import Foundation

/// 用户自配的 OpenAI 兼容 API 配置（Keychain 不强制，UserDefaults 明文可选；生产可换 Keychain）
enum AIConfig {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let apiBaseURL = "ai.apiBaseURL"
        static let apiKey = "ai.apiKey"
        static let chatModel = "ai.chatModel"
        static let embeddingModel = "ai.embeddingModel"
        static let embeddingDimensions = "ai.embeddingDimensions"
        static let enableBookUnderstanding = "ai.enableBookUnderstanding"
        static let stylePreset = "ai.stylePreset"
        static let maxContextTokens = "ai.maxContextTokens"
        static let temperature = "ai.temperature"
    }

    static var apiBaseURL: String {
        get {
            let v = defaults.string(forKey: Key.apiBaseURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? "https://api.openai.com/v1" : v
        }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.apiBaseURL) }
    }

    static var apiKey: String {
        get {
            // 优先 Keychain；迁移旧 UserDefaults 明文
            if let k = KeychainManager.get(Key.apiKey), !k.isEmpty {
                return k
            }
            if let legacy = defaults.string(forKey: Key.apiKey), !legacy.isEmpty {
                KeychainManager.set(legacy, forKey: Key.apiKey)
                defaults.removeObject(forKey: Key.apiKey)
                return legacy
            }
            return ""
        }
        set {
            if newValue.isEmpty {
                KeychainManager.delete(Key.apiKey)
            } else {
                KeychainManager.set(newValue, forKey: Key.apiKey)
            }
            defaults.removeObject(forKey: Key.apiKey)
        }
    }

    static var chatModel: String {
        get {
            let v = defaults.string(forKey: Key.chatModel) ?? ""
            return v.isEmpty ? "gpt-4o-mini" : v
        }
        set { defaults.set(newValue, forKey: Key.chatModel) }
    }

    static var embeddingModel: String {
        get {
            let v = defaults.string(forKey: Key.embeddingModel) ?? ""
            return v.isEmpty ? "text-embedding-3-small" : v
        }
        set { defaults.set(newValue, forKey: Key.embeddingModel) }
    }

    static var embeddingDimensions: Int {
        get {
            let v = defaults.integer(forKey: Key.embeddingDimensions)
            return v > 0 ? v : 1536
        }
        set { defaults.set(newValue, forKey: Key.embeddingDimensions) }
    }

    /// 「AI 理解本书」— 向量索引 + 记忆锚点后台消化
    static var enableBookUnderstanding: Bool {
        get {
            if defaults.object(forKey: Key.enableBookUnderstanding) == nil { return true }
            return defaults.bool(forKey: Key.enableBookUnderstanding)
        }
        set { defaults.set(newValue, forKey: Key.enableBookUnderstanding) }
    }

    static var stylePresetRaw: String {
        get { defaults.string(forKey: Key.stylePreset) ?? RewriteStylePreset.default.rawValue }
        set { defaults.set(newValue, forKey: Key.stylePreset) }
    }

    static var stylePreset: RewriteStylePreset {
        get { RewriteStylePreset(rawValue: stylePresetRaw) ?? .default }
        set { stylePresetRaw = newValue.rawValue }
    }

    static var maxContextTokens: Int {
        get {
            let v = defaults.integer(forKey: Key.maxContextTokens)
            return v > 0 ? v : AIRewriteConstants.defaultMaxContextTokens
        }
        set { defaults.set(newValue, forKey: Key.maxContextTokens) }
    }

    static var temperature: Double {
        get {
            let v = defaults.double(forKey: Key.temperature)
            return v > 0 ? v : 0.8
        }
        set { defaults.set(newValue, forKey: Key.temperature) }
    }

    static var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 规范化 base URL，去掉末尾 `/`，确保以 `/v1` 结尾可选
    static func resolvedBaseURL() -> URL? {
        var s = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}

enum AIRewriteConstants {
    static let defaultMaxContextTokens = 3000
    static let maxPrecedingParagraphs = 5
    static let maxFollowingParagraphs = 3
    static let chapterSummaryLength = 200
    static let characterCardMaxLength = 30
    static let llmTimeout: TimeInterval = 60
    static let streamTimeout: TimeInterval = 120
    static let maxRewriteHistory = 50
    static let maxLengthDeviation: Double = 0.5
    static let embeddingBatchSize = 16
    static let vectorTopK = 5
    static let vectorMinSimilarity: Float = 0.6
    static let rerankTopK = 8
    static let chunkSize = 512
    static let chunkOverlap = 64
}

enum RewriteStylePreset: String, CaseIterable, Identifiable, Sendable {
    case `default`
    case wuxia       // 金庸风
    case catty       // 猫腻风
    case tomato      // 番茄风
    case lightNovel  // 轻小说
    case literary    // 严肃文学

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: return String(localized: "默认")
        case .wuxia: return String(localized: "金庸风")
        case .catty: return String(localized: "猫腻风")
        case .tomato: return String(localized: "番茄风")
        case .lightNovel: return String(localized: "轻小说风")
        case .literary: return String(localized: "严肃文学")
        }
    }

    /// 拼接到 userRequest 前面的风格指令
    var promptModifier: String {
        switch self {
        case .default:
            return ""
        case .wuxia:
            return "使用金庸式武侠语言：半文半白、多用四字短语、武功描写具象化、人物对话有古韵但不晦涩。"
        case .catty:
            return "使用猫腻式文风：冷峻克制、内心独白丰富、句式短而有力、擅长用细节塑造人物、带轻微文艺感。"
        case .tomato:
            return "使用番茄（我吃西红柿）式文风：节奏快、描写简洁直接、战斗场景热血、等级体系清晰、弱化心理描写。"
        case .lightNovel:
            return "使用日式轻小说风格：口语化对话多、内心吐槽丰富、场景切换快、适量卖萌元素。"
        case .literary:
            return "使用严肃文学风格：描写细腻、心理刻画深入、语言精炼有张力、留白多、意象丰富。"
        }
    }
}
