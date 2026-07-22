import Foundation
import UIKit

/// EPUB 解析：ZIP 解压 → OPF → spine 章节 → 纯文本
enum EPUBParser {
    static func parse(data: Data, preferredTitle: String?) throws -> ParsedBook {
        if data.isEmpty { throw ImportError.emptyFile }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        try ZIPUtility.extract(data: data, to: work)

        let rootfile = try findRootfile(in: work)
        let opfURL = work.appendingPathComponent(rootfile)
        let opfDir = opfURL.deletingLastPathComponent()
        let opfXML = try String(contentsOf: opfURL, encoding: .utf8)

        let preferred = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (preferred?.isEmpty == false ? preferred : nil)
            ?? extractTag(opfXML, name: "dc:title")
            ?? extractTag(opfXML, name: "title")
            ?? String(localized: "未命名")
        let author = extractTag(opfXML, name: "dc:creator")
            ?? extractTag(opfXML, name: "creator")
            ?? ""

        let manifest = parseManifest(opfXML)
        let spine = parseSpine(opfXML)
        var chapters: [ParsedChapter] = []

        for idref in spine {
            guard let href = manifest[idref] else { continue }
            let chapterURL = opfDir.appendingPathComponent(href)
            guard FileManager.default.fileExists(atPath: chapterURL.path) else { continue }
            let raw = (try? String(contentsOf: chapterURL, encoding: .utf8))
                ?? (try? String(contentsOf: chapterURL, encoding: .utf16))
                ?? ""
            let plain = stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.isEmpty { continue }
            let chapterTitle = extractHTMLTitle(raw)
                ?? URL(fileURLWithPath: href).deletingPathExtension().lastPathComponent
            chapters.append(
                ParsedChapter(index: chapters.count, title: chapterTitle, content: plain)
            )
        }

        if chapters.isEmpty {
            for url in listHTMLFiles(in: work) {
                let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let plain = stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if plain.isEmpty { continue }
                chapters.append(
                    ParsedChapter(
                        index: chapters.count,
                        title: url.deletingPathExtension().lastPathComponent,
                        content: plain
                    )
                )
            }
        }

        if chapters.isEmpty { throw ImportError.epubInvalid }

        let cover = findCoverImage(opfDir: opfDir, manifest: manifest, root: work)

        return ParsedBook(
            title: title,
            author: author,
            format: .epub,
            chapters: chapters,
            coverImageData: cover
        )
    }

    private static func findRootfile(in root: URL) throws -> String {
        let container = root.appendingPathComponent("META-INF/container.xml")
        let xml = try String(contentsOf: container, encoding: .utf8)
        guard let re = try? NSRegularExpression(
            pattern: #"full-path\s*=\s*"([^"]+)""#,
            options: [.caseInsensitive]
        ),
        let match = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
        match.range(at: 1).location != NSNotFound else {
            throw ImportError.epubInvalid
        }
        return (xml as NSString).substring(with: match.range(at: 1))
    }

    private static func parseManifest(_ opf: String) -> [String: String] {
        var map: [String: String] = [:]
        let pattern = #"<item\b[^>]*>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return map
        }
        let ns = opf as NSString
        for m in re.matches(in: opf, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let id = attr(tag, "id"), let href = attr(tag, "href") else { continue }
            map[id] = href.removingPercentEncoding ?? href
        }
        return map
    }

    private static func parseSpine(_ opf: String) -> [String] {
        var ids: [String] = []
        guard let re = try? NSRegularExpression(
            pattern: #"idref\s*=\s*"([^"]+)""#,
            options: [.caseInsensitive]
        ) else { return ids }
        let ns = opf as NSString
        for m in re.matches(in: opf, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound {
                ids.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return ids
    }

    private static func attr(_ tag: String, _ name: String) -> String? {
        let pattern = #"\#(name)\s*=\s*"([^"]+)""#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              m.range(at: 1).location != NSNotFound else {
            return nil
        }
        return (tag as NSString).substring(with: m.range(at: 1))
    }

    private static func extractTag(_ xml: String, name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "<\(escaped)[^>]*>([^<]+)</\(escaped)>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              m.range(at: 1).location != NSNotFound else {
            return nil
        }
        let s = (xml as NSString).substring(with: m.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func stripHTML(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(
            of: #"<script[^>]*>[\s\S]*?</script>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: #"<style[^>]*>[\s\S]*?</style>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: #"<br\s*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: #"</p>"#,
            with: "\n\n",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: #"</div>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        while s.contains("\n\n\n") {
            s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return s
    }

    private static func extractHTMLTitle(_ html: String) -> String? {
        extractTag(html, name: "title") ?? extractTag(html, name: "h1")
    }

    private static func listHTMLFiles(in root: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in en {
            let ext = url.pathExtension.lowercased()
            if ext == "html" || ext == "xhtml" || ext == "htm" {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func findCoverImage(
        opfDir: URL,
        manifest: [String: String],
        root: URL
    ) -> Data? {
        for (_, href) in manifest {
            let lower = href.lowercased()
            if lower.contains("cover"),
               lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") {
                let url = opfDir.appendingPathComponent(href)
                if let d = try? Data(contentsOf: url), UIImage(data: d) != nil {
                    return d
                }
            }
        }
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in en {
            let name = url.lastPathComponent.lowercased()
            if name.contains("cover"),
               ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()),
               let d = try? Data(contentsOf: url),
               UIImage(data: d) != nil {
                return d
            }
        }
        return nil
    }
}
