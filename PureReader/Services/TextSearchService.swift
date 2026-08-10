import Foundation
import SwiftData

// MARK: - TextSearchHit

/// 全文搜索结果命中。
struct TextSearchHit: Identifiable, Sendable {
    let id = UUID()
    let chapterID: UUID
    let chapterIndex: Int
    let chapterTitle: String
    let snippet: String
    let matchPosition: Int
}

// MARK: - TextSearchService

/// 全文搜索服务。
///
/// 第一版使用内存遍历，后续可升级为持久化索引。
enum TextSearchService {

    /// 单次搜索最多返回结果数。
    static let maxResults = 200

    /// 摘录前后字符数。
    static let snippetContextChars = 80

    // MARK: - Search

    /// 在书籍中全文搜索。
    /// - Parameters:
    ///   - query: 搜索关键词
    ///   - book: 目标书籍
    ///   - context: 仅搜索已缓存章节时传 true
    /// - Returns: 搜索结果列表
    static func search(
        query: String,
        in book: Book,
        cachedOnly: Bool = false
    ) -> [TextSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        let chapters = (book.chapters ?? []).sorted { $0.index < $1.index }
        var results: [TextSearchHit] = []

        for chapter in chapters {
            guard results.count < maxResults else { break }

            let text: String
            let memoryContent = chapter.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !memoryContent.isEmpty {
                text = memoryContent
            } else if cachedOnly {
                continue
            } else if let path = chapter.offlineCachePath, !path.isEmpty,
                      let cached = try? OnlineLibraryService.cachedText(relativePath: path) {
                text = cached
            } else {
                continue
            }

            let lowerText = text.lowercased()
            var searchStart = lowerText.startIndex

            while results.count < maxResults {
                guard let range = lowerText[searchStart...].range(of: q) else { break }
                let matchPos = lowerText.distance(from: lowerText.startIndex, to: range.lowerBound)

                let snippet = makeSnippet(
                    from: text,
                    matchRange: range,
                    matchPos: matchPos
                )

                results.append(TextSearchHit(
                    chapterID: chapter.id,
                    chapterIndex: chapter.index,
                    chapterTitle: chapter.title,
                    snippet: snippet,
                    matchPosition: matchPos
                ))

                searchStart = range.upperBound
            }
        }

        return results
    }

    /// 多书联合搜索。
    static func search(
        query: String,
        in books: [Book],
        cachedOnly: Bool = false
    ) -> [(Book, [TextSearchHit])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        return books.compactMap { book in
            let hits = search(query: q, in: book, cachedOnly: cachedOnly)
            return hits.isEmpty ? nil : (book, hits)
        }
    }

    // MARK: - Snippet

    /// 生成带关键词前后的摘录文本。
    private static func makeSnippet(
        from text: String,
        matchRange: Range<String.Index>,
        matchPos: Int
    ) -> String {
        let contextStart = text.index(
            matchRange.lowerBound,
            offsetBy: -min(snippetContextChars, matchPos),
            limitedBy: text.startIndex
        ) ?? text.startIndex

        let remainingChars = text.distance(from: matchRange.upperBound, to: text.endIndex)
        let afterChars = min(snippetContextChars, remainingChars)
        let contextEnd = text.index(
            matchRange.upperBound,
            offsetBy: afterChars,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        var snippet = String(text[contextStart..<contextEnd])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")

        if contextStart != text.startIndex {
            snippet = "…" + snippet
        }
        if contextEnd != text.endIndex {
            snippet = snippet + "…"
        }

        return snippet.trimmingCharacters(in: .whitespaces)
    }
}