import Foundation

enum RewritePhase: Sendable {
    case selecting
    case loading
    case result
}

enum RewriteProgressStage: Sendable, Equatable {
    case planning
    case drafting
    case validating
    case repairing
    case completed

    var title: String {
        switch self {
        case .planning: return String(localized: "正在分析情节目标…")
        case .drafting: return String(localized: "正在按结构生成正文…")
        case .validating: return String(localized: "正在检查人物与衔接…")
        case .repairing: return String(localized: "正在修复一致性问题…")
        case .completed: return String(localized: "改写完成")
        }
    }
}

struct RewritePlan: Codable, Sendable, Equatable {
    var intentSummary: String
    var narrativeGoal: String
    var mustPreserve: [String]
    var storyBeats: [String]
    var transitionRequirements: [String]
    var styleNotes: [String]
    var targetLength: String

    var promptBlock: String {
        var sections: [String] = [
            "【改写结构方案】",
            "意图：\(intentSummary)",
            "叙事目标：\(narrativeGoal)",
            "目标长度：\(targetLength)"
        ]
        if !mustPreserve.isEmpty {
            sections.append("必须保留：\n" + bulletList(mustPreserve))
        }
        if !storyBeats.isEmpty {
            sections.append("情节节拍：\n" + numberedList(storyBeats))
        }
        if !transitionRequirements.isEmpty {
            sections.append("前后衔接：\n" + bulletList(transitionRequirements))
        }
        if !styleNotes.isEmpty {
            sections.append("文风控制：\n" + bulletList(styleNotes))
        }
        return sections.joined(separator: "\n")
    }

    private func bulletList(_ values: [String]) -> String {
        values.map { "- \($0)" }.joined(separator: "\n")
    }

    private func numberedList(_ values: [String]) -> String {
        values.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

struct RewriteValidationResult: Sendable {
    var passed: Bool
    var warnings: [String]
    var cleanedText: String
    var needsRepair: Bool
}

struct RewriteOutcome: Sendable {
    var text: String
    var plan: RewritePlan
    var validation: RewriteValidationResult
}

struct RewriteApplication: Sendable {
    var originalText: String
    var rewrittenText: String
    var userRequest: String
    var style: RewriteStylePreset
    var expectedUTF16Offset: Int?
}

enum AIRewriteEngine {
    // MARK: - Prompts

    static let systemPrompt = """
    你是「纯享阅读」的小说情节改写引擎。

    你的任务是依据【改写结构方案】和用户要求，改写指定小说段落。先保证故事逻辑，
    再追求语言表现；不要把改写写成摘要、提纲或解释。

    ═══════════════════════════════════
    第一层：不可触碰的锚点
    ═══════════════════════════════════
    - 人物姓名、性别、身份、核心性格与人物关系
    - 世界观规则、力量体系、时代与科技水平
    - 已经发生的不可逆剧情事实
    - 原文叙事视角与时态
    - 【本书知识纲要】、【相关设定】和结构方案中的“必须保留”项

    ═══════════════════════════════════
    第二层：情节结构
    ═══════════════════════════════════
    - 严格按结构方案中的情节节拍推进，但正文不得出现提纲措辞
    - 每个动作必须有动机，每个结果必须能由前文推出
    - 不凭空新增能改变全书走向的角色、能力、道具或规则
    - 用户要求改变事件结果时，要同步修正因果链，而不是只替换一句结论

    ═══════════════════════════════════
    第三层：文风与接缝
    ═══════════════════════════════════
    - 句式节奏、用词密度、对话方式和情感温度贴近原文
    - 第一句承接【前文】；最后一句自然进入【后文】
    - 后文已经引用的动作、物件、位置和信息必须保留

    ═══════════════════════════════════
    第四层：用户意图
    ═══════════════════════════════════
    在上述约束内最大化满足用户要求。若要求与硬设定冲突，采用最接近且不破坏设定的方案。

    输出格式：只输出可直接替换原文的小说正文，不要标题、前缀、Markdown、分析或解释。
    """

    private static let planningPrompt = """
    你是小说改写的情节规划器。请先把用户要求转化成一个可执行、可校验的局部改写方案。

    规划原则：
    1. 区分“必须保留的事实”和“允许改变的情节”。
    2. 用 3-6 个情节节拍描述改写段落内部的因果推进。
    3. 明确如何从前文进入、如何衔接后文。
    4. 目标长度应接近原文，除非用户明确要求扩写或缩写。
    5. 不得虚构输入中没有依据的全书设定。

    只输出 JSON，不要 Markdown：
    {
      "intentSummary":"一句话概括用户真正想改什么",
      "narrativeGoal":"这段改写在当前章节中的叙事作用",
      "mustPreserve":["人物/设定/后文依赖的硬约束"],
      "storyBeats":["节拍1","节拍2","节拍3"],
      "transitionRequirements":["前接缝要求","后接缝要求"],
      "styleNotes":["视角、语气、节奏要求"],
      "targetLength":"例如 300-450 字"
    }
    """

    private static let repairPrompt = """
    你是小说改写的终稿修订器。修复候选正文中的一致性问题，同时保留已经实现的用户意图。
    严格遵守结构方案、人物设定、前后文接缝和原文叙事视角。
    只输出修订后的小说正文，不要解释。
    """

    // MARK: - Message assembly

    static func buildUserMessage(
        context: RewriteContext,
        userRequest: String,
        style: RewriteStylePreset,
        plan: RewritePlan? = nil
    ) -> String {
        let stylePrefix = style.promptModifier
        let request = stylePrefix.isEmpty
            ? userRequest
            : "\(stylePrefix)\n\n\(userRequest)"

        var parts: [String] = []
        parts.append("""
        【任务】改写以下小说段落

        【作品信息】
        书名：《\(context.bookTitle)》
        作者：\(context.author.isEmpty ? "未知" : context.author)
        类型：\(context.genre)
        章节：第\(context.chapterIndex + 1)章 \(context.chapterTitle)
        """)

        if let plan {
            parts.append(plan.promptBlock)
        }
        if !context.memoryAnchorContext.isEmpty {
            parts.append(context.memoryAnchorContext)
        }
        if !context.semanticContext.isEmpty {
            parts.append(context.semanticContext)
        }
        if !context.chapterSummary.isEmpty {
            parts.append("""
            【本章结构线索】
            \(context.chapterSummary)
            """)
        }
        if !context.characterCards.isEmpty {
            parts.append("""
            【当前人物提示】
            \(context.characterCards)
            """)
        }
        if !context.previousContext.isEmpty {
            parts.append("""
            【前文】
            \(context.previousContext)
            """)
        }

        parts.append("""
        ════════ 需要改写的原文 ═══════
        \(context.originalText)
        ════════ 原文结束 ═══════
        """)

        if !context.nextContext.isEmpty {
            parts.append("""
            【后文】
            \(context.nextContext)
            """)
        }

        parts.append("""
        【用户要求】
        \(request)
        """)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Structured pipeline

    static func rewriteStructured(
        context: RewriteContext,
        userRequest: String,
        style: RewriteStylePreset = AIConfig.stylePreset,
        temperature: Double? = nil,
        progress: (@MainActor (RewriteProgressStage) -> Void)? = nil
    ) async throws -> RewriteOutcome {
        await progress?(.planning)
        let plan: RewritePlan
        do {
            plan = try await createPlan(
                context: context,
                userRequest: userRequest,
                style: style
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 规划模型或 JSON 输出不兼容时仍可使用本地保底结构继续生成。
            plan = fallbackPlan(
                context: context,
                userRequest: userRequest,
                style: style
            )
        }

        await progress?(.drafting)
        let userMessage = buildUserMessage(
            context: context,
            userRequest: userRequest,
            style: style,
            plan: plan
        )
        let rawDraft = try await LLMClient.chat(
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userMessage)
            ],
            temperature: temperature ?? AIConfig.temperature,
            timeout: AIRewriteConstants.llmTimeout
        )

        await progress?(.validating)
        var validation = RewriteValidator.validate(
            original: context.originalText,
            rewritten: rawDraft,
            context: context,
            plan: plan
        )

        if validation.needsRepair {
            await progress?(.repairing)
            if let repaired = try? await repairDraft(
                context: context,
                userRequest: userRequest,
                style: style,
                plan: plan,
                candidate: validation.cleanedText,
                issues: validation.warnings
            ) {
                let repairedValidation = RewriteValidator.validate(
                    original: context.originalText,
                    rewritten: repaired,
                    context: context,
                    plan: plan
                )
                if !repairedValidation.needsRepair
                    || repairedValidation.warnings.count <= validation.warnings.count {
                    validation = repairedValidation
                }
            }
        }

        await progress?(.completed)
        return RewriteOutcome(
            text: validation.cleanedText,
            plan: plan,
            validation: validation
        )
    }

    /// 兼容原有调用方，仅返回正文。
    static func rewrite(
        context: RewriteContext,
        userRequest: String,
        style: RewriteStylePreset = AIConfig.stylePreset,
        temperature: Double? = nil
    ) async throws -> String {
        let outcome = try await rewriteStructured(
            context: context,
            userRequest: userRequest,
            style: style,
            temperature: temperature
        )
        return outcome.text
    }

    static func refineStructured(
        context: RewriteContext,
        originalRequest: String,
        refineNote: String,
        previousRewrite: String,
        style: RewriteStylePreset = AIConfig.stylePreset,
        progress: (@MainActor (RewriteProgressStage) -> Void)? = nil
    ) async throws -> RewriteOutcome {
        let combined = """
        \(originalRequest)

        补充要求：\(refineNote)

        上一版改写如下。保留其中已经正确实现的部分，只调整与补充要求相关的内容：
        \(previousRewrite)
        """
        return try await rewriteStructured(
            context: context,
            userRequest: combined,
            style: style,
            temperature: min(1.0, AIConfig.temperature + 0.05),
            progress: progress
        )
    }

    static func refine(
        context: RewriteContext,
        originalRequest: String,
        refineNote: String,
        previousRewrite: String,
        style: RewriteStylePreset = AIConfig.stylePreset
    ) async throws -> String {
        let outcome = try await refineStructured(
            context: context,
            originalRequest: originalRequest,
            refineNote: refineNote,
            previousRewrite: previousRewrite,
            style: style
        )
        return outcome.text
    }

    // MARK: - Planning / repair

    private static func createPlan(
        context: RewriteContext,
        userRequest: String,
        style: RewriteStylePreset
    ) async throws -> RewritePlan {
        let planningInput = """
        【作品】《\(context.bookTitle)》 第\(context.chapterIndex + 1)章 \(context.chapterTitle)
        【用户要求】\(userRequest)
        【风格要求】\(style.promptModifier.isEmpty ? "贴近原文" : style.promptModifier)
        【原文长度】\(context.originalText.count) 字

        【前文末尾】
        \(clip(context.previousContext, limit: 900, fromEnd: true))

        【原文】
        \(clip(context.originalText, limit: 3_500))

        【后文开头】
        \(clip(context.nextContext, limit: 700))

        【全书约束】
        \(clip(context.memoryAnchorContext, limit: 1_200))

        【相关设定】
        \(clip(context.semanticContext, limit: 1_000))
        """
        let raw = try await LLMClient.chat(
            messages: [
                .init(role: "system", content: planningPrompt),
                .init(role: "user", content: planningInput)
            ],
            temperature: 0.2,
            timeout: AIRewriteConstants.llmTimeout
        )
        return parsePlan(raw, originalLength: context.originalText.count)
            ?? fallbackPlan(
                context: context,
                userRequest: userRequest,
                style: style
            )
    }

    private static func repairDraft(
        context: RewriteContext,
        userRequest: String,
        style: RewriteStylePreset,
        plan: RewritePlan,
        candidate: String,
        issues: [String]
    ) async throws -> String {
        let user = """
        \(buildUserMessage(
            context: context,
            userRequest: userRequest,
            style: style,
            plan: plan
        ))

        【候选正文】
        \(candidate)

        【必须修复的问题】
        \(issues.map { "- \($0)" }.joined(separator: "\n"))
        """
        let raw = try await LLMClient.chat(
            messages: [
                .init(role: "system", content: repairPrompt),
                .init(role: "user", content: user)
            ],
            temperature: max(0.2, AIConfig.temperature - 0.2),
            timeout: AIRewriteConstants.llmTimeout
        )
        return sanitizeOutput(raw)
    }

    private struct PlanPayload: Decodable {
        var intentSummary: String?
        var narrativeGoal: String?
        var mustPreserve: [String]?
        var storyBeats: [String]?
        var transitionRequirements: [String]?
        var styleNotes: [String]?
        var targetLength: String?
    }

    private static func parsePlan(_ raw: String, originalLength: Int) -> RewritePlan? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PlanPayload.self, from: data) else {
            return nil
        }

        let intent = clean(payload.intentSummary) ?? "按用户要求调整当前情节"
        let goal = clean(payload.narrativeGoal) ?? intent
        let beats = clean(payload.storyBeats, limit: 6)
        guard !beats.isEmpty else { return nil }
        return RewritePlan(
            intentSummary: intent,
            narrativeGoal: goal,
            mustPreserve: clean(payload.mustPreserve, limit: 10),
            storyBeats: beats,
            transitionRequirements: clean(payload.transitionRequirements, limit: 6),
            styleNotes: clean(payload.styleNotes, limit: 6),
            targetLength: clean(payload.targetLength)
                ?? "\(max(40, Int(Double(originalLength) * 0.75)))-\(max(80, Int(Double(originalLength) * 1.30))) 字"
        )
    }

    private static func fallbackPlan(
        context: RewriteContext,
        userRequest: String,
        style: RewriteStylePreset
    ) -> RewritePlan {
        let originalLength = max(context.originalText.count, 1)
        let lower = max(40, Int(Double(originalLength) * 0.75))
        let upper = max(lower + 20, Int(Double(originalLength) * 1.30))
        var preserve = ContextAssembler.extractCharacterNames(from: context.originalText)
            .prefix(6)
            .map { "保留人物「\($0)」的身份与关系" }
        if preserve.isEmpty {
            preserve = ["保留原文叙事视角、时态和已发生事实"]
        }
        return RewritePlan(
            intentSummary: userRequest,
            narrativeGoal: "在当前场景中落实用户要求，并保持因果链完整",
            mustPreserve: preserve,
            storyBeats: [
                "承接前文中的人物状态与场景位置",
                "通过人物行动或对话落实改写要求",
                "补足选择带来的直接因果结果",
                "收束到后文可以自然承接的状态"
            ],
            transitionRequirements: [
                "开头承接前文最后一个动作或情绪",
                "结尾保留后文依赖的信息与场景状态"
            ],
            styleNotes: [
                style.promptModifier.isEmpty ? "贴近原文语言与节奏" : style.promptModifier,
                "保持原文叙事视角与时态"
            ],
            targetLength: "\(lower)-\(upper) 字"
        )
    }

    private static func clean(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private static func clean(_ values: [String]?, limit: Int) -> [String] {
        Array((values ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit))
    }

    private static func clip(_ text: String, limit: Int, fromEnd: Bool = false) -> String {
        guard text.count > limit else { return text }
        return fromEnd ? String(text.suffix(limit)) : String(text.prefix(limit))
    }

    static func sanitizeOutput(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            } else {
                cleaned = String(cleaned.dropFirst(3))
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bannedPrefixes = ["改写如下：", "改写后：", "好的，", "以下是改写", "以下是", "我来改写"]
        for prefix in bannedPrefixes where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}

// MARK: - Style detector

enum StyleDetector {
    struct StyleProfile: Sendable {
        var preset: RewriteStylePreset
        var temperature: Double
    }

    static func analyze(_ text: String) -> StyleProfile {
        let sentences = text.split { "。！？!?\n".contains($0) }
        let averageLength = sentences.isEmpty
            ? text.count
            : sentences.map(\.count).reduce(0, +) / max(sentences.count, 1)
        let dialogueMarks = text.filter { "“”\"「」".contains($0) }.count
        let dialogueRatio = text.isEmpty ? 0 : Double(dialogueMarks) / Double(text.count)
        let particleDensity = Double(text.filter { "的地得".contains($0) }.count)
            / Double(max(text.count, 1))

        if text.contains("剑") || text.contains("仙") || text.contains("内力") || text.contains("掌门") {
            return StyleProfile(preset: .wuxia, temperature: 0.8)
        }
        if averageLength < 30 && dialogueRatio > 0.02 {
            return StyleProfile(preset: .tomato, temperature: 0.7)
        }
        if averageLength > 60 && particleDensity > 0.04 {
            return StyleProfile(preset: .literary, temperature: 0.6)
        }
        return StyleProfile(preset: .default, temperature: 0.8)
    }
}

// MARK: - Validator

enum RewriteValidator {
    static func validate(
        original: String,
        rewritten: String,
        context: RewriteContext,
        plan: RewritePlan? = nil
    ) -> RewriteValidationResult {
        var warnings: [String] = []
        var needsRepair = false
        var cleaned = AIRewriteEngine.sanitizeOutput(rewritten)
        let originalLength = max(original.count, 1)

        if cleaned.isEmpty {
            warnings.append(String(localized: "模型没有返回可替换的正文"))
            needsRepair = true
        } else if cleaned.count < max(20, originalLength / 5) {
            warnings.append(String(localized: "改写结果过短，可能丢失主要情节"))
            needsRepair = true
        }

        let deviation = abs(Double(cleaned.count - original.count)) / Double(originalLength)
        if deviation > AIRewriteConstants.maxLengthDeviation {
            warnings.append(String(localized: "改写后长度变化 \(Int(deviation * 100))%，与原文差异较大"))
        }
        if deviation > 1.2 {
            needsRepair = true
        }

        if cleaned == original.trimmingCharacters(in: .whitespacesAndNewlines) {
            warnings.append(String(localized: "结果与原文基本相同，尚未落实改写要求"))
            needsRepair = true
        }

        let banned = ["改写如下", "改写后", "作为AI", "作为 AI", "以下是我的"]
        for phrase in banned where cleaned.contains(phrase) {
            warnings.append(String(localized: "输出包含元文本「\(phrase)」，已尝试清洗"))
            cleaned = cleaned.replacingOccurrences(of: phrase, with: "")
        }

        let originalNames = ContextAssembler.extractCharacterNames(from: original)
        for name in originalNames.prefix(5) {
            if !cleaned.contains(name),
               !context.previousContext.contains(name),
               !context.nextContext.contains(name) {
                warnings.append(String(localized: "人物「\(name)」在改写后可能消失"))
            }
        }

        let originalFirstPerson = original.contains("我") || original.contains("我的")
        let rewrittenFirstPerson = cleaned.contains("我") || cleaned.contains("我的")
        if originalFirstPerson != rewrittenFirstPerson {
            warnings.append(String(localized: "叙事视角可能发生改变"))
        }

        if let plan, plan.storyBeats.count < 3 {
            warnings.append(String(localized: "情节结构方案过于简略"))
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return RewriteValidationResult(
            passed: warnings.isEmpty,
            warnings: warnings,
            cleanedText: cleaned,
            needsRepair: needsRepair
        )
    }
}
