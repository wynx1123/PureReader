import Foundation
import zlib

/// EPUB 使用的轻量 ZIP 读取器。
///
/// 通过中央目录读取压缩尺寸，因此能够正确处理使用 data descriptor 的标准 EPUB；
/// 同时限制解压体积并阻止路径穿越。
enum ZIPUtility {
    struct Entry: Sendable {
        let name: String
        let data: Data
    }

    private struct CentralEntry {
        let name: String
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static let localHeaderSignature: UInt32 = 0x04034B50
    private static let centralHeaderSignature: UInt32 = 0x02014B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054B50
    private static let maxEntryCount = 20_000
    private static let maxEntryBytes = 128 * 1024 * 1024
    private static let maxArchiveBytes = 256 * 1024 * 1024

    /// 解压到目录（供 EPUBParser 使用）。
    static func extract(data: Data, to directory: URL) throws {
        let entries = try unzip(data)
        let fm = FileManager.default
        let root = directory.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"

        for entry in entries {
            guard let relativePath = safeRelativePath(entry.name) else {
                throw ImportError.epubInvalid
            }
            let destination = root.appendingPathComponent(relativePath).standardizedFileURL
            guard destination.path.hasPrefix(rootPrefix) else {
                throw ImportError.epubInvalid
            }
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try entry.data.write(to: destination, options: .atomic)
        }
    }

    static func unzip(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ImportError.epubInvalid }

        return try data.withUnsafeBytes { rawBuffer -> [Entry] in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw ImportError.epubInvalid
            }
            let byteCount = rawBuffer.count
            let eocdOffset = try findEndOfCentralDirectory(base: base, count: byteCount)

            let diskNumber = Int(readU16(base, eocdOffset + 4))
            let centralDisk = Int(readU16(base, eocdOffset + 6))
            let entriesOnDisk = Int(readU16(base, eocdOffset + 8))
            let entryCount = Int(readU16(base, eocdOffset + 10))
            let centralSize = Int(readU32(base, eocdOffset + 12))
            let centralOffset = Int(readU32(base, eocdOffset + 16))

            // EPUB 不需要跨磁盘 ZIP 或 ZIP64；明确拒绝，避免错误解析。
            guard diskNumber == 0,
                  centralDisk == 0,
                  entriesOnDisk == entryCount,
                  entryCount > 0,
                  entryCount <= maxEntryCount,
                  entryCount != Int(UInt16.max),
                  centralSize != Int(UInt32.max),
                  centralOffset != Int(UInt32.max),
                  centralOffset >= 0,
                  centralSize >= 0,
                  centralOffset + centralSize <= byteCount else {
                throw ImportError.epubInvalid
            }

            var centralEntries: [CentralEntry] = []
            centralEntries.reserveCapacity(entryCount)
            var cursor = centralOffset

            for _ in 0..<entryCount {
                guard cursor + 46 <= byteCount,
                      readU32(base, cursor) == centralHeaderSignature else {
                    throw ImportError.epubInvalid
                }

                let flags = Int(readU16(base, cursor + 8))
                let method = Int(readU16(base, cursor + 10))
                let compressedSize = Int(readU32(base, cursor + 20))
                let uncompressedSize = Int(readU32(base, cursor + 24))
                let nameLength = Int(readU16(base, cursor + 28))
                let extraLength = Int(readU16(base, cursor + 30))
                let commentLength = Int(readU16(base, cursor + 32))
                let localHeaderOffset = Int(readU32(base, cursor + 42))
                let recordLength = 46 + nameLength + extraLength + commentLength

                guard nameLength > 0,
                      cursor + recordLength <= byteCount,
                      compressedSize != Int(UInt32.max),
                      uncompressedSize != Int(UInt32.max),
                      localHeaderOffset != Int(UInt32.max),
                      (flags & 0x01) == 0,
                      method == 0 || method == 8 else {
                    throw ImportError.epubInvalid
                }

                let nameData = Data(bytes: base + cursor + 46, count: nameLength)
                let name = decodeFilename(nameData, utf8Flag: (flags & 0x0800) != 0)
                guard !name.isEmpty else { throw ImportError.epubInvalid }

                centralEntries.append(
                    CentralEntry(
                        name: name,
                        method: method,
                        compressedSize: compressedSize,
                        uncompressedSize: uncompressedSize,
                        localHeaderOffset: localHeaderOffset
                    )
                )
                cursor += recordLength
            }

            var entries: [Entry] = []
            entries.reserveCapacity(centralEntries.count)
            var totalUncompressed = 0

            for central in centralEntries where !central.name.hasSuffix("/") {
                guard safeRelativePath(central.name) != nil,
                      central.uncompressedSize <= maxEntryBytes,
                      central.compressedSize >= 0,
                      central.localHeaderOffset >= 0,
                      central.localHeaderOffset + 30 <= byteCount,
                      readU32(base, central.localHeaderOffset) == localHeaderSignature else {
                    throw ImportError.epubInvalid
                }

                totalUncompressed += central.uncompressedSize
                guard totalUncompressed <= maxArchiveBytes else {
                    throw ImportError.fileTooLarge
                }

                let localNameLength = Int(readU16(base, central.localHeaderOffset + 26))
                let localExtraLength = Int(readU16(base, central.localHeaderOffset + 28))
                let payloadOffset = central.localHeaderOffset + 30 + localNameLength + localExtraLength
                guard payloadOffset >= 0,
                      payloadOffset + central.compressedSize <= byteCount else {
                    throw ImportError.epubInvalid
                }

                let payload = Data(
                    bytes: base + payloadOffset,
                    count: central.compressedSize
                )
                let fileData: Data
                switch central.method {
                case 0:
                    fileData = payload
                case 8:
                    fileData = try inflateRawDeflate(
                        payload,
                        expectedSize: central.uncompressedSize
                    )
                default:
                    throw ImportError.epubInvalid
                }

                if central.uncompressedSize > 0,
                   fileData.count != central.uncompressedSize {
                    throw ImportError.epubInvalid
                }
                entries.append(Entry(name: central.name, data: fileData))
            }

            guard !entries.isEmpty else { throw ImportError.epubInvalid }
            return entries
        }
    }

    // MARK: - ZIP metadata

    private static func findEndOfCentralDirectory(
        base: UnsafePointer<UInt8>,
        count: Int
    ) throws -> Int {
        let earliest = max(0, count - (65_535 + 22))
        var offset = count - 22
        while offset >= earliest {
            if readU32(base, offset) == endOfCentralDirectorySignature {
                let commentLength = Int(readU16(base, offset + 20))
                if offset + 22 + commentLength == count {
                    return offset
                }
            }
            if offset == earliest { break }
            offset -= 1
        }
        throw ImportError.epubInvalid
    }

    private static func decodeFilename(_ data: Data, utf8Flag: Bool) -> String {
        if utf8Flag, let value = String(data: data, encoding: .utf8) {
            return value
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func safeRelativePath(_ raw: String) -> String? {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains("\0") else {
            return nil
        }
        let components = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        guard !components.isEmpty,
              components.allSatisfy({ $0 != ".." }) else {
            return nil
        }
        return components.map(String.init).joined(separator: "/")
    }

    private static func readU16(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt16 {
        UInt16(base[offset]) | (UInt16(base[offset + 1]) << 8)
    }

    private static func readU32(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(base[offset])
            | (UInt32(base[offset + 1]) << 8)
            | (UInt32(base[offset + 2]) << 16)
            | (UInt32(base[offset + 3]) << 24)
    }

    // MARK: - Deflate

    private static func inflateRawDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        if data.isEmpty {
            guard expectedSize == 0 else { throw ImportError.epubInvalid }
            return Data()
        }

        var stream = z_stream()
        let status = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw ImportError.epubInvalid }
        defer { inflateEnd(&stream) }

        let initialCapacity = expectedSize > 0
            ? expectedSize
            : max(data.count * 4, 64 * 1024)
        var output = Data(count: max(initialCapacity, 1))

        try data.withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw ImportError.epubInvalid
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: source)
            stream.avail_in = uInt(data.count)

            while true {
                let written = Int(stream.total_out)
                if written >= output.count {
                    let expanded = max(output.count * 2, written + 64 * 1024)
                    guard expanded <= maxEntryBytes else { throw ImportError.fileTooLarge }
                    output.count = expanded
                }

                let available = output.count - written
                let result: Int32 = output.withUnsafeMutableBytes { destinationBuffer in
                    guard let destination = destinationBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return Z_MEM_ERROR
                    }
                    stream.next_out = destination.advanced(by: written)
                    stream.avail_out = uInt(available)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                if result == Z_STREAM_END { break }
                guard result == Z_OK else { throw ImportError.epubInvalid }
                if stream.avail_in == 0, stream.avail_out > 0 {
                    throw ImportError.epubInvalid
                }
            }
        }

        output.count = Int(stream.total_out)
        return output
    }
}
