import Foundation

/// 无状态 TXT 解析：编码检测 + 章节切分
enum TXTParser {
    /// 常见章节标题正则（中文网文）
    private static let chapterPatterns: [NSRegularExpression] = {
        let raw = [
            #"^第[零一二三四五六七八九十百千万两0-9]+[章节回卷集部篇].*$"#,
            #"^Chapter\s+\d+.*$"#,
            #"^CHAPTER\s+\d+.*$"#,
            #"^第\s*\d+\s*[章节回].*$"#,
            #"^[0-9]{1,4}[\.、\s].{0,40}$"#
        ]
        return raw.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines])
        }
    }()

    static func decodeText(from data: Data) throws -> String {
        if data.isEmpty { throw ImportError.emptyFile }

        // UTF-8 BOM
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let s = String(data: data.dropFirst(3), encoding: .utf8) {
            return normalizeNewlines(s)
        }
        // UTF-16 LE/BE BOM
        if data.starts(with: [0xFF, 0xFE]),
           let s = String(data: data, encoding: .utf16LittleEndian) {
            return normalizeNewlines(s)
        }
        if data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16BigEndian) {
            return normalizeNewlines(s)
        }

        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            // 过滤大量替换字符视为失败
            let bad = s.unicodeScalars.filter { $0.value == 0xFFFD }.count
            if bad * 50 < s.count {
                return normalizeNewlines(s)
            }
        }

        // GBK / GB18030 (CFString)
        let cfEncodings: [CFStringEncoding] = [
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue),
            CFStringEncoding(CFStringEncodings.GBK_95.rawValue),
            CFStringEncoding(CFStringEncodings.GB_2312_80.rawValue)
        ]
        for enc in cfEncodings {
            let nsEnc = CFStringConvertEncodingToNSStringEncoding(enc)
            if let s = NSString(data: data, encoding: nsEnc) as String? {
                return normalizeNewlines(s)
            }
        }

        throw ImportError.unreadableEncoding
    }

    static func parse(data: Data, preferredTitle: String?) throws -> ParsedBook {
        let text = try decodeText(from: data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ImportError.emptyFile }

        let title = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? guessTitle(from: trimmed)

        let chapters = splitChapters(text: trimmed)
        return ParsedBook(
            title: title,
            author: "",
            format: .txt,
            chapters: chapters,
            coverImageData: nil
        )
    }

    static func splitChapters(text: String) -> [ParsedChapter] {
        let lines = text.components(separatedBy: .newlines)
        var chapterStarts: [(lineIndex: Int, title: String)] = []

        for (idx, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.count <= 60 else { continue }
            if isChapterTitle(t) {
                chapterStarts.append((idx, t))
            }
        }

        // 章节过少：整本一章
        if chapterStarts.count < 2 {
            return [
                ParsedChapter(index: 0, title: String(localized: "全文"), content: text)
            ]
        }

        var result: [ParsedChapter] = []
        // 前言
        if chapterStarts[0].lineIndex > 0 {
            let preface = lines[0..<chapterStarts[0].lineIndex].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !preface.isEmpty, preface.count > 50 {
                result.append(
                    ParsedChapter(index: 0, title: String(localized: "前言"), content: preface)
                )
            }
        }

        for i in chapterStarts.indices {
            let start = chapterStarts[i].lineIndex
            let end = (i + 1 < chapterStarts.count)
                ? chapterStarts[i + 1].lineIndex
                : lines.count
            let bodyLines = lines[(start + 1)..<end]
            let body = bodyLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(
                ParsedChapter(
                    index: result.count,
                    title: chapterStarts[i].title,
                    content: body.isEmpty ? " " : body
                )
            )
        }
        return result
    }

    private static func isChapterTitle(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        for re in chapterPatterns {
            if re.firstMatch(in: line, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private static func guessTitle(from text: String) -> String {
        let first = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let first, first.count <= 40, !isChapterTitle(first) {
            return first
        }
        return String(localized: "未命名")
    }

    private static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
