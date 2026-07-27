import Foundation
import UIKit

/// EPUB 解析：ZIP 解压 → OPF → spine 章节 → 纯文本。
enum EPUBParser {
    static func parse(data: Data, preferredTitle: String?) throws -> ParsedBook {
        if data.isEmpty { throw ImportError.emptyFile }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        try ZIPUtility.extract(data: data, to: work)

        let rootfile = try findRootfile(in: work)
        guard let opfURL = resolvedURL(rootfile, relativeTo: work, root: work),
              FileManager.default.fileExists(atPath: opfURL.path) else {
            throw ImportError.epubInvalid
        }
        let opfDirectory = opfURL.deletingLastPathComponent()
        let opfXML = try readMarkup(at: opfURL)

        let fallbackTitle = preferredTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = extractTag(opfXML, name: "dc:title")
            ?? extractTag(opfXML, name: "title")
            ?? (fallbackTitle?.isEmpty == false ? fallbackTitle : nil)
            ?? String(localized: "未命名")
        let author = extractTag(opfXML, name: "dc:creator")
            ?? extractTag(opfXML, name: "creator")
            ?? ""

        let manifest = parseManifest(opfXML)
        let spine = parseSpine(opfXML)
        var chapters: [ParsedChapter] = []

        for idref in spine {
            guard let href = manifest[idref],
                  let chapterURL = resolvedURL(href, relativeTo: opfDirectory, root: work),
                  FileManager.default.fileExists(atPath: chapterURL.path),
                  let raw = try? readMarkup(at: chapterURL) else {
                continue
            }
            let plain = stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.isEmpty { continue }
            let chapterTitle = extractHTMLTitle(raw)
                ?? chapterURL.deletingPathExtension().lastPathComponent
            chapters.append(
                ParsedChapter(index: chapters.count, title: chapterTitle, content: plain)
            )
        }

        // 非规范 EPUB 可能缺少 spine；按目录中的 HTML 顺序兜底。
        if chapters.isEmpty {
            for url in listHTMLFiles(in: work) {
                guard let raw = try? readMarkup(at: url) else { continue }
                let plain = stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if plain.isEmpty { continue }
                chapters.append(
                    ParsedChapter(
                        index: chapters.count,
                        title: extractHTMLTitle(raw)
                            ?? url.deletingPathExtension().lastPathComponent,
                        content: plain
                    )
                )
            }
        }

        if chapters.isEmpty { throw ImportError.epubInvalid }

        return ParsedBook(
            title: title,
            author: author,
            format: .epub,
            chapters: chapters,
            coverImageData: findCoverImage(
                opfDirectory: opfDirectory,
                manifest: manifest,
                root: work
            )
        )
    }

    // MARK: - Package metadata

    private static func findRootfile(in root: URL) throws -> String {
        let container = root.appendingPathComponent("META-INF/container.xml")
        let xml = try readMarkup(at: container)
        guard let expression = try? NSRegularExpression(
            pattern: #"<rootfile\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else {
            throw ImportError.epubInvalid
        }
        let ns = xml as NSString
        for match in expression.matches(
            in: xml,
            range: NSRange(location: 0, length: ns.length)
        ) {
            let tag = ns.substring(with: match.range)
            if let path = attr(tag, "full-path"), !path.isEmpty {
                return path
            }
        }
        throw ImportError.epubInvalid
    }

    private static func parseManifest(_ opf: String) -> [String: String] {
        var map: [String: String] = [:]
        guard let expression = try? NSRegularExpression(
            pattern: #"<item\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else {
            return map
        }
        let ns = opf as NSString
        for match in expression.matches(
            in: opf,
            range: NSRange(location: 0, length: ns.length)
        ) {
            let tag = ns.substring(with: match.range)
            guard let id = attr(tag, "id"),
                  let href = attr(tag, "href") else {
                continue
            }
            map[id] = decodeHTMLEntities(href)
        }
        return map
    }

    private static func parseSpine(_ opf: String) -> [String] {
        var ids: [String] = []
        guard let expression = try? NSRegularExpression(
            pattern: #"<itemref\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else {
            return ids
        }
        let ns = opf as NSString
        for match in expression.matches(
            in: opf,
            range: NSRange(location: 0, length: ns.length)
        ) {
            let tag = ns.substring(with: match.range)
            if let idref = attr(tag, "idref"), !idref.isEmpty {
                ids.append(idref)
            }
        }
        return ids
    }

    private static func attr(_ tag: String, _ name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\\b\(escaped)\\s*=\\s*([\"'])(.*?)\\1"
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
        let match = expression.firstMatch(
            in: tag,
            range: NSRange(tag.startIndex..., in: tag)
        ),
        match.range(at: 2).location != NSNotFound else {
            return nil
        }
        return (tag as NSString).substring(with: match.range(at: 2))
    }

    private static func extractTag(_ xml: String, name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "<\(escaped)\\b[^>]*>([\\s\\S]*?)</\(escaped)>"
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ),
        let match = expression.firstMatch(
            in: xml,
            range: NSRange(xml.startIndex..., in: xml)
        ),
        match.range(at: 1).location != NSNotFound else {
            return nil
        }
        let raw = (xml as NSString).substring(with: match.range(at: 1))
        let value = stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Content decoding

    private static func readMarkup(at url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ImportError.epubInvalid
        }
        guard let text = decodeMarkup(data), !text.isEmpty else {
            throw ImportError.epubInvalid
        }
        return text
    }

    private static func decodeMarkup(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return String(data: data, encoding: .utf32LittleEndian)
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: data, encoding: .utf32BigEndian)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        let preview = String(data: data.prefix(512), encoding: .isoLatin1) ?? ""
        let declaredEncoding = firstCapture(
            in: preview,
            pattern: #"encoding\s*=\s*["']([^"']+)["']"#
        ) ?? firstCapture(
            in: preview,
            pattern: #"charset\s*=\s*["']?([^\s"'/>;]+)"#
        )
        if let declared = declaredEncoding?.lowercased() {
            let encoding: String.Encoding?
            switch declared {
            case "iso-8859-1", "latin1", "latin-1":
                encoding = .isoLatin1
            case "windows-1252", "cp1252":
                encoding = .windowsCP1252
            case "utf-16", "utf-16le":
                encoding = .utf16LittleEndian
            case "utf-16be":
                encoding = .utf16BigEndian
            default:
                encoding = nil
            }
            if let encoding, let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
        }

        // 部分中文 EPUB 的声明与实际编码不一致，复用 TXT 的编码探测兜底。
        return try? TXTParser.decodeText(from: data)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ),
        let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ),
        match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    private static func resolvedURL(
        _ rawPath: String,
        relativeTo base: URL,
        root: URL
    ) -> URL? {
        var path = decodeHTMLEntities(rawPath)
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        path = path.removingPercentEncoding ?? path
        path = path.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }

        let destination = base.appendingPathComponent(path).standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else { return nil }
        return destination
    }

    // MARK: - HTML to text

    private static func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<![CDATA[", with: "")
            .replacingOccurrences(of: "]]>", with: "")
        text = text.replacingOccurrences(
            of: #"<script[^>]*>[\s\S]*?</script>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: #"<style[^>]*>[\s\S]*?</style>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        for closingTag in ["p", "div", "li", "h1", "h2", "h3", "blockquote"] {
            text = text.replacingOccurrences(
                of: "</\(closingTag)>",
                with: "\n\n",
                options: [.caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = decodeHTMLEntities(text)
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        var result = input
        let named: [(String, String)] = [
            ("&nbsp;", " "),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&amp;", "&")
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(
                of: entity,
                with: replacement,
                options: [.caseInsensitive]
            )
        }

        guard let expression = try? NSRegularExpression(
            pattern: #"&#(x?[0-9A-Fa-f]+);"#
        ) else {
            return result
        }
        let ns = result as NSString
        let matches = expression.matches(
            in: result,
            range: NSRange(location: 0, length: ns.length)
        )
        for match in matches.reversed() where match.range(at: 1).location != NSNotFound {
            let raw = ns.substring(with: match.range(at: 1))
            let value: UInt32?
            if raw.lowercased().hasPrefix("x") {
                value = UInt32(raw.dropFirst(), radix: 16)
            } else {
                value = UInt32(raw, radix: 10)
            }
            guard let value, let scalar = UnicodeScalar(value) else { continue }
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: String(scalar)
            )
        }
        return result
    }

    private static func extractHTMLTitle(_ html: String) -> String? {
        extractTag(html, name: "title")
            ?? extractTag(html, name: "h1")
            ?? extractTag(html, name: "h2")
    }

    private static func listHTMLFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if ["html", "xhtml", "htm"].contains(url.pathExtension.lowercased()) {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func findCoverImage(
        opfDirectory: URL,
        manifest: [String: String],
        root: URL
    ) -> Data? {
        for href in manifest.values {
            let lowercased = href.lowercased()
            guard lowercased.contains("cover"),
                  ["jpg", "jpeg", "png", "webp"].contains(
                    URL(fileURLWithPath: lowercased).pathExtension
                  ),
                  let url = resolvedURL(href, relativeTo: opfDirectory, root: root),
                  let data = try? Data(contentsOf: url),
                  UIImage(data: data) != nil else {
                continue
            }
            return data
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            if name.contains("cover"),
               ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased()),
               let data = try? Data(contentsOf: url),
               UIImage(data: data) != nil {
                return data
            }
        }
        return nil
    }
}
