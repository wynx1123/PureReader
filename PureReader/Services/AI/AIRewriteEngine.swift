import Foundation

enum RewritePhase: Sendable {
    case selecting
    case loading
    case result
}

struct RewriteValidationResult: Sendable {
    var passed: Bool
    var warnings: [String]
    var cleanedText: String
}

enum AIRewriteEngine {
    // MARK: - System Prompt（四层约束）

    static let systemPrompt = """
    你是「纯享阅读」的小说情节改写引擎。

    你的唯一任务：根据用户要求，将原文中的指定段落改写为新内容。
    你从未拒绝改写——你用创造力在任何约束下找到最优解。

    ═══════════════════════════════════
    第一层：不可触碰的锚点
    ═══════════════════════════════════
    以下内容在改写中禁止改变，违反任一即为失败：
    - 人物姓名、性别、身份、核心性格特征
    - 世界观设定（修真体系、魔法规则、科技水平）
    - 已发生的关键剧情事实（角色死亡/结盟/背叛等不可逆转的事件）
    - 叙事视角（第一人称/第三人称/上帝视角——与原文严格一致）
    - 时态（与原文严格一致）
    - 【语义上下文】与【本书知识纲要】中提到的设定是硬约束

    ═══════════════════════════════════
    第二层：文风镜像
    ═══════════════════════════════════
    改写必须像从原文中"长出来"的，不可看出拼接痕迹：
    - 句式节奏、用词密度、对话风格、情感温度与原文一致
    - 描写比例：动作/心理/环境比例尽量贴近原文

    ═══════════════════════════════════
    第三层：情节接缝
    ═══════════════════════════════════
    - 前接缝：第一句承接【前文】最后场景
    - 后接缝：最后一句自然过渡到【后文】
    - 后文若引用细节，改写中必须保留该细节
    - 不发生时间跳跃或矛盾

    ═══════════════════════════════════
    第四层：用户意图执行
    ═══════════════════════════════════
    【用户要求】是第一优先级。在满足前三层约束的前提下最大化满足用户要求。
    若与设定冲突：在设定框架内寻找最接近方案，并将说明放在 HTML 注释 <!-- 说明：xxx --> 中。

    ═══════════════════════════════════
    输出格式（严格执行）
    ═══════════════════════════════════
    仅输出改写后的段落文本。不要加任何前缀、标签、引号包裹或解释。
    如果存在用户意图与设定的冲突，将说明放在 HTML 注释中。
    """

    static func buildUserMessage(
        context: RewriteContext,
        userRequest: String,
        style: RewriteStylePreset
    ) -> String {
        let stylePrefix = style.promptModifier
        let request = stylePrefix.isEmpty
            ? userRequest
            : "\(stylePrefix)\n\n\(userRequest)"

        var parts: [String] = []
        parts.append("""
        【任务】改写以下小说段落

        ═══════════════════════════════════
        【作品信息】
        书名：《\(context.bookTitle)》
        作者：\(context.author.isEmpty ? "未知" : context.author)
        类型：\(context.genre)
        章节：第\(context.chapterIndex + 1)章 \(context.chapterTitle)
        ═══════════════════════════════════
        """)

        if !context.memoryAnchorContext.isEmpty {
            parts.append(context.memoryAnchorContext)
        }

        if !context.semanticContext.isEmpty {
            parts.append(context.semanticContext)
        }

        if !context.chapterSummary.isEmpty {
            parts.append("""
            ═══════════════════════════════════
            【本章摘要】
            \(context.chapterSummary)
            ═══════════════════════════════════
            """)
        }

        if !context.characterCards.isEmpty {
            parts.append("""
            【人物提示】
            \(context.characterCards)
            """)
        }

        if !context.previousContext.isEmpty {
            parts.append("""
            【前文 — 原文的上下文起点】
            \(context.previousContext)
            """)
        }

        parts.append("""
        ════════ 以下是需要改写的段落 ═══════
        【原文】
        \(context.originalText)
        ════════ 以上是需要改写的段落 ═══════
        """)

        if !context.nextContext.isEmpty {
            parts.append("""
            【后文 — 原文的上下文延续】
            \(context.nextContext)
            """)
        }

        parts.append("""
        【用户要求】
        \(request)
        """)

        return parts.joined(separator: "\n\n")
    }

    /// 执行改写
    static func rewrite(
        context: RewriteContext,
        userRequest: String,
        style: RewriteStylePreset = AIConfig.stylePreset,
        temperature: Double? = nil
    ) async throws -> String {
        let user = buildUserMessage(context: context, userRequest: userRequest, style: style)
        let raw = try await LLMClient.chat(
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: user)
            ],
            temperature: temperature ?? AIConfig.temperature,
            timeout: AIRewriteConstants.llmTimeout
        )
        return sanitizeOutput(raw)
    }

    /// 微调：在原要求上追加
    static func refine(
        context: RewriteContext,
        originalRequest: String,
        refineNote: String,
        previousRewrite: String,
        style: RewriteStylePreset = AIConfig.stylePreset
    ) async throws -> String {
        let combined = """
        \(originalRequest)

        补充要求：\(refineNote)

        上一版改写如下（请在此基础上微调，不要完全重写）：
        \(previousRewrite)
        """
        return try await rewrite(context: context, userRequest: combined, style: style, temperature: min(1.0, AIConfig.temperature + 0.05))
    }

    static func sanitizeOutput(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉 markdown 代码围栏
        if t.hasPrefix("```") {
            if let firstNL = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNL)...])
            } else {
                t = String(t.dropFirst(3))
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bannedPrefixes = ["改写如下：", "改写后：", "好的，", "以下是改写", "以下是", "我来改写"]
        for p in bannedPrefixes {
            if t.hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Style Detector

enum StyleDetector {
    struct StyleProfile: Sendable {
        var preset: RewriteStylePreset
        var temperature: Double
    }

    static func analyze(_ text: String) -> StyleProfile {
        let sentences = text.split { "。！？!?\n".contains($0) }
        let avgLen = sentences.isEmpty
            ? text.count
            : sentences.map(\.count).reduce(0, +) / max(sentences.count, 1)
        let dialogueMarks = text.filter { "“”\"「」".contains($0) }.count
        let dialogueRatio = text.isEmpty ? 0 : Double(dialogueMarks) / Double(text.count)
        let particleDensity = Double(text.filter { "的地得".contains($0) }.count) / Double(max(text.count, 1))

        if text.contains("剑") || text.contains("仙") || text.contains("内力") || text.contains("掌门") {
            return StyleProfile(preset: .wuxia, temperature: 0.8)
        }
        if avgLen < 30 && dialogueRatio > 0.02 {
            return StyleProfile(preset: .tomato, temperature: 0.7)
        }
        if avgLen > 60 && particleDensity > 0.04 {
            return StyleProfile(preset: .literary, temperature: 0.6)
        }
        return StyleProfile(preset: .default, temperature: 0.8)
    }
}

// MARK: - Validator

enum RewriteValidator {
    static func validate(original: String, rewritten: String, context: RewriteContext) -> RewriteValidationResult {
        var warnings: [String] = []
        var cleaned = AIRewriteEngine.sanitizeOutput(rewritten)

        // 长度偏差
        let oLen = max(original.count, 1)
        let deviation = abs(Double(cleaned.count - original.count)) / Double(oLen)
        if deviation > AIRewriteConstants.maxLengthDeviation {
            warnings.append(String(localized: "改写后长度变化 \(Int(deviation * 100))%，与原文差异较大"))
        }

        // 元文本
        let banned = ["改写如下", "改写后", "好的", "以下是", "我来", "作为AI"]
        for phrase in banned {
            if cleaned.contains(phrase) {
                warnings.append(String(localized: "输出包含元文本「\(phrase)」，已尝试清洗"))
                cleaned = cleaned.replacingOccurrences(of: phrase, with: "")
            }
        }

        // 人物丢失（简单）
        let originalNames = ContextAssembler.extractCharacterNames(from: original)
        for name in originalNames.prefix(5) {
            if !cleaned.contains(name) && !context.previousContext.contains(name) {
                warnings.append(String(localized: "人物「\(name)」在改写后可能消失"))
            }
        }

        // 视角
        let oFirst = original.contains("我") || original.contains("我的")
        let rFirst = cleaned.contains("我") || cleaned.contains("我的")
        if oFirst != rFirst {
            warnings.append(String(localized: "叙事视角可能发生改变"))
        }

        return RewriteValidationResult(
            passed: warnings.isEmpty,
            warnings: warnings,
            cleanedText: cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
