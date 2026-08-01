import Foundation
import SwiftData

struct BookSourceSearchFailure: Sendable {
    var sourceID: UUID
    var sourceName: String
    var reason: String
    var verificationURL: URL? = nil
}

struct BookSourceSearchReport: Sendable {
    var results: [SourceSearchResult]
    var attemptedCount: Int
    var failures: [BookSourceSearchFailure]
}

struct BookSourceValidationResult: Sendable {
    var isReachable: Bool
    var resultCount: Int
    var message: String
}

/// `BookSource` 的值语义快照。
///
/// `BookSource` 是 SwiftData `@Model`，只能在其所属 context 的 actor 上访问。网络抓取跑在
/// 任意执行器上，因此所有跨越 await 的读取都必须先在调用方（主 actor）取快照。
struct BookSourceSnapshot: Sendable {
    var id: UUID
    var name: String
    var searchURL: String
    var exploreURL: String
    var bookURL: String
    var tocURL: String
    var contentURL: String
    var headerJSON: String
    var rules: ParseRule
    var exploreRules: ParseRule

    @MainActor
    init(_ source: BookSource) {
        id = source.id
        name = source.name
        searchURL = source.searchURL
        exploreURL = source.exploreURL
        bookURL = source.bookURL
        tocURL = source.tocURL
        contentURL = source.contentURL
        headerJSON = source.headerJSON
        rules = source.rules
        exploreRules = source.exploreRules
    }
}

/// 书源网络引擎：搜索 / 目录 / 正文（15s 超时 + 最多 2 次重试）
enum BookSourceEngine {
    private struct SearchBatch: Sendable {
        var results: [SourceSearchResult]
        var failure: BookSourceSearchFailure?
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 PureReader/1.0",
            // A few older book-source servers advertise broken gzip/br encodings.
            // Asking for identity avoids CFNetwork decode/parse failures (often code 303).
            "Accept-Encoding": "identity",
            "Accept-Language": "zh-CN,zh-Hans;q=0.9,en;q=0.5"
        ]
        return URLSession(configuration: c)
    }()

    // MARK: - Search

    @MainActor
    static func search(
        keyword: String,
        sources: [BookSource],
        page: Int = 1
    ) async -> BookSourceSearchReport {
        // isValid is a health indicator, not a permanent block. A user can retry a
        // previously failed source without having to re-import it first.
        let enabled = sources.filter { $0.enabled && !$0.searchURL.isEmpty }
        return await search(
            keyword: keyword,
            snapshots: enabled.map { BookSourceSnapshot($0) },
            page: page
        )
    }

    static func search(
        keyword: String,
        snapshots searchable: [BookSourceSnapshot],
        page: Int = 1
    ) async -> BookSourceSearchReport {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !searchable.isEmpty else {
            return BookSourceSearchReport(results: [], attemptedCount: 0, failures: [])
        }

        return await withTaskGroup(of: SearchBatch.self) { group in
            for source in searchable {
                group.addTask {
                    do {
                        return SearchBatch(
                            results: try await searchOne(keyword: key, source: source, page: page),
                            failure: nil
                        )
                    } catch is CancellationError {
                        return SearchBatch(results: [], failure: nil)
                    } catch {
                        return SearchBatch(
                            results: [],
                            failure: BookSourceSearchFailure(
                                sourceID: source.id,
                                sourceName: source.name,
                                reason: error.localizedDescription,
                                verificationURL: verificationURL(from: error)
                            )
                        )
                    }
                }
            }
            var all: [SourceSearchResult] = []
            var failures: [BookSourceSearchFailure] = []
            for await batch in group {
                all.append(contentsOf: batch.results)
                if let failure = batch.failure {
                    failures.append(failure)
                }
            }
            // 去重 by name+author
            var seen = Set<String>()
            let unique = all.filter { r in
                let k = r.name + "|" + r.author
                if seen.contains(k) { return false }
                seen.insert(k)
                return true
            }
            return BookSourceSearchReport(
                results: unique,
                attemptedCount: searchable.count,
                failures: failures.sorted { $0.sourceName < $1.sourceName }
            )
        }
    }

    private static func searchOne(
        keyword: String,
        source: BookSourceSnapshot,
        page: Int
    ) async throws -> [SourceSearchResult] {
        guard let request = makeSearchRequest(
            raw: source.searchURL,
            baseURL: source.bookURL,
            keyword: keyword,
            page: page,
            sourceHeaderJSON: source.headerJSON
        ) else {
            throw BookSourceError.unsupportedRequest
        }
        guard let url = request.url else { throw BookSourceError.invalidURL }
        let body = try await fetchString(
            request: request,
            allowHTTPFallback: source.bookURL.hasPrefix("http://")
        )
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

    static func parseSearchFromRoot(
        body: String,
        url: URL,
        source: BookSourceSnapshot
    ) -> [SourceSearchResult] {
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

    // MARK: - Discover / categories

    static func exploreCategories(snapshots: [BookSourceSnapshot]) -> [SourceExploreCategory] {
        var categories: [SourceExploreCategory] = []
        var seen = Set<String>()
        for source in snapshots where !source.exploreURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for entry in parseExploreEntries(source.exploreURL, baseURL: source.bookURL) {
                let key = source.id.uuidString + "|" + entry.title + "|" + entry.url
                guard seen.insert(key).inserted else { continue }
                categories.append(SourceExploreCategory(
                    title: entry.title,
                    url: entry.url,
                    sourceID: source.id,
                    sourceName: source.name
                ))
            }
        }
        return categories
    }

    static func discover(
        categories: [SourceExploreCategory],
        snapshots: [BookSourceSnapshot],
        page: Int = 1
    ) async -> BookSourceSearchReport {
        let sourceByID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let usable = categories.compactMap { category -> (SourceExploreCategory, BookSourceSnapshot)? in
            guard let source = sourceByID[category.sourceID] else { return nil }
            return (category, source)
        }
        guard !usable.isEmpty else {
            return BookSourceSearchReport(results: [], attemptedCount: 0, failures: [])
        }

        return await withTaskGroup(of: SearchBatch.self) { group in
            for (category, source) in usable {
                group.addTask {
                    do {
                        var exploreSource = source
                        exploreSource.searchURL = category.url
                        exploreSource.rules = source.exploreRules
                        return SearchBatch(
                            results: try await searchOne(keyword: "", source: exploreSource, page: page),
                            failure: nil
                        )
                    } catch is CancellationError {
                        return SearchBatch(results: [], failure: nil)
                    } catch {
                        return SearchBatch(
                            results: [],
                            failure: BookSourceSearchFailure(
                                sourceID: source.id,
                                sourceName: source.name,
                                reason: error.localizedDescription,
                                verificationURL: verificationURL(from: error)
                            )
                        )
                    }
                }
            }
            var all: [SourceSearchResult] = []
            var failures: [BookSourceSearchFailure] = []
            for await batch in group {
                all.append(contentsOf: batch.results)
                if let failure = batch.failure { failures.append(failure) }
            }
            var seen = Set<String>()
            let unique = all.filter { seen.insert($0.name + "|" + $0.author).inserted }
            return BookSourceSearchReport(
                results: unique,
                attemptedCount: usable.count,
                failures: failures.sorted { $0.sourceName < $1.sourceName }
            )
        }
    }

    private static func parseExploreEntries(
        _ raw: String,
        baseURL: String
    ) -> [(title: String, url: String)] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "&&")
            .replacingOccurrences(of: "\n", with: "&&")
        let parts = normalized.components(separatedBy: "&&")
        var output: [(String, String)] = []
        for (offset, part) in parts.enumerated() {
            let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { continue }
            let title: String
            let path: String
            if let separator = item.range(of: "::") {
                title = String(item[..<separator.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                path = String(item[separator.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                title = offset == 0 ? String(localized: "推荐") : String(localized: "分类 \(offset + 1)")
                path = item
            }
            guard !path.isEmpty else { continue }
            let resolved: String
            if let url = URL(string: path), url.scheme != nil {
                resolved = path
            } else if let base = URL(string: baseURL.hasSuffix("/") ? baseURL : baseURL + "/"),
                      let absolute = URL(string: path, relativeTo: base)?.absoluteURL {
                resolved = absolute.absoluteString
            } else {
                continue
            }
            output.append((title.isEmpty ? String(localized: "推荐") : title, resolved))
        }
        return output
    }

    // MARK: - TOC

    @MainActor
    static func fetchTOC(bookURL: String, source: BookSource) async throws -> [SourceChapterItem] {
        try await fetchTOC(bookURL: bookURL, source: BookSourceSnapshot(source))
    }

    static func fetchTOC(
        bookURL: String,
        source: BookSourceSnapshot
    ) async throws -> [SourceChapterItem] {
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
        var body = try await fetchString(
            url: url,
            sourceHeaderJSON: source.headerJSON,
            allowHTTPFallback: source.bookURL.hasPrefix("http://")
        )
        if let tocRule = rules.tocUrl, !tocRule.isEmpty,
           let next = RuleParser.getString(from: body, rule: tocRule, baseURL: url),
           let nextURL = URL(string: next.hasPrefix("http") ? next : RuleParser.resolveURL(next, base: url)) {
            body = try await fetchString(
                url: nextURL,
                sourceHeaderJSON: source.headerJSON,
                allowHTTPFallback: source.bookURL.hasPrefix("http://")
            )
            return parseChapters(body: body, base: nextURL, rules: rules)
        }
        return parseChapters(body: body, base: url, rules: rules)
    }

    static func parseChapters(body: String, base: URL, rules: ParseRule) -> [SourceChapterItem] {
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

    @MainActor
    static func fetchContent(chapterURL: String, source: BookSource) async throws -> String {
        try await fetchContent(chapterURL: chapterURL, source: BookSourceSnapshot(source))
    }

    static func fetchContent(
        chapterURL: String,
        source: BookSourceSnapshot
    ) async throws -> String {
        let rules = source.rules
        var urlString = source.contentURL.isEmpty ? chapterURL : source.contentURL
        urlString = urlString
            .replacingOccurrences(of: "{{chapterUrl}}", with: chapterURL)
            .replacingOccurrences(of: "{chapterUrl}", with: chapterURL)
        if urlString.isEmpty { urlString = chapterURL }
        guard let url = URL(string: urlString) else { throw BookSourceError.invalidURL }
        let body = try await fetchString(
            url: url,
            sourceHeaderJSON: source.headerJSON,
            allowHTTPFallback: source.bookURL.hasPrefix("http://")
        )
        var text = RuleParser.getString(from: body, rule: rules.content, baseURL: url)
            ?? RuleParser.stripTags(body)
        text = RuleParser.applyReplacements(text, replaceRegex: rules.replaceRegex)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Validate source

    @MainActor
    static func validate(_ source: BookSource, keyword: String = "修仙") async -> Bool {
        (await validateDetailed(source, keyword: keyword)).isReachable
    }

    @MainActor
    static func validateDetailed(
        _ source: BookSource,
        keyword: String = "修仙"
    ) async -> BookSourceValidationResult {
        await validateDetailed(BookSourceSnapshot(source), keyword: keyword)
    }

    static func validateDetailed(
        _ source: BookSourceSnapshot,
        keyword: String = "修仙"
    ) async -> BookSourceValidationResult {
        do {
            let results = try await searchOne(keyword: keyword, source: source, page: 1)
            if results.isEmpty {
                return BookSourceValidationResult(
                    isReachable: true,
                    resultCount: 0,
                    message: String(localized: "请求成功，但试搜索没有结果；书源保持启用")
                )
            }
            return BookSourceValidationResult(
                isReachable: true,
                resultCount: results.count,
                message: String(localized: "请求成功，解析到 \(results.count) 条结果")
            )
        } catch {
            return BookSourceValidationResult(
                isReachable: false,
                resultCount: 0,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Network

    private static func fetchString(
        url: URL,
        sourceHeaderJSON: String = "",
        allowHTTPFallback: Bool = false
    ) async throws -> String {
        var request = URLRequest(url: url)
        for (name, value) in parseHeaders(sourceHeaderJSON) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try await fetchString(request: request, allowHTTPFallback: allowHTTPFallback)
    }

    private static func fetchString(
        request initialRequest: URLRequest,
        allowHTTPFallback: Bool = false
    ) async throws -> String {
        var lastError: Error = BookSourceError.network
        var activeRequest = initialRequest
        var didTryHTTPFallback = false
        for attempt in 0..<3 {
            do {
                var request = activeRequest
                request.timeoutInterval = 15
                let (data, response) = try await session.data(for: request)
                if verificationChallenge(data: data, response: response, fallbackURL: request.url) {
                    throw BookSourceError.verificationRequired(response.url ?? request.url!)
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw BookSourceError.httpStatus(http.statusCode)
                }
                // encoding
                if let s = String(data: data, encoding: .utf8) { return s }
                if let s = String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
                    return s
                }
                return String(decoding: data, as: UTF8.self)
            } catch let error as BookSourceError {
                // Verification and HTTP status errors are deterministic; retrying only delays the prompt.
                throw error
            } catch {
                lastError = error
                // HTTPS 降级仅限书源显式配置 http:// 的情况（隐私/安全优先，
                // 避免搜索关键词走明文 + 中间人篡改）
                if allowHTTPFallback, !didTryHTTPFallback,
                   let fallback = httpFallbackRequest(for: activeRequest, after: error) {
                    activeRequest = fallback
                    didTryHTTPFallback = true
                    continue
                }
                if isBrowserRecoverableNetworkError(error), let url = activeRequest.url {
                    throw BookSourceError.verificationRequired(url)
                }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError
    }

    /// Some long-lived community sources still publish an HTTPS URL with an expired,
    /// untrusted, or malformed TLS endpoint while their HTTP endpoint remains usable
    /// (and may redirect to the site's current HTTPS host). For book-source traffic only,
    /// retry the same request over HTTP after a transport-level TLS/parser failure.
    private static func httpFallbackRequest(
        for request: URLRequest,
        after error: Error
    ) -> URLRequest? {
        guard request.url?.scheme?.lowercased() == "https",
              isTLSOrHTTPParseError(error),
              var components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return nil
        }
        components.scheme = "http"
        guard let url = components.url else { return nil }
        var fallback = request
        fallback.url = url
        return fallback
    }

    private static func isTLSOrHTTPParseError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return [
                NSURLErrorSecureConnectionFailed,
                NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid,
                NSURLErrorClientCertificateRejected,
                NSURLErrorClientCertificateRequired
            ].contains(ns.code)
        }
        // kCFErrorHTTPParseFailure. Several anti-bot gateways return malformed
        // interim responses that URLSession rejects before exposing a status code.
        return ns.domain == "kCFErrorDomainCFNetwork" && ns.code == 303
    }

    private static func isBrowserRecoverableNetworkError(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == "kCFErrorDomainCFNetwork" && ns.code == 303)
            || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCannotParseResponse)
    }

    private static func verificationURL(from error: Error) -> URL? {
        guard case BookSourceError.verificationRequired(let url) = error else { return nil }
        return url
    }

    private static func verificationChallenge(
        data: Data,
        response: URLResponse,
        fallbackURL: URL?
    ) -> Bool {
        if let http = response as? HTTPURLResponse, [401, 403, 429].contains(http.statusCode) {
            return true
        }
        let sample = data.prefix(64 * 1024)
        let text = String(decoding: sample, as: UTF8.self).lowercased()
        let markers = [
            "captcha", "cf-chl-", "challenge-platform", "verify you are human",
            "geetest", "__jsl_clearance", "_wa_=", "http-equiv=refresh content=0",
            "\u{4eba}\u{673a}\u{9a8c}\u{8bc1}", "\u{6ed1}\u{52a8}\u{9a8c}\u{8bc1}", "\u{8bbf}\u{95ee}\u{9a8c}\u{8bc1}", "\u{5b89}\u{5168}\u{9a8c}\u{8bc1}"
        ]
        return markers.contains { text.contains($0) } && (response.url ?? fallbackURL) != nil
    }

    static func canBuildSearchRequest(raw: String, baseURL: String) -> Bool {
        makeSearchRequest(
            raw: raw,
            baseURL: baseURL,
            keyword: "PureReader",
            page: 1,
            sourceHeaderJSON: ""
        ) != nil
    }

    private struct RequestOptions {
        var method = "GET"
        var body: String?
        var charset = "utf-8"
        var headers: [String: String] = [:]
    }

    private static func makeSearchRequest(
        raw: String,
        baseURL: String,
        keyword: String,
        page: Int,
        sourceHeaderJSON: String
    ) -> URLRequest? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !lower.contains("@js:"),
              !lower.contains("<js>"),
              !lower.contains("</js>") else {
            return nil
        }

        let separator = trimmed.range(
            of: #"\s*,\s*(?=\{)"#,
            options: .regularExpression
        )
        let pathTemplate = separator.map { String(trimmed[..<$0.lowerBound]) } ?? trimmed
        let descriptorTemplate = separator.map { String(trimmed[$0.upperBound...]) } ?? ""
        let descriptor = replacePlaceholders(
            in: descriptorTemplate,
            keyword: escapedJSONString(keyword),
            page: page
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let options = requestOptions(from: descriptor) else { return nil }

        // 关键词编码必须用书源声明的 charset。GBK/GB2312 站点走 GET 时，
        // 若按 UTF-8 百分号编码，中文关键词会变成站点无法识别的字节序列，
        // 搜索恒为空。descriptor 必须先解析出来才知道 charset。
        let path = replacePlaceholders(
            in: pathTemplate,
            keyword: percentEncodeQueryValue(
                keyword,
                encoding: stringEncoding(for: options.charset)
            ),
            page: page
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.contains("{{"), !path.contains("}}"),
              !descriptor.contains("{{"), !descriptor.contains("}}") else {
            return nil
        }
        let url: URL?
        if let absolute = URL(string: path), absolute.scheme != nil {
            url = absolute
        } else if let base = URL(string: baseURL.hasSuffix("/") ? baseURL : baseURL + "/") {
            url = URL(string: path, relativeTo: base)?.absoluteURL
        } else {
            url = nil
        }
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = options.method
        for (name, value) in parseHeaders(sourceHeaderJSON) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in options.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if options.method == "POST" {
            let body = options.body ?? ""
            let encoding = stringEncoding(for: options.charset)
            let contentType = request.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let preparedBody: String
            if contentType?.contains("application/x-www-form-urlencoded") == true {
                preparedBody = formEncoded(body, encoding: encoding)
            } else if contentType != nil {
                preparedBody = body
            } else if (trimmedBody.hasPrefix("{") && trimmedBody.hasSuffix("}"))
                        || (trimmedBody.hasPrefix("[") && trimmedBody.hasSuffix("]")) {
                preparedBody = body
                request.setValue(
                    "application/json; charset=\(options.charset)",
                    forHTTPHeaderField: "Content-Type"
                )
            } else if trimmedBody.hasPrefix("<") {
                preparedBody = body
                request.setValue(
                    "application/xml; charset=\(options.charset)",
                    forHTTPHeaderField: "Content-Type"
                )
            } else {
                preparedBody = formEncoded(body, encoding: encoding)
                request.setValue(
                    "application/x-www-form-urlencoded; charset=\(options.charset)",
                    forHTTPHeaderField: "Content-Type"
                )
            }
            guard let bodyData = preparedBody.data(using: encoding) else { return nil }
            request.httpBody = bodyData
        }
        return request
    }

    private static func requestOptions(from descriptor: String) -> RequestOptions? {
        guard !descriptor.isEmpty else { return RequestOptions() }
        if let data = descriptor.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let unsupportedKeys = ["js", "webJs", "bodyJs", "dnsIp", "type"]
            guard !unsupportedKeys.contains(where: { meaningfulValue(value($0, in: object)) }),
                  !isTruthy(value("webView", in: object)) else {
                return nil
            }
            var options = RequestOptions()
            options.method = stringValue(value("method", in: object))?.uppercased() ?? "GET"
            guard ["GET", "POST", "HEAD"].contains(options.method) else { return nil }
            options.charset = stringValue(value("charset", in: object))?.lowercased() ?? "utf-8"
            options.body = serializedValue(value("body", in: object))
            options.headers = parseHeaders(value("headers", in: object))
            return options
        }

        // A few older sources use single-quoted, non-strict JSON. This fallback
        // intentionally accepts only their simple string options.
        let method = captureValue("method", in: descriptor)?.uppercased()
        let body = captureValue("body", in: descriptor)
        let charset = captureValue("charset", in: descriptor)?.lowercased()
        let headers = captureHeaders(in: descriptor)
        guard method != nil || body != nil || charset != nil || !headers.isEmpty else {
            return nil
        }
        let resolvedMethod = method ?? "GET"
        guard ["GET", "POST", "HEAD"].contains(resolvedMethod) else { return nil }
        return RequestOptions(
            method: resolvedMethod,
            body: body,
            charset: charset ?? "utf-8",
            headers: headers
        )
    }

    static func parseHeaders(_ value: Any?) -> [String: String] {
        if let headers = value as? [String: Any] {
            return sanitizeHeaders(headers)
        }
        guard var text = value as? String else { return [:] }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [:] }
        if !text.hasPrefix("{") {
            text = "{" + text + "}"
        }
        guard let data = text.data(using: .utf8),
              let headers = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return sanitizeHeaders(headers)
    }

    private static func sanitizeHeaders<Value>(_ headers: [String: Value]) -> [String: String] {
        let blocked = Set(["host", "content-length", "connection", "transfer-encoding"])
        var result: [String: String] = [:]
        for (name, rawValue) in headers {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  !blocked.contains(trimmedName.lowercased()),
                  !trimmedName.contains("\r"), !trimmedName.contains("\n"),
                  let headerValue = stringValue(rawValue),
                  !headerValue.contains("\r"), !headerValue.contains("\n") else {
                continue
            }
            result[trimmedName] = headerValue
        }
        return result
    }

    private static func captureHeaders(in descriptor: String) -> [String: String] {
        guard let outer = try? NSRegularExpression(
            pattern: #"['\"]headers['\"]\s*:\s*\{([^}]*)\}"#,
            options: [.caseInsensitive]
        ),
        let match = outer.firstMatch(
            in: descriptor,
            range: NSRange(descriptor.startIndex..., in: descriptor)
        ),
        match.range(at: 1).location != NSNotFound else {
            return [:]
        }

        let body = (descriptor as NSString).substring(with: match.range(at: 1))
        guard let pairExpression = try? NSRegularExpression(
            pattern: #"['\"]([^'\"]+)['\"]\s*:\s*['\"]([^'\"]*)['\"]"#
        ) else { return [:] }

        var headers: [String: String] = [:]
        for pair in pairExpression.matches(
            in: body,
            range: NSRange(body.startIndex..., in: body)
        ) where pair.range(at: 1).location != NSNotFound
            && pair.range(at: 2).location != NSNotFound {
            let name = (body as NSString).substring(with: pair.range(at: 1))
            headers[name] = (body as NSString).substring(with: pair.range(at: 2))
        }
        return sanitizeHeaders(headers)
    }

    private static func captureValue(_ key: String, in descriptor: String) -> String? {
        guard !descriptor.isEmpty,
              let expression = try? NSRegularExpression(
                pattern: "['\"]\(NSRegularExpression.escapedPattern(for: key))['\"]\\s*:\\s*['\"]([^'\"]*)['\"]",
                options: [.caseInsensitive]
              ),
              let match = expression.firstMatch(
                in: descriptor,
                range: NSRange(descriptor.startIndex..., in: descriptor)
              ),
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return (descriptor as NSString).substring(with: match.range(at: 1))
    }

    private static func value(_ key: String, in object: [String: Any]) -> Any? {
        object.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    private static func meaningfulValue(_ value: Any?) -> Bool {
        guard let value else { return false }
        if value is NSNull { return false }
        if let text = value as? String {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private static func isTruthy(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            return !text.isEmpty && text.lowercased() != "false" && text != "0"
        }
        return false
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func serializedValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return stringValue(value)
        }
        return text
    }

    private static func replacePlaceholders(
        in template: String,
        keyword: String,
        page: Int
    ) -> String {
        template
            .replacingOccurrences(of: "{{key}}", with: keyword)
            .replacingOccurrences(of: "{{page}}", with: "\(page)")
            .replacingOccurrences(of: "{key}", with: keyword)
            .replacingOccurrences(of: "{page}", with: "\(page)")
    }

    private static func escapedJSONString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else {
            return value
        }
        return String(encoded.dropFirst().dropLast())
    }

    private static func percentEncodeQueryValue(
        _ value: String,
        encoding: String.Encoding = .utf8
    ) -> String {
        if encoding != .utf8 {
            // 非 UTF-8 站点：按目标编码取字节后逐字节百分号编码。
            guard let data = value.data(using: encoding) else {
                // 目标编码表示不了该关键词，退回 UTF-8 而不是让整个请求失败。
                return percentEncodeQueryValue(value)
            }
            let unreserved = Set(
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~".utf8
            )
            return data.map { byte in
                unreserved.contains(byte)
                    ? String(UnicodeScalar(byte))
                    : String(format: "%%%02X", byte)
            }.joined()
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func stringEncoding(for charset: String) -> String.Encoding {
        if charset.lowercased().contains("gb") {
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        }
        return .utf8
    }

    private static func formEncoded(_ body: String, encoding: String.Encoding) -> String {
        body.split(separator: "&", omittingEmptySubsequences: false).map { field in
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = percentEncodeFormComponent(String(parts[0]), encoding: encoding)
            guard parts.count == 2 else { return key }
            return key + "=" + percentEncodeFormComponent(String(parts[1]), encoding: encoding)
        }.joined(separator: "&")
    }

    private static func percentEncodeFormComponent(
        _ value: String,
        encoding: String.Encoding
    ) -> String {
        guard let data = value.data(using: encoding) else { return value }
        // RFC 1866 application/x-www-form-urlencoded unreserved：字母数字 + * - . _
        // 注意不能包含 %：否则关键词里已转义的序列会原样透传，服务端解码出错
        let unreserved = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._*".utf8)
        return data.map { byte in
            if unreserved.contains(byte) { return String(UnicodeScalar(byte)) }
            if byte == 0x20 { return "+" }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}

enum BookSourceError: LocalizedError {
    case invalidURL
    case network
    case httpStatus(Int)
    case empty
    case unsupportedRequest
    case verificationRequired(URL)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return String(localized: "书源 URL 无效")
        case .network: return String(localized: "网络请求失败")
        case .httpStatus(let c): return String(localized: "HTTP \(c)")
        case .empty: return String(localized: "无结果")
        case .unsupportedRequest: return String(localized: "该书源的请求格式暂不支持")
        case .verificationRequired: return String(localized: "\u{8be5}\u{4e66}\u{6e90}\u{9700}\u{8981}\u{5148}\u{5b8c}\u{6210}\u{4eba}\u{673a}\u{9a8c}\u{8bc1}")
        }
    }
}
