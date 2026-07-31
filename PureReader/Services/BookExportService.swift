import Foundation
import Compression

// MARK: - BookExportFormat

/// 导出格式。
enum BookExportFormat: String, CaseIterable, Sendable {
    case txt
    case markdown
    case html
    case epub

    var displayName: String {
        switch self {
        case .txt: return String(localized: "TXT 纯文本")
        case .markdown: return String(localized: "Markdown")
        case .html: return String(localized: "HTML 网页")
        case .epub: return String(localized: "EPUB 电子书")
        }
    }

    var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .markdown: return "md"
        case .html: return "html"
        case .epub: return "epub"
        }
    }

    var mimeType: String {
        switch self {
        case .txt: return "text/plain"
        case .markdown: return "text/markdown"
        case .html: return "text/html"
        case .epub: return "application/epub+zip"
        }
    }
}

// MARK: - BookExportOptions

/// 导出选项。
struct BookExportOptions: Sendable {
    var includeCover: Bool
    var includeMetadata: Bool
    var onlyCachedChapters: Bool
    var replaceImagePlaceholders: Bool

    static let `default` = BookExportOptions(
        includeCover: true,
        includeMetadata: true,
        onlyCachedChapters: false,
        replaceImagePlaceholders: true
    )

    /// 只导出已缓存章节。
    static let cachedOnly = BookExportOptions(
        includeCover: true,
        includeMetadata: true,
        onlyCachedChapters: true,
        replaceImagePlaceholders: true
    )
}

// MARK: - BookExportReport

/// 导出前检查报告。
struct BookExportReport: Sendable {
    let totalChapters: Int
    let chaptersWithContent: Int
    let chaptersWithCache: Int
    let missingChapters: Int

    var canExport: Bool {
        chaptersWithContent + chaptersWithCache > 0
    }

    var missingCount: Int {
        totalChapters - chaptersWithContent - chaptersWithCache
    }
}

// MARK: - BookExportService

/// 统一书籍导出服务。
///
/// 支持 TXT、Markdown、HTML、EPUB 四种格式。
/// 在线书籍优先使用 chapter.content，其次读取离线缓存。
enum BookExportService {

    // MARK: - Pre-check

    /// 导出前检查：统计各章节内容来源。
    static func checkExportAvailability(book: Book, chapters: [Chapter]) -> BookExportReport {
        var withContent = 0
        var withCache = 0
        let total = chapters.count

        for ch in chapters {
            if !ch.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withContent += 1
            } else if let path = ch.offlineCachePath, !path.isEmpty,
                      (try? OnlineLibraryService.cachedText(relativePath: path))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                withCache += 1
            }
        }

        return BookExportReport(
            totalChapters: total,
            chaptersWithContent: withContent,
            chaptersWithCache: withCache,
            missingChapters: total - withContent - withCache
        )
    }

    // MARK: - Export

    /// 导出书籍为指定格式。
    /// - Returns: 导出文件的临时 URL
    @MainActor
    static func export(
        book: Book,
        chapters: [Chapter],
        format: BookExportFormat,
        options: BookExportOptions = .default
    ) throws -> URL {
        let sorted = chapters.sorted { $0.index < $1.index }

        switch format {
        case .txt:
            return try exportAsTXT(book: book, chapters: sorted, options: options)
        case .markdown:
            return try exportAsMarkdown(book: book, chapters: sorted, options: options)
        case .html:
            return try exportAsHTML(book: book, chapters: sorted, options: options)
        case .epub:
            return try exportAsEPUB(book: book, chapters: sorted, options: options)
        }
    }

    // MARK: - TXT

    private static func exportAsTXT(book: Book, chapters: [Chapter], options: BookExportOptions) throws -> URL {
        var parts: [String] = []

        if options.includeMetadata {
            parts.append("《\(book.title)》")
            if !book.author.isEmpty {
                parts.append(String(localized: "作者：\(book.author)"))
            }
            parts.append(String(repeating: "-", count: 40))
            parts.append("")
        }

        for (index, ch) in chapters.enumerated() {
            guard let text = chapterContent(ch, options: options) else { continue }
            parts.append(ch.title)
            parts.append("")
            parts.append(text)
            parts.append("")
            if index < chapters.count - 1 {
                parts.append("")
            }
        }

        let content = parts.joined(separator: "\n")
        return try writeExportFile(content: content, book: book, format: .txt)
    }

    // MARK: - Markdown

    private static func exportAsMarkdown(book: Book, chapters: [Chapter], options: BookExportOptions) throws -> URL {
        var parts: [String] = []

        if options.includeMetadata {
            parts.append("# \(book.title)")
            if !book.author.isEmpty {
                parts.append(String(localized: "*作者：\(book.author)*"))
            }
            parts.append("")
            parts.append("---")
            parts.append("")
        }

        // 目录
        parts.append("## " + String(localized: "目录"))
        parts.append("")
        for (index, ch) in chapters.enumerated() {
            parts.append("\(index + 1). [\(ch.title)](#chapter-\(index + 1))")
        }
        parts.append("")
        parts.append("---")
        parts.append("")

        for (index, ch) in chapters.enumerated() {
            guard let text = chapterContent(ch, options: options) else { continue }
            parts.append("## " + String(localized: "第\(index + 1)章 \(ch.title)") + " {#chapter-\(index + 1)}")
            parts.append("")
            // 将正文按段落分开
            let paragraphs = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for paragraph in paragraphs {
                parts.append(paragraph)
                parts.append("")
            }
            parts.append("")
        }

        let content = parts.joined(separator: "\n")
        return try writeExportFile(content: content, book: book, format: .markdown)
    }

    // MARK: - HTML

    private static func exportAsHTML(book: Book, chapters: [Chapter], options: BookExportOptions) throws -> URL {
        var html = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>\(book.title)</title>
        <style>
        body { font-family: -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; line-height: 1.8; color: #333; }
        h1 { text-align: center; border-bottom: 2px solid #eee; padding-bottom: 10px; }
        h2 { margin-top: 40px; color: #555; }
        .author { text-align: center; color: #888; margin-bottom: 30px; }
        .toc { background: #f8f8f8; padding: 15px 20px; border-radius: 8px; margin: 20px 0; }
        .toc ol { padding-left: 20px; }
        .toc a { color: #0066cc; text-decoration: none; }
        .chapter-content { margin: 20px 0; }
        .chapter-content p { text-indent: 2em; margin: 0.5em 0; }
        </style>
        </head>
        <body>
        """

        if options.includeMetadata {
            html += """
            <h1>\(book.title)</h1>
            """
            if !book.author.isEmpty {
                html += """
                <p class="author">\(String(localized: "作者：\(book.author)"))</p>
                """
            }
        }

        // 目录
        html += """
        <div class="toc">
        <h2>\(String(localized: "目录"))</h2>
        <ol>
        """
        for (index, ch) in chapters.enumerated() {
            html += "<li><a href=\"#chapter-\(index + 1)\">\(ch.title)</a></li>"
        }
        html += "</ol></div>"

        for (index, ch) in chapters.enumerated() {
            guard let text = chapterContent(ch, options: options) else { continue }
            html += "<h2 id=\"chapter-\(index + 1)\">\(ch.title)</h2>"
            html += "<div class=\"chapter-content\">"
            let paragraphs = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for paragraph in paragraphs {
                if options.replaceImagePlaceholders {
                    let cleaned = paragraph.replacingOccurrences(
                        of: ChapterRichContent.imagePlaceholder,
                        with: String(localized: "[图片]")
                    )
                    html += "<p>\(cleaned)</p>"
                } else {
                    html += "<p>\(paragraph)</p>"
                }
            }
            html += "</div>"
        }

        html += "</body></html>"

        return try writeExportFile(content: html, book: book, format: .html)
    }

    // MARK: - EPUB

    private static func exportAsEPUB(book: Book, chapters: [Chapter], options: BookExportOptions) throws -> URL {
        let dir = try prepareExportDirectory(for: book)
        let epubDir = dir.appendingPathComponent("epub", isDirectory: true)
        try FileManager.default.createDirectory(at: epubDir, withIntermediateDirectories: true)

        // mimetype（EPUB 标准要求首文件，不压缩）
        let mimetypeData = "application/epub+zip".data(using: .ascii)!
        try mimetypeData.write(to: epubDir.appendingPathComponent("mimetype"))

        // 创建 EPUB 基本结构
        let metaInfDir = epubDir.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInfDir, withIntermediateDirectories: true)

        let oebpsDir = epubDir.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: oebpsDir, withIntermediateDirectories: true)

        // container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        // content.opf
        var manifestItems = ""
        var spineItems = ""
        var chapterFiles: [String] = []

        for (index, ch) in chapters.enumerated() {
            guard let text = chapterContent(ch, options: options) else { continue }
            let fileName = "chapter-\(index + 1).xhtml"
            chapterFiles.append(fileName)

            let chapterHTML = buildChapterXHTML(title: ch.title, content: text, options: options)
            try chapterHTML.write(to: oebpsDir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)

            manifestItems += """
                <item id="chapter-\(index + 1)" href="\(fileName)" media-type="application/xhtml+xml"/>
            """
            spineItems += """
                <itemref idref="chapter-\(index + 1)"/>
            """
        }

        let contentOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(book.title)</dc:title>
                <dc:creator>\(book.author)</dc:creator>
                <dc:language>zh-CN</dc:language>
                <dc:identifier id="book-id">\(book.id.uuidString)</dc:identifier>
            </metadata>
            <manifest>
                \(manifestItems)
            </manifest>
            <spine>
                \(spineItems)
            </spine>
        </package>
        """
        try contentOPF.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        // 打包为 ZIP (EPUB)
        let epubURL = dir.appendingPathComponent("\(safeFilename(for: book.title)).epub")
        try createEPUBArchive(from: epubDir, to: epubURL)

        return epubURL
    }

    private static func buildChapterXHTML(title: String, content: String, options: BookExportOptions) -> String {
        var paragraphs = ""
        let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for line in lines {
            let cleaned = options.replaceImagePlaceholders
                ? line.replacingOccurrences(of: ChapterRichContent.imagePlaceholder, with: String(localized: "[图片]"))
                : line
            paragraphs += "<p>\(cleaned)</p>\n"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <title>\(title)</title>
        <meta charset="UTF-8"/>
        </head>
        <body>
        <h1>\(title)</h1>
        \(paragraphs)
        </body>
        </html>
        """
    }

    // MARK: - Chapter content resolution

    /// 解析章节正文：优先内存内容，其次离线缓存。
    private static func chapterContent(_ chapter: Chapter, options: BookExportOptions) -> String? {
        let memoryContent = chapter.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memoryContent.isEmpty {
            return memoryContent
        }
        guard !options.onlyCachedChapters else { return nil }
        if let path = chapter.offlineCachePath, !path.isEmpty,
           let cached = try? OnlineLibraryService.cachedText(relativePath: path) {
            let trimmed = cached.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - File helpers

    private static func writeExportFile(content: String, book: Book, format: BookExportFormat) throws -> URL {
        let dir = try prepareExportDirectory(for: book)
        let filename = "\(safeFilename(for: book.title)).\(format.fileExtension)"
        let url = dir.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func prepareExportDirectory(for book: Book) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent(book.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func safeFilename(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -_()[]（）【】"))
        var sanitized = String(
            title.unicodeScalars
                .map { allowed.contains($0) || $0.value > 0x2FFF ? Character($0) : "_" }
                .prefix(60)
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if sanitized.isEmpty || sanitized.hasPrefix(".") || sanitized.allSatisfy({ $0 == "_" }) {
            sanitized = String(localized: "未命名")
        }
        return "\(sanitized)-\(UUID().uuidString.prefix(8))"
    }
}

private extension BookExportService {

    /// 使用 Compression 框架压缩数据。
    static func compressData(_ data: Data) -> Data {
        let sourceSize = data.count
        let destinationSize = sourceSize + 1024
        var result = Data(count: destinationSize)
        let compressedSize = result.withUnsafeMutableBytes { dest -> Int in
            return data.withUnsafeBytes { src -> Int in
                guard let destBase = dest.baseAddress,
                      let srcBase = src.baseAddress else { return 0 }
                return compression_encode_buffer(
                    destBase.assumingMemoryBound(to: UInt8.self),
                    destinationSize,
                    srcBase.assumingMemoryBound(to: UInt8.self),
                    sourceSize,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        if compressedSize > 0 && compressedSize <= destinationSize {
            result.count = compressedSize
            return result
        }
        return data
    }

    /// 使用手动 ZIP 打包 EPUB。
    static func createEPUBArchive(from epubDir: URL, to epubURL: URL) throws {
        if FileManager.default.fileExists(atPath: epubURL.path) {
            try FileManager.default.removeItem(at: epubURL)
        }
        let fileManager = FileManager.default
        var entries: [(path: String, data: Data)] = []

        // 1. mimetype（不压缩，首文件）
        let mimetypePath = epubDir.appendingPathComponent("mimetype")
        if fileManager.fileExists(atPath: mimetypePath.path) {
            entries.append(("mimetype", try Data(contentsOf: mimetypePath)))
        }

        // 2. 递归收集其他文件
        func collectFiles(in dir: URL, basePath: String) throws {
            let contents = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for url in contents {
                let name = url.lastPathComponent
                let relativePath = basePath.isEmpty ? name : basePath + "/" + name
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    entries.append((relativePath + "/", Data()))
                    try collectFiles(in: url, basePath: relativePath)
                } else if name != "mimetype" {
                    entries.append((relativePath, try Data(contentsOf: url)))
                }
            }
        }
        try collectFiles(in: epubDir, basePath: "")

        // 3. 写入 ZIP
        let output = try FileHandle(forWritingTo: epubURL)
        defer { try? output.close() }

        var centralDirectory = Data()
        var offset: UInt32 = 0

        for (path, data) in entries {
            let isMimetype = path == "mimetype"
            let compressed = isMimetype ? data : compressData(data)
            let crc = crc32Value(data)
            let pathBytes = path.data(using: .utf8)!

            // Local file header
            var local = Data()
            local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // signature
            local.append(u16: 20)  // version needed
            local.append(u16: 0)   // flags
            local.append(u16: isMimetype ? 0 : 8) // compression
            local.append(u16: 0)   // mod time
            local.append(u16: 0)   // mod date
            local.append(u32: crc)
            local.append(u32: UInt32(compressed.count))
            local.append(u32: UInt32(data.count))
            local.append(u16: UInt16(pathBytes.count))
            local.append(u16: 0)   // extra field
            local.append(contentsOf: pathBytes)

            output.write(local)
            output.write(compressed)

            // Central directory entry
            var cd = Data()
            cd.append(contentsOf: [0x50, 0x4B, 0x01, 0x02]) // signature
            cd.append(u16: 20) // version made by
            cd.append(u16: 20) // version needed
            cd.append(u16: 0)  // flags
            cd.append(u16: isMimetype ? 0 : 8) // compression
            cd.append(u16: 0)  // mod time
            cd.append(u16: 0)  // mod date
            cd.append(u32: crc)
            cd.append(u32: UInt32(compressed.count))
            cd.append(u32: UInt32(data.count))
            cd.append(u16: UInt16(pathBytes.count))
            cd.append(u16: 0)  // extra field
            cd.append(u16: 0)  // file comment
            cd.append(u16: 0)  // disk number start
            cd.append(u16: 0)  // internal attrs
            cd.append(u32: 0)  // external attrs
            cd.append(u32: offset) // local header offset
            cd.append(contentsOf: pathBytes)

            centralDirectory.append(cd)
            offset += UInt32(local.count + compressed.count)
        }

        let cdOffset = offset
        output.write(centralDirectory)

        // End of central directory
        let entryCount = UInt16(entries.count)
        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // signature
        eocd.append(u16: 0)  // disk number
        eocd.append(u16: 0)  // disk with CD
        eocd.append(u16: entryCount) // entries on this disk
        eocd.append(u16: entryCount) // total entries
        eocd.append(u32: UInt32(centralDirectory.count))
        eocd.append(u32: cdOffset)
        eocd.append(u16: 0)  // comment length
        output.write(eocd)
    }

    // MARK: - CRC-32

    private static func crc32Value(_ data: Data) -> UInt32 {
        return data.withUnsafeBytes { bytes in
            var crc: UInt32 = 0xFFFF_FFFF
            let table = crc32Table
            for byte in bytes.bindMemory(to: UInt8.self) {
                let index = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = (crc >> 8) ^ table[index]
            }
            return crc ^ 0xFFFF_FFFF
        }
    }

    private static let crc32Table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
            table[i] = crc
        }
        return table
    }()
}

// MARK: - Data binary helpers

private extension Data {
    mutating func append(u16 value: UInt16) {
        var v = value.littleEndian
        append(contentsOf: Swift.withUnsafeBytes(of: &v) { Array($0) })
    }

    mutating func append(u32 value: UInt32) {
        var v = value.littleEndian
        append(contentsOf: Swift.withUnsafeBytes(of: &v) { Array($0) })
    }
}