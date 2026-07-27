import Foundation
import SwiftData

/// 多格式书源导入：Legado / 爱阅记 / PureReader JSON
enum BookSourceImporter {
    private static let maxDownloadBytes = 10 * 1024 * 1024

    struct ImportResult: Sendable {
        var changed: Int
        var enabled: Int
        var disabled: Int

        var message: String {
            if disabled > 0 {
                return String(localized: "已导入或更新 \(changed) 个书源，其中 \(enabled) 个可启用，\(disabled) 个因兼容性限制已停用")
            }
            return String(localized: "成功导入或更新 \(changed) 个书源")
        }
    }

    // MARK: - Public

    @MainActor
    static func importJSON(_ data: Data, into context: ModelContext) throws -> ImportResult {
        let data = normalizedJSONData(data)
        let root = try JSONSerialization.jsonObject(with: data)
        let objects: [[String: Any]]
        if let array = root as? [[String: Any]] {
            objects = array
        } else if let object = root as? [String: Any] {
            objects = [object]
        } else {
            throw ImportError.invalidFormat
        }

        let candidates = objects.compactMap { try? parseOne($0) }
        guard !candidates.isEmpty else { throw ImportError.noValidSources }

        let existing = (try? context.fetch(FetchDescriptor<BookSource>())) ?? []
        var existingByKey: [String: BookSource] = [:]
        var duplicateExisting: [BookSource] = []
        for source in existing {
            let key = identityKey(source)
            if existingByKey[key] == nil {
                existingByKey[key] = source
            } else {
                duplicateExisting.append(source)
            }
        }
        var changed = 0
        do {
            for candidate in candidates {
                let key = identityKey(candidate)
                let legacyMatch = existing.first { current in
                    current.formatRaw == candidate.formatRaw
                        && current.name.caseInsensitiveCompare(candidate.name) == .orderedSame
                        && current.searchURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            == candidate.searchURL.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let current = existingByKey[key] ?? legacyMatch {
                    update(current, from: candidate)
                    existingByKey[key] = current
                } else {
                    context.insert(candidate)
                    existingByKey[key] = candidate
                }
                changed += 1
            }
            for duplicate in duplicateExisting {
                context.delete(duplicate)
            }
            try context.save()
            return ImportResult(
                changed: changed,
                enabled: candidates.filter { $0.enabled && $0.isValid }.count,
                disabled: candidates.filter { !$0.enabled || !$0.isValid }.count
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    @MainActor
    static func importFromURL(_ url: URL, into context: ModelContext) async throws -> ImportResult {
        guard url.scheme?.lowercased() == "https" else {
            throw ImportError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                + "AppleWebKit/605.1.15 Mobile/15E148 PureReader/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await download(request)
        guard let http = response as? HTTPURLResponse else {
            throw ImportError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ImportError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw ImportError.emptyResponse }
        guard data.count <= maxDownloadBytes else { throw ImportError.responseTooLarge }
        return try importJSON(data, into: context)
    }

    private static func download(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse {
                    guard (200...299).contains(http.statusCode) else {
                        throw ImportError.httpStatus(http.statusCode)
                    }
                    if let length = http.value(forHTTPHeaderField: "Content-Length"),
                       let byteCount = Int(length), byteCount > maxDownloadBytes {
                        throw ImportError.responseTooLarge
                    }
                }

                var data = Data()
                data.reserveCapacity(min(response.expectedContentLength > 0
                    ? Int(response.expectedContentLength)
                    : 256 * 1024, maxDownloadBytes))
                for try await byte in bytes {
                    guard data.count < maxDownloadBytes else {
                        throw ImportError.responseTooLarge
                    }
                    data.append(byte)
                }
                return (data, response)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ImportError {
                throw error
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 400_000_000)
                }
            }
        }
        throw ImportError.downloadFailed(
            lastError?.localizedDescription ?? String(localized: "未知网络错误")
        )
    }

    private static func normalizedJSONData(_ data: Data) -> Data {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        guard var text = String(data: bytes, encoding: .utf8) else { return bytes }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 部分代理或托管服务会添加常见的 JSON 防劫持前缀。
        for prefix in [")]}'", "while(1);"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.data(using: .utf8) ?? bytes
    }

    private static func identityKey(_ source: BookSource) -> String {
        let base = sanitizedBaseURL(source.bookURL).lowercased()
        let fallback = source.searchURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return source.formatRaw + "|" + (base.isEmpty ? source.name.lowercased() + "|" + fallback : base)
    }

    private static func update(_ target: BookSource, from source: BookSource) {
        target.name = source.name
        target.groupName = source.groupName
        target.searchURL = source.searchURL
        target.bookURL = source.bookURL
        target.tocURL = source.tocURL
        target.contentURL = source.contentURL
        target.ruleJSON = source.ruleJSON
        target.enabled = source.enabled
        target.formatRaw = source.formatRaw
        target.isValid = source.isValid
        target.comment = source.comment
        target.weight = source.weight
    }

    private static func sanitizedBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutMetadata = trimmed.components(separatedBy: "##").first ?? trimmed
        return withoutMetadata.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func compatibilityIssue(
        searchURL: String,
        object: [String: Any]
    ) -> String? {
        let lower = searchURL.lowercased()
        if lower.contains("@js:") || lower.contains("<js>") || lower.contains("</js>") {
            return String(localized: "包含 JavaScript 搜索逻辑")
        }
        if bool(object, "enabledCookieJar") == true,
           lower.contains("webview") || lower.contains("startbrowser") {
            return String(localized: "依赖 WebView/Cookie 验证")
        }
        guard requestDescriptor(searchURL, baseURL: sanitizedBaseURL(string(object, "bookSourceUrl") ?? "")) != nil else {
            return String(localized: "搜索请求格式暂不支持")
        }

        guard let searchRules = object["ruleSearch"] as? [String: Any],
              string(searchRules, "bookList") != nil,
              string(searchRules, "name") != nil,
              string(searchRules, "bookUrl") != nil else {
            return String(localized: "缺少搜索列表、书名或详情地址规则")
        }
        let ruleValues = searchRules.values.compactMap { $0 as? String }
        if ruleValues.contains(where: {
            $0.contains("@js:") || $0.contains("<js>")
                || $0.contains("@put:") || $0.contains("@get:")
        }) {
            return String(localized: "解析规则包含 JavaScript")
        }
        if ruleValues.contains(where: { rule in
            let lowerRule = rule.lowercased()
            return lowerRule.hasPrefix("//")
                || lowerRule.contains("@xpath:")
        }) {
            return String(localized: "搜索规则使用了 XPath")
        }
        return nil
    }

    private static func readingCompatibilityIssue(_ object: [String: Any]) -> String? {
        let ruleObjects = ["ruleBookInfo", "ruleToc", "ruleContent"]
            .compactMap { object[$0] as? [String: Any] }
        let values = ruleObjects.flatMap { $0.values.compactMap { $0 as? String } }
        if values.contains(where: {
            let lower = $0.lowercased()
            return lower.contains("@js:") || lower.contains("<js>")
                || lower.contains("webview") || lower.contains("@put:") || lower.contains("@get:")
        }) {
            return String(localized: "目录或正文依赖脚本/WebView")
        }
        return nil
    }

    private static func requestDescriptor(_ raw: String, baseURL: String) -> (url: URL, method: String)? {
        let path = raw.components(separatedBy: ",{").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved: URL?
        if let absolute = URL(string: path), absolute.scheme != nil {
            resolved = absolute
        } else if let base = URL(string: baseURL) {
            resolved = URL(string: path, relativeTo: base)?.absoluteURL
        } else {
            resolved = nil
        }
        guard let url = resolved, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        let method = raw.range(of: #"['\"]method['\"]\s*:\s*['\"]post['\"]"#, options: [.regularExpression, .caseInsensitive]) == nil
            ? "GET"
            : "POST"
        return (url, method)
    }

    private static func appendCompatibilityNote(_ comment: String, issue: String) -> String {
        let note = String(localized: "PureReader 暂不兼容：\(issue)。该书源已自动停用。")
        return comment.isEmpty ? note : comment + "\n\n" + note
    }

    private static func appendPartialCompatibilityNote(_ comment: String, issue: String) -> String {
        let note = String(localized: "PureReader 部分兼容：\(issue)。可显示搜索结果，但加入书架可能失败。")
        return comment.isEmpty ? note : comment + "\n\n" + note
    }

    static func exportJSON(sources: [BookSource]) throws -> Data {
        let payloads: [[String: Any]] = sources.map { s in
            [
                "name": s.name,
                "group": s.groupName,
                "searchUrl": s.searchURL,
                "bookUrl": s.bookURL,
                "tocUrl": s.tocURL,
                "contentUrl": s.contentURL,
                "enabled": s.enabled,
                "format": s.format.rawValue,
                "comment": s.comment,
                "weight": s.weight,
                "ruleSearch": ruleDict(s.rules, kind: .search),
                "ruleBookInfo": ruleDict(s.rules, kind: .info),
                "ruleToc": ruleDict(s.rules, kind: .toc),
                "ruleContent": ruleDict(s.rules, kind: .content)
            ]
        }
        return try JSONSerialization.data(withJSONObject: payloads, options: [.prettyPrinted, .sortedKeys])
    }

    /// 内置示例书源（演示规则结构；站点可用性不保证）
    static func seedBuiltInIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<BookSource>()
        let existing = (try? context.fetch(descriptor)) ?? []
        if !existing.isEmpty { return }

        // PureReader 演示书源：指向本地可解析的静态 HTML 模板风格规则
        // 实际用户可导入社区 JSON
        let demo = BookSource(
            name: String(localized: "示例书源（需自行导入可用源）"),
            groupName: String(localized: "内置"),
            searchURL: "https://www.example.com/search?q={{key}}&page={{page}}",
            bookURL: "",
            tocURL: "",
            contentURL: "",
            rules: ParseRule(
                bookList: "div.book-item",
                name: "h3@text||a@text",
                author: "span.author@text",
                intro: "p.intro@text",
                coverUrl: "img@src",
                bookUrl: "a@href",
                tocUrl: nil,
                chapterList: "ul.chapters li",
                chapterName: "a@text",
                chapterUrl: "a@href",
                content: "div#content@text||div.content@text",
                nextPage: nil,
                replaceRegex: nil
            ),
            enabled: false,
            format: .pureReader,
            comment: String(localized: "占位示例，默认禁用。请从社区导入可用书源。"),
            weight: 0
        )
        context.insert(demo)
        try? context.save()
    }

    // MARK: - Parse one

    private static func parseOne(_ obj: [String: Any]) throws -> BookSource {
        // 判定格式
        if string(obj, "format") == BookSourceFormat.pureReader.rawValue {
            return try parsePureReader(obj)
        }
        if obj["bookSourceName"] != nil || obj["bookSourceUrl"] != nil {
            return try parseLegado(obj)
        }
        if obj["search_url"] != nil || obj["host"] != nil {
            return try parseAiYueJi(obj)
        }
        if obj["name"] != nil,
           obj["searchURL"] != nil || obj["searchUrl"] != nil
                || obj["rules"] != nil || obj["ruleSearch"] != nil {
            return try parsePureReader(obj)
        }
        throw ImportError.invalidFormat
    }

    private static func parseLegado(_ obj: [String: Any]) throws -> BookSource {
        guard let name = string(obj, "bookSourceName") ?? string(obj, "name"),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.invalidFormat
        }
        let group = string(obj, "bookSourceGroup") ?? string(obj, "group") ?? ""
        let search = string(obj, "searchUrl") ?? ""
        let baseURL = sanitizedBaseURL(string(obj, "bookSourceUrl") ?? "")
        guard !search.isEmpty, !baseURL.isEmpty else { throw ImportError.invalidFormat }
        let comment = string(obj, "bookSourceComment") ?? string(obj, "comment") ?? ""
        let compatibility = compatibilityIssue(searchURL: search, object: obj)
        let readingIssue = readingCompatibilityIssue(obj)
        let enabled = (bool(obj, "enabled") ?? true) && compatibility == nil
        let weight = int(obj, "customOrder") ?? int(obj, "weight") ?? 0

        var rules = ParseRule()
        if let rs = obj["ruleSearch"] as? [String: Any] {
            rules.bookList = string(rs, "bookList")
            rules.name = string(rs, "name")
            rules.author = string(rs, "author")
            rules.intro = string(rs, "intro")
            rules.coverUrl = string(rs, "coverUrl")
            rules.bookUrl = string(rs, "bookUrl")
        }
        if let ri = obj["ruleBookInfo"] as? [String: Any] {
            rules.tocUrl = string(ri, "tocUrl") ?? rules.tocUrl
            rules.intro = rules.intro ?? string(ri, "intro")
            rules.coverUrl = rules.coverUrl ?? string(ri, "coverUrl")
            rules.name = rules.name ?? string(ri, "name")
            rules.author = rules.author ?? string(ri, "author")
        }
        if let rt = obj["ruleToc"] as? [String: Any] {
            rules.chapterList = string(rt, "chapterList")
            rules.chapterName = string(rt, "chapterName")
            rules.chapterUrl = string(rt, "chapterUrl")
        }
        if let rc = obj["ruleContent"] as? [String: Any] {
            rules.content = string(rc, "content")
            rules.nextPage = string(rc, "nextContentUrl")
            rules.replaceRegex = string(rc, "replaceRegex")
        }

        let source = BookSource(
            name: name,
            groupName: group,
            searchURL: search,
            bookURL: baseURL,
            tocURL: "",
            contentURL: "",
            rules: rules,
            enabled: enabled,
            format: .legado,
            comment: compatibility.map { appendCompatibilityNote(comment, issue: $0) }
                ?? readingIssue.map { appendPartialCompatibilityNote(comment, issue: $0) }
                ?? comment,
            weight: weight
        )
        source.isValid = compatibility == nil
        return source
    }

    private static func parseAiYueJi(_ obj: [String: Any]) throws -> BookSource {
        guard let name = string(obj, "name") ?? string(obj, "title") else {
            throw ImportError.invalidFormat
        }
        let host = string(obj, "host") ?? ""
        let search = string(obj, "search_url") ?? string(obj, "searchUrl") ?? (host + "/search?q={{key}}")
        var rules = ParseRule()
        rules.bookList = string(obj, "search_list") ?? string(obj, "bookList")
        rules.name = string(obj, "search_name") ?? string(obj, "name_rule")
        rules.author = string(obj, "search_author")
        rules.bookUrl = string(obj, "search_url_rule") ?? string(obj, "book_url")
        rules.chapterList = string(obj, "toc_list")
        rules.chapterName = string(obj, "toc_name")
        rules.chapterUrl = string(obj, "toc_url")
        rules.content = string(obj, "content")
        guard !search.isEmpty else { throw ImportError.invalidFormat }
        return BookSource(
            name: name,
            groupName: string(obj, "group") ?? "爱阅记",
            searchURL: search,
            rules: rules,
            enabled: bool(obj, "enabled") ?? true,
            format: .aiYueJi,
            comment: string(obj, "comment") ?? ""
        )
    }

    private static func parsePureReader(_ obj: [String: Any]) throws -> BookSource {
        guard let name = string(obj, "name"), !name.isEmpty else {
            throw ImportError.invalidFormat
        }
        var rules = ParseRule()
        if let r = obj["rules"] as? [String: Any] {
            rules = rulesFromDict(r)
        } else if let r = obj["ruleSearch"] as? [String: Any] {
            rules = rulesFromDict(r)
            if let info = obj["ruleBookInfo"] as? [String: Any] {
                rules.tocUrl = string(info, "tocUrl")
                rules.intro = rules.intro ?? string(info, "intro")
                rules.coverUrl = rules.coverUrl ?? string(info, "coverUrl")
            }
            if let toc = obj["ruleToc"] as? [String: Any] {
                rules.chapterList = string(toc, "chapterList")
                rules.chapterName = string(toc, "chapterName")
                rules.chapterUrl = string(toc, "chapterUrl")
            }
            if let content = obj["ruleContent"] as? [String: Any] {
                rules.content = string(content, "content")
                rules.nextPage = string(content, "nextContentUrl")
                rules.replaceRegex = string(content, "replaceRegex")
            }
        } else {
            // flat
            rules.bookList = string(obj, "bookList")
            rules.name = string(obj, "nameRule")
            rules.author = string(obj, "authorRule")
            rules.bookUrl = string(obj, "bookUrlRule")
            rules.chapterList = string(obj, "chapterList")
            rules.chapterName = string(obj, "chapterName")
            rules.chapterUrl = string(obj, "chapterUrl")
            rules.content = string(obj, "contentRule")
        }
        let searchURL = string(obj, "searchUrl") ?? string(obj, "searchURL") ?? ""
        guard !searchURL.isEmpty, rules.name != nil, rules.bookUrl != nil else {
            throw ImportError.invalidFormat
        }
        return BookSource(
            name: name,
            groupName: string(obj, "group") ?? "",
            searchURL: searchURL,
            bookURL: string(obj, "bookUrl") ?? "",
            tocURL: string(obj, "tocUrl") ?? "",
            contentURL: string(obj, "contentUrl") ?? "",
            rules: rules,
            enabled: bool(obj, "enabled") ?? true,
            format: .pureReader,
            comment: string(obj, "comment") ?? "",
            weight: int(obj, "weight") ?? 0
        )
    }

    private enum RuleKind { case search, info, toc, content }

    private static func ruleDict(_ r: ParseRule, kind: RuleKind) -> [String: Any] {
        switch kind {
        case .search:
            return compact([
                "bookList": r.bookList,
                "name": r.name,
                "author": r.author,
                "intro": r.intro,
                "coverUrl": r.coverUrl,
                "bookUrl": r.bookUrl
            ])
        case .info:
            return compact(["tocUrl": r.tocUrl, "intro": r.intro, "coverUrl": r.coverUrl])
        case .toc:
            return compact([
                "chapterList": r.chapterList,
                "chapterName": r.chapterName,
                "chapterUrl": r.chapterUrl
            ])
        case .content:
            return compact([
                "content": r.content,
                "nextContentUrl": r.nextPage,
                "replaceRegex": r.replaceRegex
            ])
        }
    }

    private static func rulesFromDict(_ r: [String: Any]) -> ParseRule {
        ParseRule(
            bookList: string(r, "bookList"),
            name: string(r, "name"),
            author: string(r, "author"),
            intro: string(r, "intro"),
            coverUrl: string(r, "coverUrl"),
            bookUrl: string(r, "bookUrl"),
            tocUrl: string(r, "tocUrl"),
            chapterList: string(r, "chapterList"),
            chapterName: string(r, "chapterName"),
            chapterUrl: string(r, "chapterUrl"),
            content: string(r, "content"),
            nextPage: string(r, "nextPage"),
            replaceRegex: string(r, "replaceRegex")
        )
    }

    private static func compact(_ dict: [String: String?]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            if let v, !v.isEmpty { out[k] = v }
        }
        return out
    }

    private static func string(_ obj: [String: Any], _ key: String) -> String? {
        if let s = obj[key] as? String { return s }
        if let n = obj[key] as? NSNumber { return n.stringValue }
        return nil
    }

    private static func bool(_ obj: [String: Any], _ key: String) -> Bool? {
        if let b = obj[key] as? Bool { return b }
        if let n = obj[key] as? NSNumber { return n.boolValue }
        if let s = obj[key] as? String {
            return s == "1" || s.lowercased() == "true"
        }
        return nil
    }

    private static func int(_ obj: [String: Any], _ key: String) -> Int? {
        if let i = obj[key] as? Int { return i }
        if let n = obj[key] as? NSNumber { return n.intValue }
        if let s = obj[key] as? String { return Int(s) }
        return nil
    }

    enum ImportError: LocalizedError {
        case invalidFormat
        case noValidSources
        case invalidURL
        case invalidResponse
        case httpStatus(Int)
        case emptyResponse
        case responseTooLarge
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return String(localized: "无法识别的书源 JSON 格式")
            case .noValidSources:
                return String(localized: "JSON 中没有可导入的有效书源")
            case .invalidURL:
                return String(localized: "书源地址无效，仅支持 HTTPS")
            case .invalidResponse:
                return String(localized: "书源服务器返回了无效响应")
            case .httpStatus(let code):
                return String(localized: "书源下载失败：HTTP \(code)")
            case .emptyResponse:
                return String(localized: "书源地址返回了空内容")
            case .responseTooLarge:
                return String(localized: "书源文件超过 10 MB，已停止导入")
            case .downloadFailed(let message):
                return String(localized: "书源下载失败：\(message)")
            }
        }
    }
}
