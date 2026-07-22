import Foundation
import SwiftData

/// 书源网络引擎：搜索 / 目录 / 正文（15s 超时 + 最多 2 次重试）
enum BookSourceEngine {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 PureReader/1.0"
        ]
        return URLSession(configuration: c)
    }()

    // MARK: - Search

    static func search(keyword: String, sources: [BookSource], page: Int = 1) async -> [SourceSearchResult] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        let enabled = sources.filter { $0.enabled && $0.isValid && !$0.searchURL.isEmpty }
        guard !enabled.isEmpty else { return [] }

        return await withTaskGroup(of: [SourceSearchResult].self) { group in
            for source in enabled {
                group.addTask {
                    (try? await searchOne(keyword: key, source: source, page: page)) ?? []
                }
            }
            var all: [SourceSearchResult] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            // 去重 by name+author
            var seen = Set<String>()
            return all.filter { r in
                let k = r.name + "|" + r.author
                if seen.contains(k) { return false }
                seen.insert(k)
                return true
            }
        }
    }

    private static func searchOne(keyword: String, source: BookSource, page: Int) async throws -> [SourceSearchResult] {
        let urlString = source.searchURL
            .replacingOccurrences(of: "{{key}}", with: urlEncode(keyword))
            .replacingOccurrences(of: "{{page}}", with: "\(page)")
            .replacingOccurrences(of: "{{key}}", with: urlEncode(keyword))
        // Legado uses {{key}} or {key}
        let u2 = urlString
            .replacingOccurrences(of: "{key}", with: urlEncode(keyword))
            .replacingOccurrences(of: "{page}", with: "\(page)")
        guard let url = URL(string: u2) else { return [] }
        let body = try await fetchString(url: url)
        let rules = source.rules
        let blocks = RuleParser.getStrings(from: body, rule: rules.bookList, baseURL: url)
        if blocks.isEmpty {
            // try JSON list directly as single document fields
            return parseSearchFromRoot(body: body, url: url, source: source)
        }
        var results: [SourceSearchResult] = []
        for block in blocks.prefix(30) {
            let name = RuleParser.getString(from: block, rule: rules.name, baseURL: url) ?? ""
            let author = RuleParser.getString(from: block, rule: rules.author, baseURL: url) ?? ""
            let intro = RuleParser.getString(from: block, rule: rules.intro, baseURL: url) ?? ""
            let cover = RuleParser.getString(from: block, rule: rules.coverUrl, baseURL: url)
            var bookUrl = RuleParser.getString(from: block, rule: rules.bookUrl, baseURL: url) ?? ""
            if bookUrl.isEmpty { continue }
            if !bookUrl.hasPrefix("http") {
                bookUrl = RuleParser.resolveURL(bookUrl, base: url)
            }
            if name.isEmpty { continue }
            results.append(SourceSearchResult(
                name: name,
                author: author,
                intro: intro,
                coverURL: cover,
                bookURL: bookUrl,
                sourceID: source.id,
                sourceName: source.name
            ))
        }
        return results
    }

    private static func parseSearchFromRoot(body: String, url: URL, source: BookSource) -> [SourceSearchResult] {
        let rules = source.rules
        // JSON arrays of books via bookUrl list
        let names = RuleParser.getStrings(from: body, rule: rules.name, baseURL: url)
        let urls = RuleParser.getStrings(from: body, rule: rules.bookUrl, baseURL: url)
        let authors = RuleParser.getStrings(from: body, rule: rules.author, baseURL: url)
        let intros = RuleParser.getStrings(from: body, rule: rules.intro, baseURL: url)
        let covers = RuleParser.getStrings(from: body, rule: rules.coverUrl, baseURL: url)
        guard !urls.isEmpty else { return [] }
        var out: [SourceSearchResult] = []
        for i in 0..<min(urls.count, 30) {
            let name = i < names.count ? names[i] : "未命名"
            let author = i < authors.count ? authors[i] : ""
            let intro = i < intros.count ? intros[i] : ""
            let cover = i < covers.count ? covers[i] : nil
            var bookUrl = urls[i]
            if !bookUrl.hasPrefix("http") {
                bookUrl = RuleParser.resolveURL(bookUrl, base: url)
            }
            out.append(SourceSearchResult(
                name: name,
                author: author,
                intro: intro,
                coverURL: cover,
                bookURL: bookUrl,
                sourceID: source.id,
                sourceName: source.name
            ))
        }
        return out
    }

    // MARK: - TOC

    static func fetchTOC(bookURL: String, source: BookSource) async throws -> [SourceChapterItem] {
        let rules = source.rules
        var tocURLString = source.tocURL.isEmpty ? bookURL : source.tocURL
        tocURLString = tocURLString
            .replacingOccurrences(of: "{{bookUrl}}", with: bookURL)
            .replacingOccurrences(of: "{bookUrl}", with: bookURL)
        if tocURLString.isEmpty { tocURLString = bookURL }
        guard let url = URL(string: tocURLString) else {
            throw BookSourceError.invalidURL
        }
        // If tocURL empty in rules, fetch book page and extract tocUrl then list
        var body = try await fetchString(url: url)
        if let tocRule = rules.tocUrl, !tocRule.isEmpty,
           let next = RuleParser.getString(from: body, rule: tocRule, baseURL: url),
           let nextURL = URL(string: next.hasPrefix("http") ? next : RuleParser.resolveURL(next, base: url)) {
            body = try await fetchString(url: nextURL)
            return parseChapters(body: body, base: nextURL, rules: rules)
        }
        return parseChapters(body: body, base: url, rules: rules)
    }

    private static func parseChapters(body: String, base: URL, rules: ParseRule) -> [SourceChapterItem] {
        let blocks = RuleParser.getStrings(from: body, rule: rules.chapterList, baseURL: base)
        var items: [SourceChapterItem] = []
        if blocks.isEmpty {
            let names = RuleParser.getStrings(from: body, rule: rules.chapterName, baseURL: base)
            let urls = RuleParser.getStrings(from: body, rule: rules.chapterUrl, baseURL: base)
            for i in 0..<min(urls.count, 5000) {
                let title = i < names.count ? names[i] : "第\(i + 1)章"
                var u = urls[i]
                if !u.hasPrefix("http") { u = RuleParser.resolveURL(u, base: base) }
                items.append(SourceChapterItem(title: title, url: u, index: i))
            }
            return items
        }
        for (i, block) in blocks.prefix(5000).enumerated() {
            let title = RuleParser.getString(from: block, rule: rules.chapterName, baseURL: base) ?? "第\(i + 1)章"
            var u = RuleParser.getString(from: block, rule: rules.chapterUrl, baseURL: base) ?? ""
            if u.isEmpty { continue }
            if !u.hasPrefix("http") { u = RuleParser.resolveURL(u, base: base) }
            items.append(SourceChapterItem(title: title, url: u, index: i))
        }
        return items
    }

    // MARK: - Content

    static func fetchContent(chapterURL: String, source: BookSource) async throws -> String {
        let rules = source.rules
        var urlString = source.contentURL.isEmpty ? chapterURL : source.contentURL
        urlString = urlString
            .replacingOccurrences(of: "{{chapterUrl}}", with: chapterURL)
            .replacingOccurrences(of: "{chapterUrl}", with: chapterURL)
        if urlString.isEmpty { urlString = chapterURL }
        guard let url = URL(string: urlString) else { throw BookSourceError.invalidURL }
        let body = try await fetchString(url: url)
        var text = RuleParser.getString(from: body, rule: rules.content, baseURL: url)
            ?? RuleParser.stripTags(body)
        text = RuleParser.applyReplacements(text, replaceRegex: rules.replaceRegex)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Validate source

    static func validate(_ source: BookSource, keyword: String = "修仙") async -> Bool {
        do {
            let results = try await searchOne(keyword: keyword, source: source, page: 1)
            return !results.isEmpty
        } catch {
            return false
        }
    }

    // MARK: - Import book fully

    static func downloadBook(
        result: SourceSearchResult,
        source: BookSource,
        into context: ModelContext,
        maxChapters: Int = 500
    ) async throws -> Book {
        let chapters = try await fetchTOC(bookURL: result.bookURL, source: source)
        let limited = Array(chapters.prefix(maxChapters))
        var chapterModels: [Chapter] = []
        for (i, item) in limited.enumerated() {
            // 控制并发：串行拉取避免封禁
            let content: String
            do {
                content = try await fetchContent(chapterURL: item.url, source: source)
            } catch {
                content = ""
            }
            let ch = Chapter(index: i, title: item.title, content: content.isEmpty ? "（正文获取失败）" : content)
            chapterModels.append(ch)
            // 轻微间隔
            if i % 5 == 4 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let book = Book(
            title: result.name,
            author: result.author,
            sourceType: .booksource,
            sourceName: result.sourceName,
            sourceURL: result.bookURL,
            format: .online,
            totalChapters: chapterModels.count
        )
        book.chapters = chapterModels
        for ch in chapterModels { ch.book = book }
        context.insert(book)
        try context.save()
        return book
    }

    // MARK: - Network

    private static func fetchString(url: URL) async throws -> String {
        var lastError: Error = BookSourceError.network
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw BookSourceError.httpStatus(http.statusCode)
                }
                // encoding
                if let s = String(data: data, encoding: .utf8) { return s }
                if let s = String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
                    return s
                }
                return String(decoding: data, as: UTF8.self)
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError
    }

    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

enum BookSourceError: LocalizedError {
    case invalidURL
    case network
    case httpStatus(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidURL: return String(localized: "书源 URL 无效")
        case .network: return String(localized: "网络请求失败")
        case .httpStatus(let c): return String(localized: "HTTP \(c)")
        case .empty: return String(localized: "无结果")
        }
    }
}
