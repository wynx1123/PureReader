import Foundation
import SwiftData
import OSLog

extension Logger {
    static let bookSource = Logger(subsystem: "com.wynx.PureReader", category: "book-source")
}

/// 多格式书源导入：Legado / 爱阅记 / PureReader JSON
enum BookSourceImporter {
    static let maximumImportBytes = 10 * 1024 * 1024

    struct ImportResult: Sendable {
        var changed: Int
        var enabled: Int
        var disabled: Int
        var skipped: Int

        var message: String {
            let skippedNote = skipped > 0
                ? String(localized: "，另有 \(skipped) 个条目格式无效已跳过")
                : ""
            if disabled > 0 {
                return String(localized: "已导入或更新 \(changed) 个书源，其中 \(enabled) 个可启用，\(disabled) 个因兼容性限制已停用") + skippedNote
            }
            return String(localized: "成功导入或更新 \(changed) 个书源") + skippedNote
        }
    }

    // MARK: - Public

    static func readLocalJSON(from url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory == true { throw ImportError.invalidFormat }
        if let size = values.fileSize, size > maximumImportBytes {
            throw ImportError.responseTooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumImportBytes + 1) ?? Data()
        guard data.count <= maximumImportBytes else { throw ImportError.responseTooLarge }
        return data
    }

    @MainActor
    static func importJSON(_ data: Data, into context: ModelContext) throws -> ImportResult {
        let data = normalizedJSONData(data)
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw ImportError.invalidFormat
        }
        let objects = sourceObjects(from: root)
        guard !objects.isEmpty else { throw ImportError.invalidFormat }

        let parsedCandidates = objects.compactMap { try? parseOne($0) }
        let candidates = coalescedCandidates(parsedCandidates)
        guard !candidates.isEmpty else { throw ImportError.noValidSources }

        let existing = (try? context.fetch(FetchDescriptor<BookSource>())) ?? []
        var existingByKey: [String: BookSource] = [:]
        var duplicateExisting: [(duplicate: BookSource, retained: BookSource)] = []
        for source in existing {
            let key = identityKey(source)
            if let retained = existingByKey[key] {
                duplicateExisting.append((source, retained))
            } else {
                existingByKey[key] = source
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
            if !duplicateExisting.isEmpty {
                let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
                for pair in duplicateExisting {
                    for book in books where book.bookSourceID == pair.duplicate.id {
                        book.bookSourceID = pair.retained.id
                        book.sourceName = pair.retained.name
                    }
                    context.delete(pair.duplicate)
                }
            }
            try context.save()
            return ImportResult(
                changed: changed,
                enabled: candidates.filter { $0.enabled && $0.isValid }.count,
                disabled: candidates.filter { !$0.enabled || !$0.isValid }.count,
                skipped: objects.count - candidates.count
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    @MainActor
    static func importFromURL(_ url: URL, into context: ModelContext) async throws -> ImportResult {
        let url = normalizedRemoteURL(url)
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
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
        guard data.count <= maximumImportBytes else { throw ImportError.responseTooLarge }
        return try importJSON(data, into: context)
    }

    private static func normalizedRemoteURL(_ url: URL) -> URL {
        guard url.host?.lowercased() == "github.com" else { return url }
        let parts = url.pathComponents
        guard parts.count >= 6, parts[3].lowercased() == "blob" else { return url }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "raw.githubusercontent.com"
        let rawParts = [parts[1], parts[2]] + Array(parts.dropFirst(4))
        components.path = "/" + rawParts.joined(separator: "/")
        return components.url ?? url
    }

    private static func download(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                // Download to a temporary file so an unexpectedly large response
                // cannot be buffered entirely in memory before the 10 MB limit is checked.
                let (temporaryURL, response) = try await URLSession.shared.download(for: request)
                if let http = response as? HTTPURLResponse {
                    guard (200...299).contains(http.statusCode) else {
                        throw ImportError.httpStatus(http.statusCode)
                    }
                }
                guard response.expectedContentLength < 0
                        || response.expectedContentLength <= Int64(maximumImportBytes) else {
                    throw ImportError.responseTooLarge
                }
                let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= maximumImportBytes else {
                    throw ImportError.responseTooLarge
                }
                let data = try readLocalJSON(from: temporaryURL)
                return (data, response)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
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

    private static func sourceObjects(from root: Any) -> [[String: Any]] {
        if let array = root as? [[String: Any]] { return array }
        guard let object = root as? [String: Any] else { return [] }
        if isSourceObject(object) { return [object] }
        for key in ["bookSources", "bookSource", "sources", "data", "items"] {
            if let array = object[key] as? [[String: Any]] { return array }
            if let nested = object[key] as? [String: Any] {
                let sources = sourceObjects(from: nested)
                if !sources.isEmpty { return sources }
            }
        }
        return []
    }

    private static func isSourceObject(_ object: [String: Any]) -> Bool {
        object["bookSourceName"] != nil
            || object["bookSourceUrl"] != nil
            || object["searchUrl"] != nil
            || object["searchURL"] != nil
            || object["search_url"] != nil
    }

    /// Native adapters may have a primary and a disabled fallback entry in the
    /// same Legado file. Import them as one logical source and prefer the enabled
    /// primary entry, otherwise a later disabled fallback could overwrite it.
    private static func coalescedCandidates(_ candidates: [BookSource]) -> [BookSource] {
        var orderedKeys: [String] = []
        var selected: [String: BookSource] = [:]
        for candidate in candidates {
            let key = identityKey(candidate)
            guard let current = selected[key] else {
                orderedKeys.append(key)
                selected[key] = candidate
                continue
            }
            if candidatePreference(candidate) > candidatePreference(current) {
                selected[key] = candidate
            }
        }
        return orderedKeys.compactMap { selected[$0] }
    }

    private static func candidatePreference(_ source: BookSource) -> Int {
        var score = source.enabled && source.isValid ? 100 : 0
        let lowerName = source.name.lowercased()
        if lowerName.contains("备用") || lowerName.contains("backup") {
            score -= 10
        }
        return score
    }

    private static func identityKey(_ source: BookSource) -> String {
        if let native = NativeBookSourceAdapter.detect(name: source.name, bookSourceURL: source.bookURL) {
            return "native|" + native.rawValue
        }
        let base = sanitizedBaseURL(source.bookURL)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let search = source.searchURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fallback = source.name.lowercased()
        // 加入搜索 URL 和规则摘要，避免同一站点不同搜索策略被错误合并
        let ruleHash = stableRuleHash(source.rules)
        return source.formatRaw + "|"
            + (base.isEmpty ? fallback + "|" + search : base)
            + "|" + search + "|" + ruleHash
    }

    /// 解析规则的稳定摘要，用于去重比较。
    private static func stableRuleHash(_ rules: ParseRule) -> String {
        let fields = [
            rules.bookList, rules.name, rules.author, rules.bookUrl,
            rules.chapterList, rules.chapterName, rules.chapterUrl, rules.content
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !fields.isEmpty else { return "" }
        // 简单摘要：取前 3 个规则字段拼接
        let sample = fields.prefix(3).joined(separator: "|")
        return String(sample.prefix(80))
    }

    private static func update(_ target: BookSource, from source: BookSource) {
        target.name = source.name
        target.groupName = source.groupName
        target.searchURL = source.searchURL
        target.exploreURL = source.exploreURL
        target.bookURL = source.bookURL
        target.tocURL = source.tocURL
        target.contentURL = source.contentURL
        target.headerJSON = source.headerJSON
        target.ruleJSON = source.ruleJSON
        target.exploreRuleJSON = source.exploreRuleJSON
        target.enabled = source.enabled
        target.formatRaw = source.formatRaw
        target.isValid = source.isValid
        target.comment = source.comment
        target.weight = source.weight
    }

    private static func sanitizedBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutMetadata = trimmed.components(separatedBy: "##").first ?? trimmed
        return withoutMetadata.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unsupportedNativeIssue(
        name: String,
        bookSourceURL: String
    ) -> String? {
        let lowerName = name.lowercased()
        let lowerURL = bookSourceURL.lowercased()
        if (lowerName.contains("pixiv") && lowerName.contains("漫画"))
            || lowerURL.contains("pixiv.net/manga") {
            return String(localized: "Pixiv 漫画需要图片章节阅读，当前版本暂不支持漫画书源")
        }
        return nil
    }

    private static func compatibilityIssue(
        searchURL: String,
        object: [String: Any]
    ) -> String? {
        let lower = searchURL.lowercased()
        if lower.contains("@js:") || lower.contains("<js>") || lower.contains("</js>") {
            return String(localized: "包含 JavaScript 搜索逻辑")
        }
        guard BookSourceEngine.canBuildSearchRequest(
            raw: searchURL,
            baseURL: sanitizedBaseURL(string(object, "bookSourceUrl") ?? "")
        ) else {
            return String(localized: "搜索请求格式暂不支持")
        }

        guard let searchRules = object["ruleSearch"] as? [String: Any],
              string(searchRules, "bookList") != nil,
              string(searchRules, "name") != nil,
              string(searchRules, "bookUrl") != nil else {
            return String(localized: "缺少搜索列表、书名或详情地址规则")
        }
        // Only rules consumed by PureReader should decide whether search is usable.
        // Legado sources often attach JavaScript to optional metadata such as kind
        // or wordCount; disabling the whole source for unused fields hides otherwise
        // valid name/author/book URL results (for example JSON API sources).
        let consumedSearchKeys = ["bookList", "name", "author", "intro", "coverUrl", "bookUrl"]
        let ruleValues = consumedSearchKeys.compactMap { string(searchRules, $0) }
        if ruleValues.contains(where: {
            let lowerRule = $0.lowercased()
            return lowerRule.contains("@js:") || lowerRule.contains("<js>")
                || lowerRule.contains("@put:") || lowerRule.contains("@get:")
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
                "exploreUrl": s.exploreURL,
                "bookUrl": s.bookURL,
                "tocUrl": s.tocURL,
                "contentUrl": s.contentURL,
                "header": s.headerJSON,
                "enabled": s.enabled,
                "format": s.format.rawValue,
                "comment": s.comment,
                "weight": s.weight,
                "ruleSearch": ruleDict(s.rules, kind: .search),
                "ruleExplore": ruleDict(s.exploreRules, kind: .search),
                "ruleBookInfo": ruleDict(s.rules, kind: .info),
                "ruleToc": ruleDict(s.rules, kind: .toc),
                "ruleContent": ruleDict(s.rules, kind: .content)
            ]
        }
        return try JSONSerialization.data(withJSONObject: payloads, options: [.prettyPrinted, .sortedKeys])
    }

    /// 内置书源：从 App Bundle 的 BuiltinSources.json 导入。
    ///
    /// 内置合集来自社区公开书源，仅保留 PureReader 规则引擎兼容的
    /// （CSS / JSONPath，无 JS / XPath / WebView）且搜索-目录-正文链路完整的源。
    /// 首次启动自动播种；书源管理里也可随时重新导入。
    @MainActor
    static func seedBuiltInIfNeeded(context: ModelContext) {
        let descriptor = FetchDescriptor<BookSource>()
        let existing = (try? context.fetch(descriptor)) ?? []
        if !existing.isEmpty { return }

        do {
            _ = try importBuiltinSources(into: context)
        } catch {
            // 播种失败不应静默：本地资源 + 规则已筛选，失败通常是引擎/模型回归。
            assertionFailure("Failed to seed built-in book sources: \(error)")
        }
    }

    /// 导入内置书源合集。可重复调用：按站点 URL 去重并更新已有书源，不产生重复项。
    @MainActor
    @discardableResult
    static func importBuiltinSources(into context: ModelContext) throws -> ImportResult {
        guard let url = Bundle.main.url(forResource: "BuiltinSources", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw ImportError.builtinMissing
        }
        return try importJSON(data, into: context)
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
        let search = string(obj, "searchUrl") ?? string(obj, "searchURL") ?? ""
        let explore = string(obj, "exploreUrl") ?? string(obj, "exploreURL") ?? ""
        let baseURL = sanitizedBaseURL(string(obj, "bookSourceUrl") ?? "")
        guard !search.isEmpty else { throw ImportError.invalidFormat }
        let comment = string(obj, "bookSourceComment") ?? string(obj, "comment") ?? ""
        let nativeAdapter = NativeBookSourceAdapter.detect(name: name, bookSourceURL: baseURL)
        let compatibility = nativeAdapter == nil
            ? unsupportedNativeIssue(name: name, bookSourceURL: baseURL)
                ?? compatibilityIssue(searchURL: search, object: obj)
            : nil
        let readingIssue = nativeAdapter == nil ? readingCompatibilityIssue(obj) : nil
        let enabled = (bool(obj, "enabled") ?? true) && (nativeAdapter != nil || compatibility == nil)
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
        var exploreRules: ParseRule?
        if let re = obj["ruleExplore"] as? [String: Any] {
            exploreRules = ParseRule(
                bookList: string(re, "bookList"),
                name: string(re, "name"),
                author: string(re, "author"),
                intro: string(re, "intro"),
                coverUrl: string(re, "coverUrl"),
                bookUrl: string(re, "bookUrl")
            )
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

        let effectiveRules = nativeAdapter == nil ? rules : .empty
        let nativeNote = nativeAdapter.map {
            String(localized: "已识别为 \($0.displayName)，跳过原书源 JavaScript，使用 PureReader 原生网络接口")
        }
        let effectiveComment = [
            comment,
            nativeNote,
            compatibility.map { appendCompatibilityNote("", issue: $0) },
            readingIssue.map { appendPartialCompatibilityNote("", issue: $0) }
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
        let source = BookSource(
            name: name,
            groupName: group,
            searchURL: nativeAdapter?.searchURLTemplate ?? search,
            exploreURL: nativeAdapter == nil ? explore : "",
            bookURL: nativeAdapter?.baseURL ?? baseURL,
            tocURL: "",
            contentURL: "",
            headerJSON: headerStorageString(obj["header"]),
            rules: effectiveRules,
            exploreRules: nativeAdapter == nil ? exploreRules : nil,
            enabled: enabled,
            format: .legado,
            comment: effectiveComment,
            weight: weight
        )
        source.isValid = nativeAdapter != nil || compatibility == nil
        return source
    }

    private static func parseAiYueJi(_ obj: [String: Any]) throws -> BookSource {
        guard let name = string(obj, "name") ?? string(obj, "title") else {
            throw ImportError.invalidFormat
        }
        let host = string(obj, "host") ?? ""
        let search = string(obj, "search_url") ?? string(obj, "searchUrl") ?? (host + "/search?q={{key}}")
        let explore = string(obj, "explore_url") ?? string(obj, "exploreUrl") ?? ""
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
            exploreURL: explore,
            headerJSON: headerStorageString(obj["header"] ?? obj["headers"]),
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
        let exploreURL = string(obj, "exploreUrl") ?? string(obj, "exploreURL") ?? ""
        var exploreRules: ParseRule?
        if let explore = obj["ruleExplore"] as? [String: Any] {
            exploreRules = rulesFromDict(explore)
        }
        guard !searchURL.isEmpty, rules.name != nil, rules.bookUrl != nil else {
            throw ImportError.invalidFormat
        }
        return BookSource(
            name: name,
            groupName: string(obj, "group") ?? "",
            searchURL: searchURL,
            exploreURL: exploreURL,
            bookURL: string(obj, "bookUrl") ?? "",
            tocURL: string(obj, "tocUrl") ?? "",
            contentURL: string(obj, "contentUrl") ?? "",
            headerJSON: headerStorageString(obj["header"] ?? obj["headers"]),
            rules: rules,
            exploreRules: exploreRules,
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

    private static func headerStorageString(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
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
        case builtinMissing

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return String(localized: "无法识别的书源 JSON 格式")
            case .noValidSources:
                return String(localized: "JSON 中没有可导入的有效书源")
            case .invalidURL:
                return String(localized: "书源地址无效，仅支持 HTTP 或 HTTPS")
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
            case .builtinMissing:
                return String(localized: "未找到内置书源资源，请重新安装 App")
            }
        }
    }
}
