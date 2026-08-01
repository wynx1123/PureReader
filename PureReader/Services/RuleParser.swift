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
        let (extractionRule, replacement) = splitExtractionAndReplacement(rule)
        let value: String?
        if extractionRule.contains("{{"), extractionRule.contains("}}") {
            value = renderJSONTemplate(content: content, template: extractionRule)
        } else if extractionRule.hasPrefix("$.") || extractionRule.hasPrefix("$[") {
            value = jsonString(content: content, path: extractionRule)
        } else if extractionRule.hasPrefix("##") {
            value = regexFirst(content: content, rule: extractionRule)
        } else {
            value = cssFirst(
                content: content,
                rule: normalizeLegadoRule(extractionRule),
                baseURL: baseURL
            )
        }
        guard let value else { return nil }
        return replacement.map { applyInlineReplacement(value, expression: $0) } ?? value
    }

    private static func evaluateList(content: String, rule: String, baseURL: URL?) -> [String] {
        // JSON URL 模板（列表模式）：`https://api.example.com/book/{{$.novels.id}}`
        // 渲染成逐项 URL 列表。JSON API 书源常用它把 id 字段拼成完整详情地址。
        if rule.contains("{{"), rule.contains("}}") {
            return jsonTemplateList(content: content, template: rule)
        }
        if rule.hasPrefix("$.") || rule.hasPrefix("$[") {
            return jsonList(content: content, path: rule)
        }
        // 列表规则：先取列表节点，再在每块内取属性
        // 格式：`div.book` 或 `div.book@html` 作为块，由调用方再解析字段
        let (extractionRule, _) = splitExtractionAndReplacement(rule)
        return cssBlocks(content: content, rule: normalizeLegadoRule(extractionRule))
    }

    /// 模板列表：对 `{{$.a.b}}` 形式的 JSON 模板按列表逐项渲染。
    /// 模板中出现多个路径时以最长列表为基准，其余路径按索引对齐
    /// （越界时复用最后一项，避免整体丢弃）。
    private static func jsonTemplateList(content: String, template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{(\$[^}]+)\}\}"#) else { return [] }
        let matches = regex.matches(
            in: template,
            range: NSRange(template.startIndex..., in: template)
        )
        guard !matches.isEmpty else { return [] }
        var paths: [String] = []
        for match in matches {
            if let r = Range(match.range(at: 1), in: template) {
                paths.append(String(template[r]))
            }
        }
        // 每个路径的取值列表；全部为空则模板不可渲染
        let lists = paths.map { jsonList(content: content, path: $0) }
        let count = lists.compactMap { $0.isEmpty ? nil : $0.count }.max() ?? 0
        guard count > 0 else { return [] }
        var results: [String] = []
        results.reserveCapacity(count)
        for index in 0..<count {
            var rendered = template
            var failed = false
            // 倒序遍历避免前面的替换改变后面 range 的位置
            for (pathIndex, match) in matches.enumerated().reversed() {
                guard let fullRange = Range(match.range(at: 0), in: rendered) else { continue }
                let list = lists[pathIndex]
                let value = list.isEmpty ? nil : list[min(index, list.count - 1)]
                guard let value else { failed = true; break }
                rendered.replaceSubrange(fullRange, with: value)
            }
            if failed || rendered.contains("{{") { continue }
            results.append(rendered)
        }
        return results
    }

    private static func normalizeLegadoRule(_ rule: String) -> String {
        var working = rule.trimmingCharacters(in: .whitespaces)
        for prefix in ["@css:", "@CSS:", "@json:", "@JSON:"] where working.hasPrefix(prefix) {
            working = String(working.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            break
        }

        // Legado chains selectors with "@": #author@tbody@tr!0 and
        // class.item.0@tag.a.0@href. Keep the final known extraction token
        // as the attribute and translate the preceding parts to descendant CSS.
        var components = working.components(separatedBy: "@").filter { !$0.isEmpty }
        guard !components.isEmpty else { return working }
        let knownAttributes: Set<String> = [
            "text", "textnodes", "html", "href", "src", "onclick",
            "data-src", "data-original", "title", "alt", "content", "value"
        ]
        var attribute: String?
        if let last = components.last, knownAttributes.contains(last.lowercased()) {
            attribute = components.removeLast()
        }
        let selectors = components.compactMap(normalizeLegadoSelector)
        guard !selectors.isEmpty else { return working }
        let selector = selectors.joined(separator: " ")
        return attribute.map { selector + "@" + $0 } ?? selector
    }

    private static func normalizeLegadoSelector(_ raw: String) -> String? {
        var selector = raw.trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty else { return nil }

        // Positional suffixes are hints to Legado. The lightweight parser
        // currently returns the first match, so preserve the selector and drop
        // only the index suffix instead of accidentally turning `.odd.0` into tag `odd`.
        selector = selector.replacingOccurrences(
            of: #"\.(?:-?\d+|\d*:\d*)$"#,
            with: "",
            options: .regularExpression
        )
        selector = selector.replacingOccurrences(
            of: #"\[(?:-?\d+|\d*:\d*)\]$"#,
            with: "",
            options: .regularExpression
        )
        if let bang = selector.lastIndex(of: "!") {
            let suffix = selector[selector.index(after: bang)...]
            if suffix.allSatisfy({ $0.isNumber || $0 == "-" || $0 == ":" || $0 == "," }) {
                selector = String(selector[..<bang])
            }
        }

        let parts = selector.split(separator: ".").map(String.init)
        if parts.count >= 2 {
            switch parts[0].lowercased() {
            case "class": return "." + parts[1]
            case "id": return "#" + parts[1]
            case "tag": return parts[1]
            default: break
            }
        }
        return selector
    }

    private static func splitExtractionAndReplacement(_ rule: String) -> (String, String?) {
        guard let range = rule.range(of: "##"), range.lowerBound != rule.startIndex else {
            return (rule, nil)
        }
        return (String(rule[..<range.lowerBound]), String(rule[range.upperBound...]))
    }

    private static func applyInlineReplacement(_ value: String, expression: String) -> String {
        let pair = expression.components(separatedBy: "##")
        let pattern = pair.first ?? expression
        let replacement = pair.count > 1 ? pair[1] : ""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }

    // MARK: - JSON

    private static func renderJSONTemplate(content: String, template: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{(\$[^}]+)\}\}"#) else {
            return nil
        }
        let matches = regex.matches(
            in: template,
            range: NSRange(template.startIndex..., in: template)
        )
        guard !matches.isEmpty else { return template }
        var result = template
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let pathRange = Range(match.range(at: 1), in: result),
                  let value = jsonString(content: content, path: String(result[pathRange])) else {
                continue
            }
            result.replaceSubrange(fullRange, with: value)
        }
        return result.contains("{{") ? nil : result
    }

    private static func jsonString(content: String, path: String) -> String? {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return flattenedJSONValues(walkJSON(json, path: normalizeJSONPath(path)))
            .first.flatMap { stringify($0) }
    }

    private static func jsonList(content: String, path: String) -> [String] {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return flattenedJSONValues(walkJSON(json, path: normalizeJSONPath(path)))
            .compactMap { stringify($0) }
    }

    private static func flattenedJSONValues(_ values: [Any]) -> [Any] {
        values.flatMap { value in
            if let array = value as? [Any] { return array }
            return [value]
        }
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

    /// 后代选择器：`.list li`、`tbody tr`、`div.a > div.b`。
    ///
    /// 社区书源里这是最常见的形态。此前整串被当作单个简单选择器处理，
    /// class/tag 里混进空格后永远匹配不到元素——书源看似启用，搜索却恒为 0 结果。
    /// 这里逐段下钻：先在全文匹配第一段，再在其结果内匹配下一段。
    /// 子代组合符 `>` 退化为后代匹配（正则方案无法区分层级，宁可多匹配）。
    private static func matchElements(html: String, selector: String) -> [String] {
        let normalized = selector
            .replacingOccurrences(of: ">", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let segments = normalized
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !segments.isEmpty else { return [] }
        guard segments.count > 1 else {
            return matchSimpleElements(html: html, selector: segments[0])
        }

        var current = [html]
        for (offset, segment) in segments.enumerated() {
            var next: [String] = []
            for scope in current {
                // 除第一段外，作用域是上一段匹配到的完整元素（含自身标签）。
                // 必须先剥掉外层标签只留内容，否则在其中搜同名标签时，
                // 正则的 `</\1>` 会先闭合到外层元素自己（`.list li` 里的 ul 命中 ul）。
                let haystack = offset == 0 ? scope : innerHTML(of: scope)
                next.append(contentsOf: matchSimpleElements(html: haystack, selector: segment))
                if next.count >= 200 { break }
            }
            // 某一段匹配不到就整体失败，避免把上一层的结果当成最终结果返回。
            if next.isEmpty { return [] }
            current = Array(next.prefix(200))
        }
        return current
    }

    /// 剥掉元素最外层的开闭标签，只返回其内容。
    private static func innerHTML(of element: String) -> String {
        guard let openEnd = element.firstIndex(of: ">"),
              let closeStart = element.range(of: "</", options: .backwards)?.lowerBound,
              element.index(after: openEnd) <= closeStart else {
            return element
        }
        return String(element[element.index(after: openEnd)..<closeStart])
    }

    /// HTML 空元素：无闭合标签，开标签即完整元素。
    private static let voidElements: Set<String> = [
        "img", "br", "hr", "input", "meta", "link", "area",
        "base", "col", "embed", "source", "track", "wbr"
    ]

    /// 从 `start` 起找到与开标签配对的 `</tag>` 的结束位置（含闭合标签本身）。
    /// 用深度计数跳过同名嵌套；找不到配对返回 nil。
    private static func closingTagEnd(
        in ns: NSString,
        tag: String,
        after start: Int
    ) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        guard let regex = try? NSRegularExpression(
            pattern: "<(/?)\(escaped)\\b([^>]*)>",
            options: [.caseInsensitive]
        ) else { return nil }

        var depth = 1
        let searchRange = NSRange(location: start, length: ns.length - start)
        for m in regex.matches(in: ns as String, options: [], range: searchRange) {
            let isClosing = m.range(at: 1).length > 0
            if isClosing {
                depth -= 1
                if depth == 0 { return NSMaxRange(m.range) }
            } else {
                // 自闭合的同名标签不增加深度。
                let attrs = ns.substring(with: m.range(at: 2))
                if !attrs.hasSuffix("/") { depth += 1 }
            }
        }
        return nil
    }

    private static func matchSimpleElements(html: String, selector: String) -> [String] {
        // Support: tag, tag.class, tag#id, .class, #id, tag[attr=value]
        var sel = selector.trimmingCharacters(in: .whitespaces)
        // jsoup 伪类（:contains(...)、:eq(0)、:not(...)）本引擎不支持。
        // 剥掉后按基础选择器匹配，好过整条规则失效。
        if let colon = sel.firstIndex(of: ":") {
            sel = String(sel[..<colon])
        }
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

        // 只匹配「开标签」，逐个用深度计数找到各自的闭合标签。
        //
        // 此前用 `<(tag)\b([^>]*)>([\s\S]*?)</\1>` 一次性匹配整个元素，属性筛选在事后进行，
        // 于是 `.list li` 这类规则必然失败：非贪婪匹配会先命中最外层的 <div class="wrap">，
        // 把整段吞掉，游标直接跳到末尾，内层的 <ul class="list"> 根本没有机会被检验。
        let openPattern = "<(\(tag))\\b([^>]*)>"
        guard let openRegex = try? NSRegularExpression(
            pattern: openPattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        var results: [String] = []

        for m in openRegex.matches(in: html, options: [], range: range) {
            let attrs = ns.substring(with: m.range(at: 2))
            // 自闭合标签没有配对的闭合标签，跳过（下面的兜底分支单独处理）。
            if attrs.hasSuffix("/") { continue }

            if let className {
                // class 是空白分隔的 token 列表，做精确 token 比对。
                let classPattern = "class\\s*=\\s*[\"']([^\"']*)[\"']"
                guard let cre = try? NSRegularExpression(pattern: classPattern, options: .caseInsensitive),
                      let cm = cre.firstMatch(in: attrs, options: [], range: NSRange(attrs.startIndex..., in: attrs)),
                      let cr = Range(cm.range(at: 1), in: attrs) else { continue }
                let classes = String(attrs[cr]).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                guard classes.contains(where: { $0 == className }) else { continue }
            }
            if let idName {
                let idPattern = "id\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: idName))[\"']"
                guard attrs.range(of: idPattern, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            }

            let actualTag = ns.substring(with: m.range(at: 1))
            if Self.voidElements.contains(actualTag.lowercased()) {
                // img / br / input 等空元素没有闭合标签，开标签本身就是完整元素。
                // 书源里 `img@src` 取封面很常见，不能因为找不到 </img> 就丢弃。
                results.append(ns.substring(with: m.range))
            } else if let end = closingTagEnd(in: ns, tag: actualTag, after: NSMaxRange(m.range)) {
                results.append(
                    ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))
                )
            } else {
                continue
            }
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
        if a == "text" {
            return stripTags(elementHTML)
        }
        if a == "textnodes" {
            // 仅直接文本节点：剥离子元素标签块后剩余的内容
            let inner: String
            if let openEnd = elementHTML.firstIndex(of: ">"),
               let closeStart = elementHTML.range(of: "</", options: .backwards)?.lowerBound {
                inner = String(elementHTML[elementHTML.index(after: openEnd)..<closeStart])
            } else {
                inner = elementHTML
            }
            let stripped = inner.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // numeric entities: &#NN; and &#xHH;
        s = decodeNumericEntities(s)
        // collapse
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解码 `&#NNN;` / `&#xHH;` 数字实体（如 &#38; -> &）。
    /// 逐段扫描避免正则大范围回溯；无效码点原样保留。
    static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let hash = s.index(i, offsetBy: 1, limitedBy: s.endIndex), s[hash] == "#" {
                let rest = s[hash...]
                if let semi = rest.firstIndex(of: ";"), semi > hash {
                    let digits = rest[rest.index(after: hash)..<semi]
                    let value: UInt32?
                    if digits.first == "x" || digits.first == "X" {
                        value = UInt32(digits.dropFirst(), radix: 16)
                    } else {
                        value = UInt32(digits, radix: 10)
                    }
                    if let value, let scalar = UnicodeScalar(value) {
                        result.unicodeScalars.append(scalar)
                        i = s.index(after: semi)
                        continue
                    }
                }
            }
            result.append(s[i])
            i = s.index(after: i)
        }
        return result
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
