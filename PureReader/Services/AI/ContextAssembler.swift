import Foundation

struct RewriteContext: Sendable {
    var originalText: String
    var previousContext: String
    var nextContext: String
    var chapterSummary: String
    var characterCards: String
    var semanticContext: String
    var memoryAnchorContext: String
    var bookTitle: String
    var author: String
    var genre: String
    var chapterTitle: String
    var chapterIndex: Int
}

enum ContextAssembler {
    /// 位置上下文组装（同步、不调用网络）
    static func assemblePositional(
        chapterContent: String,
        chapterTitle: String,
        chapterIndex: Int,
        originalText: String,
        bookTitle: String,
        author: String,
        maxContextTokens: Int = AIConfig.maxContextTokens
    ) -> RewriteContext {
        let originalTokens = LLMClient.estimateTokens(originalText)
        let remaining = max(200, maxContextTokens - originalTokens)

        let prevBudget = Int(Double(remaining) * 0.45)
        let nextBudget = Int(Double(remaining) * 0.25)
        let summaryBudget = Int(Double(remaining) * 0.20)

        let previous = extractPreceding(
            from: chapterContent,
            before: originalText,
            maxTokens: prevBudget
        )
        let next = extractFollowing(
            from: chapterContent,
            after: originalText,
            maxTokens: nextBudget
        )
        let summary = extractSummary(from: chapterContent, maxTokens: summaryBudget)
        let names = extractCharacterNames(from: originalText + previous)
        let cards = names.prefix(8).map { "• \($0)" }.joined(separator: "\n")

        return RewriteContext(
            originalText: originalText,
            previousContext: previous,
            nextContext: next,
            chapterSummary: summary,
            characterCards: cards,
            semanticContext: "",
            memoryAnchorContext: "",
            bookTitle: bookTitle,
            author: author,
            genre: "小说",
            chapterTitle: chapterTitle,
            chapterIndex: chapterIndex
        )
    }

    /// 混合：位置 + 向量 + 记忆锚点
    static func assembleHybrid(
        chapterContent: String,
        chapterTitle: String,
        chapterIndex: Int,
        originalText: String,
        bookTitle: String,
        author: String,
        vectorIndex: BookVectorIndex?,
        memoryAnchorText: String
    ) async -> RewriteContext {
        var ctx = assemblePositional(
            chapterContent: chapterContent,
            chapterTitle: chapterTitle,
            chapterIndex: chapterIndex,
            originalText: originalText,
            bookTitle: bookTitle,
            author: author
        )
        ctx.memoryAnchorContext = memoryAnchorText

        guard let index = vectorIndex else { return ctx }

        do {
            var results = try await index.search(
                query: originalText,
                topK: 20,
                minSimilarity: AIRewriteConstants.vectorMinSimilarity,
                excludeChapterIndex: chapterIndex,
                excludeText: originalText
            )
            // 候选较多时 LLM 精排
            if results.count > AIRewriteConstants.vectorTopK {
                results = try await Reranker.rerank(
                    query: originalText,
                    candidates: results,
                    topK: AIRewriteConstants.vectorTopK
                )
            } else {
                results = Array(results.prefix(AIRewriteConstants.vectorTopK))
            }
            if !results.isEmpty {
                let body = results.enumerated().map { i, entry in
                    "[来源：第\(entry.chapterIndex + 1)章]\n\(entry.text)"
                }.joined(separator: "\n---\n")
                ctx.semanticContext = """
                【相关设定与背景（来自全书语义检索）】
                以下段落与当前改写场景语义相关，可能包含关键设定信息：

                \(body)
                """
            }
        } catch {
            // 向量检索失败时降级为纯位置上下文
        }
        return ctx
    }

    // MARK: - Extractors

    private static func extractPreceding(from full: String, before needle: String, maxTokens: Int) -> String {
        guard let range = full.range(of: needle) else {
            return takeLastTokens(String(full.prefix(2000)), maxTokens: maxTokens)
        }
        let head = String(full[..<range.lowerBound])
        return takeLastTokens(head, maxTokens: maxTokens)
    }

    private static func extractFollowing(from full: String, after needle: String, maxTokens: Int) -> String {
        guard let range = full.range(of: needle) else {
            return takeFirstTokens(String(full.suffix(2000)), maxTokens: maxTokens)
        }
        let tail = String(full[range.upperBound...])
        return takeFirstTokens(tail, maxTokens: maxTokens)
    }

    private static func extractSummary(from full: String, maxTokens: Int) -> String {
        takeFirstTokens(full, maxTokens: maxTokens)
    }

    private static func takeFirstTokens(_ text: String, maxTokens: Int) -> String {
        // 按段落累加
        var result = ""
        var used = 0
        for para in text.components(separatedBy: "\n\n") {
            let t = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let tokens = LLMClient.estimateTokens(t)
            if used + tokens > maxTokens && !result.isEmpty { break }
            if !result.isEmpty { result += "\n\n" }
            result += t
            used += tokens
            if used >= maxTokens { break }
        }
        if result.isEmpty {
            // fallback 按字符
            let approxChars = maxTokens * 2
            return String(text.prefix(approxChars))
        }
        return result
    }

    private static func takeLastTokens(_ text: String, maxTokens: Int) -> String {
        var paras = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var picked: [String] = []
        var used = 0
        while let last = paras.popLast() {
            let tokens = LLMClient.estimateTokens(last)
            if used + tokens > maxTokens && !picked.isEmpty { break }
            picked.insert(last, at: 0)
            used += tokens
            if used >= maxTokens { break }
        }
        if picked.isEmpty {
            let approxChars = maxTokens * 2
            return String(text.suffix(approxChars))
        }
        return picked.joined(separator: "\n\n")
    }

    /// 粗略中文人名提取：2-3 字连续汉字 + 常见姓氏
    static func extractCharacterNames(from text: String) -> [String] {
        let surnames: Set<Character> = Set("赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳酆鲍史唐费廉岑薛雷贺倪汤滕殷罗毕郝邬安常乐于时傅皮卞齐康伍余元卜顾孟平黄和穆萧尹姚邵湛汪祁毛禹狄米贝明臧计伏成戴谈宋茅庞熊纪舒屈项祝董梁杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林刁钟徐邱骆高夏蔡田樊胡凌霍虞万支柯昝管卢莫经房裘缪干解应宗丁宣贲邓郁单杭洪包诸左石崔吉钮龚程嵇邢滑裴陆荣翁荀羊於惠甄曲家封芮羿储靳汲邴糜松井段富巫乌焦巴弓牧隗山谷车侯宓蓬全郗班仰秋仲伊宫宁仇栾暴甘钭厉戎祖武符刘景詹束龙叶幸司韶郜黎蓟薄印宿白怀蒲邰从鄂索咸籍赖卓蔺屠蒙池乔阴鬱胥能苍双闻莘党翟谭贡劳逄姬申扶堵冉宰郦雍却璩桑桂濮牛寿通边扈燕冀郏浦尚农温别庄晏柴瞿阎充慕连茹习宦艾鱼容向古易慎戈廖庾终暨居衡步都耿满弘匡国文寇广禄阙东欧殳沃利蔚越夔隆师巩厍聂晁勾敖融冷訾辛阚那简饶空曾毋沙乜养鞠须丰巢关蒯相查后荆红游竺权逯盖益桓公")
        var found: [String] = []
        var seen = Set<String>()
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if surnames.contains(c) {
                // 取 2-3 字
                for len in [3, 2] {
                    if i + len <= chars.count {
                        let slice = String(chars[i..<(i + len)])
                        if slice.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) {
                            if !seen.contains(slice) {
                                seen.insert(slice)
                                found.append(slice)
                            }
                            break
                        }
                    }
                }
            }
            i += 1
            if found.count >= 20 { break }
        }
        return found
    }
}
