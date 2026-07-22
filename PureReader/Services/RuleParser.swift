import Foundation

/// 轻量规则解析：支持 CSS 风格、JSON Path 简写、正则、文本
/// 规则语法（兼容 Legado 子集）：
/// - `tag.class@text` / `tag@class` / `a@href`
/// - `$.data.list[*].name` JSON
/// - `##regex##replacement` 文本替换
/// - 多规则用 `||` 备选，`&&` 串联取多值
enum RuleParser {

    // MARK: - Public

    /// 从 HTML/JSON 文本按规则取第一个匹配
    static func getString(from content: String, rule: String?, baseURL: URL? = nil) -> String? {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let alternatives = rule.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }
        for alt in alternatives {
            if let v = evaluateSingle(content: content, rule: alt, baseURL: baseURL), !v.isEmpty {
                return v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// 取列表
    static func getStrings(from content: String, rule: String?, baseURL: URL? = nil) -> [String] {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let alternatives = rule.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }
        for alt in alternatives {
            let list = evaluateList(content: content, rule: alt, baseURL: baseURL)
            if !list.isEmpty { return list }
        }
        return []
    }

    /// 应用 replaceRegex：`old##new@@old2##new2`
    static func applyReplacements(_ text: String, replaceRegex: String?) -> String {
        guard let replaceRegex, !replaceRegex.isEmpty else { return text }
        var result = text
        let parts = replaceRegex.components(separatedBy: "@@")
        for part in parts {
            let pair = part.components(separatedBy: "##")
            guard pair.count >= 2 else { continue }
            let pattern = pair[0]
            let replacement = pair[1]
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            } else {
                result = result.replacingOccurrences(of: pattern, with: replacement)
            }
        }
        return result
    }

    // MARK: - Evaluate

    private static func evaluateSingle(content: String, rule: String, baseURL: URL?) -> String? {
        if rule.hasPrefix("$.") || rule.hasPrefix("$[") {
            return jsonString(content: content, path: rule)
        }
        if rule.hasPrefix("##") {
            // ##regex## 取 group 1
            return regexFirst(content: content, rule: rule)
        }
        // CSS-like
        return cssFirst(content: content, rule: rule, baseURL: baseURL)
    }

    private static func evaluateList(content: String, rule: String, baseURL: URL?) -> [String] {
        if rule.hasPrefix("$.") || rule.hasPrefix("$[") {
            return jsonList(content: content, path: rule)
        }
        // 列表规则：先取列表节点，再在每块内取属性
        // 格式：`div.book` 或 `div.book@html` 作为块，由调用方再解析字段
        return cssBlocks(content: content, rule: rule)
    }

    // MARK: - JSON

    private static func jsonString(content: String, path: String) -> String? {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return walkJSON(json, path: normalizeJSONPath(path)).first.flatMap { stringify($0) }
    }

    private static func jsonList(content: String, path: String) -> [String] {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return walkJSON(json, path: normalizeJSONPath(path)).compactMap { stringify($0) }
    }

    private static func normalizeJSONPath(_ path: String) -> [String] {
        // $.data.list[*].name -> ["data","list","*","name"]
        var p = path
        if p.hasPrefix("$") { p = String(p.dropFirst()) }
        if p.hasPrefix(".") { p = String(p.dropFirst()) }
        p = p.replacingOccurrences(of: "[*]", with: ".*")
        p = p.replacingOccurrences(of: "[", with: ".")
        p = p.replacingOccurrences(of: "]", with: "")
        return p.split(separator: ".").map(String.init).filter { !$0.isEmpty }
    }

    private static func walkJSON(_ node: Any, path: [String]) -> [Any] {
        guard let first = path.first else { return [node] }
        let rest = Array(path.dropFirst())
        if first == "*" {
            if let arr = node as? [Any] {
                return arr.flatMap { walkJSON($0, path: rest) }
            }
            return []
        }
        if let dict = node as? [String: Any], let next = dict[first] {
            return walkJSON(next, path: rest)
        }
        if let arr = node as? [Any], let idx = Int(first), idx < arr.count {
            return walkJSON(arr[idx], path: rest)
        }
        return []
    }

    private static func stringify(_ any: Any) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if any is NSNull { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: any),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(any)"
    }

    // MARK: - Regex

    private static func regexFirst(content: String, rule: String) -> String? {
        // ##pattern## or ##pattern##group
        var r = rule
        if r.hasPrefix("##") { r = String(r.dropFirst(2)) }
        let parts = r.components(separatedBy: "##")
        let pattern = parts.first ?? r
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range) else { return nil }
        let g = match.numberOfRanges > 1 ? 1 : 0
        guard let rr = Range(match.range(at: g), in: content) else { return nil }
        return String(content[rr])
    }

    // MARK: - CSS-like HTML (regex based, no WebKit dependency)

    /// `div.item` / `a.book@href` / `h3@text` / `div#id@class`
    private static func cssFirst(content: String, rule: String, baseURL: URL?) -> String? {
        let (selector, attr) = splitSelectorAttr(rule)
        let blocks = matchElements(html: content, selector: selector)
        guard let first = blocks.first else { return nil }
        return extractAttr(from: first, attr: attr, baseURL: baseURL)
    }

    private static func cssBlocks(content: String, rule: String) -> [String] {
        let (selector, _) = splitSelectorAttr(rule)
        return matchElements(html: content, selector: selector)
    }

    private static func splitSelectorAttr(_ rule: String) -> (String, String) {
        // last @ separates attr
        if let at = rule.lastIndex(of: "@") {
            let sel = String(rule[..<at])
            let attr = String(rule[rule.index(after: at)...])
            return (sel, attr.isEmpty ? "text" : attr)
        }
        return (rule, "html")
    }

    private static func matchElements(html: String, selector: String) -> [String] {
        // Support: tag, tag.class, tag#id, .class, #id, tag[attr=value]
        let sel = selector.trimmingCharacters(in: .whitespaces)
        guard !sel.isEmpty else { return [] }

        var tag = "[a-zA-Z0-9]+"
        var className: String?
        var idName: String?

        if sel.hasPrefix(".") {
            className = String(sel.dropFirst())
        } else if sel.hasPrefix("#") {
            idName = String(sel.dropFirst())
        } else if let dot = sel.firstIndex(of: ".") {
            tag = String(sel[..<dot])
            className = String(sel[sel.index(after: dot)...])
        } else if let hash = sel.firstIndex(of: "#") {
            tag = String(sel[..<hash])
            idName = String(sel[sel.index(after: hash)...])
        } else {
            tag = NSRegularExpression.escapedPattern(for: sel)
        }

        var pattern = "<(\(tag))\\b([^>]*)>([\\s\\S]*?)</\\1>"
        if tag == "[a-zA-Z0-9]+" {
            pattern = "<([a-zA-Z0-9]+)\\b([^>]*)>([\\s\\S]*?)</\\1>"
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        var results: [String] = []
        for m in matches {
            guard let full = Range(m.range, in: html),
                  let attrR = Range(m.range(at: 2), in: html) else { continue }
            let attrs = String(html[attrR])
            if let className {
                // class contains token
                let classPattern = "class\\s*=\\s*[\"']([^\"']*)[\"']"
                guard let cre = try? NSRegularExpression(pattern: classPattern, options: .caseInsensitive),
                      let cm = cre.firstMatch(in: attrs, options: [], range: NSRange(attrs.startIndex..., in: attrs)),
                      let cr = Range(cm.range(at: 1), in: attrs) else { continue }
                let classes = String(attrs[cr]).split(separator: " ").map(String.init)
                guard classes.contains(className) else { continue }
            }
            if let idName {
                let idPattern = "id\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: idName))[\"']"
                guard attrs.range(of: idPattern, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            }
            results.append(String(html[full]))
            if results.count >= 200 { break }
        }
        // also self-closing tags for img etc when attr only
        if results.isEmpty {
            let selfPattern = "<(\(tag == "[a-zA-Z0-9]+" ? "[a-zA-Z0-9]+" : tag))\\b([^>]*?)/?>"
            if let re = try? NSRegularExpression(pattern: selfPattern, options: .caseInsensitive) {
                for m in re.matches(in: html, options: [], range: range) {
                    if let full = Range(m.range, in: html) {
                        results.append(String(html[full]))
                    }
                    if results.count >= 50 { break }
                }
            }
        }
        return results
    }

    private static func extractAttr(from elementHTML: String, attr: String, baseURL: URL?) -> String? {
        let a = attr.lowercased()
        if a == "text" || a == "textNodes" {
            return stripTags(elementHTML)
        }
        if a == "html" {
            // inner html
            if let openEnd = elementHTML.firstIndex(of: ">"),
               let closeStart = elementHTML.range(of: "</", options: .backwards)?.lowerBound {
                let inner = elementHTML[elementHTML.index(after: openEnd)..<closeStart]
                return String(inner)
            }
            return elementHTML
        }
        // attribute
        let pattern = "\(NSRegularExpression.escapedPattern(for: attr))\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: elementHTML, options: [], range: NSRange(elementHTML.startIndex..., in: elementHTML)),
              let r = Range(m.range(at: 1), in: elementHTML) else {
            return nil
        }
        var value = String(elementHTML[r])
        if (a == "href" || a == "src"), let baseURL {
            value = resolveURL(value, base: baseURL)
        }
        return value
    }

    static func stripTags(_ html: String) -> String {
        var s = html
        // script/style
        s = s.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        // collapse
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resolveURL(_ url: String, base: URL) -> String {
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        if url.hasPrefix("//") { return (base.scheme ?? "https") + ":" + url }
        if let absolute = URL(string: url, relativeTo: base)?.absoluteString {
            return absolute
        }
        return url
    }
}
