import Foundation
import SwiftData

/// 多格式书源导入：Legado / 爱阅记 / PureReader JSON
enum BookSourceImporter {

    // MARK: - Public

    static func importJSON(_ data: Data, into context: ModelContext) throws -> Int {
        // 尝试数组或单对象
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            var count = 0
            for item in arr {
                guard JSONSerialization.isValidJSONObject(item),
                      let itemData = try? JSONSerialization.data(withJSONObject: item),
                      let source = try? parseOne(itemData) else { continue }
                context.insert(source)
                count += 1
            }
            try context.save()
            return count
        }
        if let source = try? parseOne(data) {
            context.insert(source)
            try context.save()
            return 1
        }
        throw ImportError.invalidFormat
    }

    static func importFromURL(_ url: URL, into context: ModelContext) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try importJSON(data, into: context)
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

    private static func parseOne(_ data: Data) throws -> BookSource {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalidFormat
        }
        // 判定格式
        if obj["searchUrl"] != nil || obj["ruleSearch"] != nil || obj["bookSourceName"] != nil {
            return parseLegado(obj)
        }
        if obj["search_url"] != nil || obj["host"] != nil {
            return parseAiYueJi(obj)
        }
        return parsePureReader(obj)
    }

    private static func parseLegado(_ obj: [String: Any]) -> BookSource {
        let name = string(obj, "bookSourceName") ?? string(obj, "name") ?? "未命名书源"
        let group = string(obj, "bookSourceGroup") ?? string(obj, "group") ?? ""
        let search = string(obj, "searchUrl") ?? ""
        let comment = string(obj, "bookSourceComment") ?? string(obj, "comment") ?? ""
        let enabled = bool(obj, "enabled") ?? true
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

        return BookSource(
            name: name,
            groupName: group,
            searchURL: search,
            bookURL: string(obj, "bookUrl") ?? "",
            tocURL: "",
            contentURL: "",
            rules: rules,
            enabled: enabled,
            format: .legado,
            comment: comment,
            weight: weight
        )
    }

    private static func parseAiYueJi(_ obj: [String: Any]) -> BookSource {
        let name = string(obj, "name") ?? string(obj, "title") ?? "爱阅记书源"
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

    private static func parsePureReader(_ obj: [String: Any]) -> BookSource {
        let name = string(obj, "name") ?? "PureReader 书源"
        var rules = ParseRule()
        if let r = obj["rules"] as? [String: Any] {
            rules = rulesFromDict(r)
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
        // also accept legado-like nested
        if obj["ruleSearch"] is [String: Any] {
            return parseLegado(obj)
        }
        return BookSource(
            name: name,
            groupName: string(obj, "group") ?? "",
            searchURL: string(obj, "searchUrl") ?? string(obj, "searchURL") ?? "",
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
        var errorDescription: String? {
            String(localized: "无法识别的书源 JSON 格式")
        }
    }
}
