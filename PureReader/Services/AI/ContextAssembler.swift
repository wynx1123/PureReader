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
    /// 原文在章节全文中的 UTF-16 偏移；用于重复段落的精确替换。
    var targetUTF16Offset: Int?
}

enum ContextAssembler {
    /// 位置上下文组装（同步、不调用网络）。
    static func assemblePositional(
        chapterContent: String,
        chapterTitle: String,
        chapterIndex: Int,
        originalText: String,
        bookTitle: String,
        author: String,
        expectedUTF16Offset: Int? = nil,
        maxContextTokens: Int = AIConfig.maxContextTokens
    ) -> RewriteContext {
        let targetRange = locateTargetRange(
            in: chapterContent,
            text: originalText,
            expectedUTF16Offset: expectedUTF16Offset
        )
        let resolvedOffset = targetRange.map {
            chapterContent.utf16.distance(
                from: chapterContent.startIndex,
                to: $0.lowerBound
            )
        }

        let originalTokens = LLMClient.estimateTokens(originalText)
        let remaining = max(240, maxContextTokens - originalTokens)
        let previousBudget = Int(Double(remaining) * 0.48)
        let nextBudget = Int(Double(remaining) * 0.28)
        let structureBudget = max(80, remaining - previousBudget - nextBudget)

        let previous = extractPreceding(
            from: chapterContent,
            targetRange: targetRange,
            maxTokens: previousBudget
        )
        let next = extractFollowing(
            from: chapterContent,
            targetRange: targetRange,
            maxTokens: nextBudget
        )
        let structure = extractChapterStructure(
            from: chapterContent,
            excluding: originalText,
            maxTokens: structureBudget
        )
        let names = extractCharacterNames(
            from: originalText + "\n" + String(previous.suffix(1_200))
        )
        let cards = names.prefix(8).map { "• \($0)" }.joined(separator: "\n")

        return RewriteContext(
            originalText: originalText,
            previousContext: previous,
            nextContext: next,
            chapterSummary: structure,
            characterCards: cards,
            semanticContext: "",
            memoryAnchorContext: "",
            bookTitle: bookTitle,
            author: author,
            genre: "小说",
            chapterTitle: chapterTitle,
            chapterIndex: chapterIndex,
            targetUTF16Offset: resolvedOffset ?? expectedUTF16Offset
        )
    }

    /// 混合上下文：位置 + 向量检索 + 全书记忆锚点。
    ///
    /// 交互式改写不再额外调用 LLM 精排，避免“检索 + 精排 + 规划 + 生成”造成过高延迟；
    /// 检索查询同时包含用户意图，使返回内容更贴近要改变的情节。
    static func assembleHybrid(
        chapterContent: String,
        chapterTitle: String,
        chapterIndex: Int,
        originalText: String,
        userRequest: String,
        bookTitle: String,
        author: String,
        expectedUTF16Offset: Int? = nil,
        vectorIndex: BookVectorIndex?,
        memoryAnchorText: String
    ) async -> RewriteContext {
        let totalBudget = max(1_200, AIConfig.maxContextTokens)
        let originalTokens = LLMClient.estimateTokens(originalText)
        let memoryBudget = min(650, max(160, totalBudget / 6))
        let semanticBudget = min(900, max(240, totalBudget / 4))
        let positionalBudget = max(
            originalTokens + 420,
            totalBudget - memoryBudget - semanticBudget
        )

        var context = assemblePositional(
            chapterContent: chapterContent,
            chapterTitle: chapterTitle,
            chapterIndex: chapterIndex,
            originalText: originalText,
            bookTitle: bookTitle,
            author: author,
            expectedUTF16Offset: expectedUTF16Offset,
            maxContextTokens: positionalBudget
        )
        context.memoryAnchorContext = takeFirstTokens(
            memoryAnchorText,
            maxTokens: memoryBudget
        )

        guard let vectorIndex else { return context }

        do {
            let query = [
                userRequest.trimmingCharacters(in: .whitespacesAndNewlines),
                originalText,
                context.characterCards
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

            let results = try await vectorIndex.search(
                query: query,
                topK: AIRewriteConstants.vectorTopK,
                minSimilarity: AIRewriteConstants.vectorMinSimilarity,
                excludeChapterIndex: chapterIndex,
                excludeText: originalText
            )
            if !results.isEmpty {
                let body = results.map { entry in
                    "[来源：第\(entry.chapterIndex + 1)章]\n\(entry.text)"
                }.joined(separator: "\n---\n")
                let clipped = takeFirstTokens(body, maxTokens: semanticBudget)
                context.semanticContext = """
                【相关设定与背景（来自全书语义检索）】
                以下内容只用于校验设定与因果，不要照抄：

                \(clipped)
                """
            }
        } catch {
            // 向量检索失败时自动降级为位置上下文，不阻断改写。
        }
        return context
    }

    // MARK: - Range and context extraction

    private static func locateTargetRange(
        in fullText: String,
        text needle: String,
        expectedUTF16Offset: Int?
    ) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        let fullLength = (fullText as NSString).length
        let needleLength = (needle as NSString).length

        if let expectedUTF16Offset {
            let location = min(max(0, expectedUTF16Offset), fullLength)
            if location + needleLength <= fullLength,
               let exact = Range(
                    NSRange(location: location, length: needleLength),
                    in: fullText
               ),
               String(fullText[exact]) == needle {
                return exact
            }
        }

        var best: (range: Range<String.Index>, distance: Int)?
        var searchStart = fullText.startIndex
        while searchStart < fullText.endIndex,
              let found = fullText.range(
                of: needle,
                options: [],
                range: searchStart..<fullText.endIndex
              ) {
            let offset = fullText.utf16.distance(
                from: fullText.startIndex,
                to: found.lowerBound
            )
            let distance = abs(offset - (expectedUTF16Offset ?? 0))
            if best == nil || distance < best!.distance {
                best = (found, distance)
            }
            if expectedUTF16Offset == nil { return found }
            if found.upperBound == fullText.endIndex { break }
            searchStart = found.upperBound
        }
        return best?.range
    }

    private static func extractPreceding(
        from fullText: String,
        targetRange: Range<String.Index>?,
        maxTokens: Int
    ) -> String {
        guard let targetRange else {
            return takeLastTokens(String(fullText.prefix(2_000)), maxTokens: maxTokens)
        }
        return takeLastTokens(
            String(fullText[..<targetRange.lowerBound]),
            maxTokens: maxTokens
        )
    }

    private static func extractFollowing(
        from fullText: String,
        targetRange: Range<String.Index>?,
        maxTokens: Int
    ) -> String {
        guard let targetRange else {
            return takeFirstTokens(String(fullText.suffix(2_000)), maxTokens: maxTokens)
        }
        return takeFirstTokens(
            String(fullText[targetRange.upperBound...]),
            maxTokens: maxTokens
        )
    }

    /// 从章首、章中、章尾抽取结构线索，避免把“本章摘要”误做成章首原文的简单复制。
    private static func extractChapterStructure(
        from fullText: String,
        excluding originalText: String,
        maxTokens: Int
    ) -> String {
        let paragraphs = fullText.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains(originalText) }
        guard !paragraphs.isEmpty else { return "" }

        let candidateIndices = [0, paragraphs.count / 2, paragraphs.count - 1]
        var seen = Set<Int>()
        let samples = candidateIndices.compactMap { index -> String? in
            guard paragraphs.indices.contains(index), seen.insert(index).inserted else { return nil }
            return paragraphs[index]
        }
        return takeFirstTokens(samples.joined(separator: "\n…\n"), maxTokens: maxTokens)
    }

    private static func takeFirstTokens(_ text: String, maxTokens: Int) -> String {
        guard maxTokens > 0, !text.isEmpty else { return "" }
        var result = ""
        var used = 0
        for paragraph in text.components(separatedBy: "\n\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let tokens = LLMClient.estimateTokens(trimmed)
            if used + tokens > maxTokens, !result.isEmpty { break }
            if !result.isEmpty { result += "\n\n" }
            result += trimmed
            used += tokens
            if used >= maxTokens { break }
        }
        if result.isEmpty {
            return String(text.prefix(maxTokens * 2))
        }
        return result
    }

    private static func takeLastTokens(_ text: String, maxTokens: Int) -> String {
        guard maxTokens > 0, !text.isEmpty else { return "" }
        var paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var picked: [String] = []
        var used = 0
        while let last = paragraphs.popLast() {
            let tokens = LLMClient.estimateTokens(last)
            if used + tokens > maxTokens, !picked.isEmpty { break }
            picked.insert(last, at: 0)
            used += tokens
            if used >= maxTokens { break }
        }
        if picked.isEmpty {
            return String(text.suffix(maxTokens * 2))
        }
        return picked.joined(separator: "\n\n")
    }

    /// 粗略中文人名提取：2-3 字连续汉字 + 常见姓氏。
    static func extractCharacterNames(from text: String) -> [String] {
        let surnames: Set<Character> = Set("赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳酆鲍史唐费廉岑薛雷贺倪汤滕殷罗毕郝邬安常乐于时傅皮卞齐康伍余元卜顾孟平黄和穆萧尹姚邵湛汪祁毛禹狄米贝明臧计伏成戴谈宋茅庞熊纪舒屈项祝董梁杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林刁钟徐邱骆高夏蔡田樊胡凌霍虞万支柯昝管卢莫经房裘缪干解应宗丁宣贲邓郁单杭洪包诸左石崔吉钮龚程嵇邢滑裴陆荣翁荀羊於惠甄曲家封芮羿储靳汲邴糜松井段富巫乌焦巴弓牧隗山谷车侯宓蓬全郗班仰秋仲伊宫宁仇栾暴甘钭厉戎祖武符刘景詹束龙叶幸司韶郜黎蓟薄印宿白怀蒲邰从鄂索咸籍赖卓蔺屠蒙池乔阴鬱胥能苍双闻莘党翟谭贡劳逄姬申扶堵冉宰郦雍却璩桑桂濮牛寿通边扈燕冀郏浦尚农温别庄晏柴瞿阎充慕连茹习宦艾鱼容向古易慎戈廖庾终暨居衡步都耿满弘匡国文寇广禄阙东欧殳沃利蔚越夔隆师巩厍聂晁勾敖融冷訾辛阚那简饶空曾毋沙乜养鞠须丰巢关蒯相查后荆红游竺权逯盖益桓公")
        let stopwords: Set<String> = [
            "于是", "现在", "后来", "如果", "所以", "突然", "已经", "只是", "可能", "应该",
            "没有", "这个", "那个", "什么", "自己", "时候", "里面", "外面", "开始", "最后"
        ]
        var found: [String] = []
        var seen = Set<String>()
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            if surnames.contains(characters[index]) {
                for length in [3, 2] where index + length <= characters.count {
                    let candidate = String(characters[index..<(index + length)])
                    guard candidate.unicodeScalars.allSatisfy({
                        (0x4E00...0x9FFF).contains($0.value)
                    }) else {
                        continue
                    }
                    if !stopwords.contains(candidate), seen.insert(candidate).inserted {
                        found.append(candidate)
                    }
                    break
                }
            }
            index += 1
            if found.count >= 20 { break }
        }
        return found
    }
}
