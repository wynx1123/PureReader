import Foundation
import zlib

/// Minimal ZIP reader for EPUB (stored + deflate).
enum ZIPUtility {
    struct Entry: Sendable {
        let name: String
        let data: Data
    }

    /// 解压到目录（供 EPUBParser 使用）
    static func extract(data: Data, to directory: URL) throws {
        let entries = try unzip(data)
        let fm = FileManager.default
        for entry in entries {
            let dest = directory.appendingPathComponent(entry.name)
            let parent = dest.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try entry.data.write(to: dest, options: .atomic)
        }
    }

    static func unzip(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ImportError.epubInvalid }
        return try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [Entry] in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else {
                throw ImportError.epubInvalid
            }
            let count = buf.count
            var offset = 0
            var entries: [Entry] = []

            while offset + 30 <= count {
                let sig = readU32(base, offset)
                if sig == 0x02014b50 || sig == 0x06054b50 {
                    break
                }
                guard sig == 0x04034b50 else {
                    if entries.isEmpty { throw ImportError.epubInvalid }
                    break
                }

                let method = Int(readU16(base, offset + 8))
                let general = Int(readU16(base, offset + 6))
                let compSize = Int(readU32(base, offset + 18))
                let uncompSize = Int(readU32(base, offset + 22))
                let nameLen = Int(readU16(base, offset + 26))
                let extraLen = Int(readU16(base, offset + 28))
                let nameStart = offset + 30
                guard nameStart + nameLen + extraLen <= count else { throw ImportError.epubInvalid }

                let nameData = Data(bytes: base + nameStart, count: nameLen)
                let name = String(data: nameData, encoding: .utf8)
                    ?? String(decoding: nameData, as: UTF8.self)

                let dataStart = nameStart + nameLen + extraLen

                // Data descriptor (bit 3): sizes after payload — not fully supported
                let usesDescriptor = (general & 0x08) != 0
                var actualComp = compSize
                if usesDescriptor && actualComp == 0 {
                    // scan for next local header or data descriptor signature
                    var p = dataStart
                    var found = false
                    while p + 4 <= count {
                        let s = readU32(base, p)
                        if s == 0x08074b50 || s == 0x04034b50 || s == 0x02014b50 {
                            actualComp = p - dataStart
                            found = true
                            break
                        }
                        p += 1
                    }
                    if !found { throw ImportError.epubInvalid }
                }

                guard dataStart + actualComp <= count else { throw ImportError.epubInvalid }
                let payload = Data(bytes: base + dataStart, count: actualComp)
                let fileData: Data
                switch method {
                case 0:
                    fileData = payload
                case 8:
                    fileData = try inflateRawDeflate(payload, expectedSize: uncompSize)
                default:
                    throw ImportError.epubInvalid
                }

                if !name.hasSuffix("/") {
                    entries.append(Entry(name: name, data: fileData))
                }

                offset = dataStart + actualComp
                if usesDescriptor {
                    // optional 0x08074b50 + 3x u32
                    if offset + 4 <= count, readU32(base, offset) == 0x08074b50 {
                        offset += 16
                    } else if offset + 12 <= count {
                        offset += 12
                    }
                }
            }

            guard !entries.isEmpty else { throw ImportError.epubInvalid }
            return entries
        }
    }

    // MARK: - Binary

    private static func readU16(_ base: UnsafePointer<UInt8>, _ o: Int) -> UInt16 {
        UInt16(base[o]) | (UInt16(base[o + 1]) << 8)
    }

    private static func readU32(_ base: UnsafePointer<UInt8>, _ o: Int) -> UInt32 {
        UInt32(base[o])
            | (UInt32(base[o + 1]) << 8)
            | (UInt32(base[o + 2]) << 16)
            | (UInt32(base[o + 3]) << 24)
    }

    private static func inflateRawDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        if data.isEmpty { return Data() }

        var stream = z_stream()
        let status = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { throw ImportError.epubInvalid }
        defer { inflateEnd(&stream) }

        let capacity = expectedSize > 0 ? expectedSize : max(data.count * 4, 64 * 1024)
        var output = Data(count: capacity)

        try data.withUnsafeBytes { srcBuf in
            guard let src = srcBuf.bindMemory(to: UInt8.self).baseAddress else {
                throw ImportError.epubInvalid
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: src)
            stream.avail_in = uInt(data.count)

            while true {
                let have = Int(stream.total_out)
                if have >= output.count {
                    output.count = max(output.count * 2, have + 64 * 1024)
                }
                let remaining = output.count - have
                let rc: Int32 = output.withUnsafeMutableBytes { dstBuf in
                    guard let dst = dstBuf.bindMemory(to: UInt8.self).baseAddress else {
                        return Z_MEM_ERROR
                    }
                    stream.next_out = dst.advanced(by: have)
                    stream.avail_out = uInt(remaining)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                if rc == Z_STREAM_END { break }
                if rc == Z_BUF_ERROR && stream.avail_in == 0 { break }
                if rc != Z_OK { throw ImportError.epubInvalid }
            }
        }

        output.count = Int(stream.total_out)
        return output
    }
}
