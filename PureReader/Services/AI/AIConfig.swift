import Foundation

/// AI 改写与向量接口可分别配置；密钥仅保存在 Keychain。
enum AIConfig {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let legacyBaseURL = "ai.apiBaseURL"
        static let legacyAPIKey = "ai.apiKey"
        static let didMigrateSeparatedEndpoints = "ai.didMigrateSeparatedEndpoints"
        static let rewriteBaseURL = "ai.rewrite.baseURL"
        static let rewriteAPIKey = "ai.rewrite.apiKey"
        static let embeddingBaseURL = "ai.embedding.baseURL"
        static let embeddingAPIKey = "ai.embedding.apiKey"
        static let chatModel = "ai.chatModel"
        static let embeddingModel = "ai.embeddingModel"
        static let embeddingDimensions = "ai.embeddingDimensions"
        static let enableBookUnderstanding = "ai.enableBookUnderstanding"
        static let stylePreset = "ai.stylePreset"
        static let maxContextTokens = "ai.maxContextTokens"
        static let temperature = "ai.temperature"
    }

    static var rewriteBaseURL: String {
        get {
            migrateSeparatedEndpointsIfNeeded()
            return storedValue(for: Key.rewriteBaseURL, fallback: "https://api.openai.com/v1")
        }
        set { defaults.set(clean(newValue), forKey: Key.rewriteBaseURL) }
    }

    static var rewriteAPIKey: String {
        get {
            migrateSeparatedEndpointsIfNeeded()
            return keychainValue(for: Key.rewriteAPIKey)
        }
        set { setKeychainValue(newValue, for: Key.rewriteAPIKey) }
    }

    static var embeddingBaseURL: String {
        get {
            migrateSeparatedEndpointsIfNeeded()
            return storedValue(for: Key.embeddingBaseURL, fallback: "https://api.openai.com/v1")
        }
        set { defaults.set(clean(newValue), forKey: Key.embeddingBaseURL) }
    }

    static var embeddingAPIKey: String {
        get {
            migrateSeparatedEndpointsIfNeeded()
            return keychainValue(for: Key.embeddingAPIKey)
        }
        set { setKeychainValue(newValue, for: Key.embeddingAPIKey) }
    }

    // 兼容旧调用方，语义固定为改写接口。
    static var apiBaseURL: String {
        get { rewriteBaseURL }
        set { rewriteBaseURL = newValue }
    }

    static var apiKey: String {
        get { rewriteAPIKey }
        set { rewriteAPIKey = newValue }
    }

    static var chatModel: String {
        get { clean(defaults.string(forKey: Key.chatModel) ?? "") }
        set { defaults.set(clean(newValue), forKey: Key.chatModel) }
    }

    static var embeddingModel: String {
        get { clean(defaults.string(forKey: Key.embeddingModel) ?? "") }
        set { defaults.set(clean(newValue), forKey: Key.embeddingModel) }
    }

    static var embeddingDimensions: Int {
        get {
            guard defaults.object(forKey: Key.embeddingDimensions) != nil else { return 0 }
            return max(0, defaults.integer(forKey: Key.embeddingDimensions))
        }
        set { defaults.set(max(0, newValue), forKey: Key.embeddingDimensions) }
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
            guard defaults.object(forKey: Key.temperature) != nil else { return 0.8 }
            return defaults.double(forKey: Key.temperature)
        }
        set { defaults.set(newValue, forKey: Key.temperature) }
    }

    static var isConfigured: Bool {
        isRewriteConfigured
    }

    static var isRewriteConfigured: Bool {
        !rewriteAPIKey.isEmpty
            && !chatModel.isEmpty
            && resolvedRewriteBaseURL() != nil
    }

    static var isEmbeddingConfigured: Bool {
        !embeddingAPIKey.isEmpty
            && !embeddingModel.isEmpty
            && resolvedEmbeddingBaseURL() != nil
    }

    static func resolvedBaseURL() -> URL? {
        resolvedRewriteBaseURL()
    }

    static func resolvedRewriteBaseURL() -> URL? {
        resolvedURL(rewriteBaseURL)
    }

    static func resolvedEmbeddingBaseURL() -> URL? {
        resolvedURL(embeddingBaseURL)
    }

    private static func migrateSeparatedEndpointsIfNeeded() {
        guard !defaults.bool(forKey: Key.didMigrateSeparatedEndpoints) else { return }

        let legacyBase = storedValue(
            for: Key.legacyBaseURL,
            fallback: "https://api.openai.com/v1"
        )
        if defaults.string(forKey: Key.rewriteBaseURL) == nil {
            defaults.set(legacyBase, forKey: Key.rewriteBaseURL)
        }
        if defaults.string(forKey: Key.embeddingBaseURL) == nil {
            defaults.set(legacyBase, forKey: Key.embeddingBaseURL)
        }

        let legacyKey = keychainValue(for: Key.legacyAPIKey).isEmpty
            ? clean(defaults.string(forKey: Key.legacyAPIKey) ?? "")
            : keychainValue(for: Key.legacyAPIKey)
        if !legacyKey.isEmpty {
            if keychainValue(for: Key.rewriteAPIKey).isEmpty {
                KeychainManager.set(legacyKey, forKey: Key.rewriteAPIKey)
            }
            if keychainValue(for: Key.embeddingAPIKey).isEmpty {
                KeychainManager.set(legacyKey, forKey: Key.embeddingAPIKey)
            }
        }
        defaults.removeObject(forKey: Key.legacyAPIKey)
        defaults.set(true, forKey: Key.didMigrateSeparatedEndpoints)
    }

    private static func storedValue(for key: String, fallback: String) -> String {
        let value = clean(defaults.string(forKey: key) ?? "")
        return value.isEmpty ? fallback : value
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func keychainValue(for key: String) -> String {
        clean(KeychainManager.get(key) ?? "")
    }

    private static func setKeychainValue(_ value: String, for key: String) {
        let cleaned = clean(value)
        if cleaned.isEmpty {
            KeychainManager.delete(key)
        } else {
            KeychainManager.set(cleaned, forKey: key)
        }
    }

    private static func resolvedURL(_ value: String) -> URL? {
        var raw = clean(value)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw),
              url.host != nil,
              isTransportAcceptable(url)
        else { return nil }
        return url
    }
}

/// API Key 会随请求一起发出，公网必须走 HTTPS，否则密钥在链路上是明文。
///
/// App 级 ATS 仍为 NSAllowsArbitraryLoads（书源需要访问用户自选的任意站点，
/// 大量书源站只有 HTTP），因此这里在代码层按路径分别把关：
/// 书源路径继续允许 HTTP，密钥路径收紧为 HTTPS。
///
/// 例外：自建 / 局域网网关（Ollama、LM Studio、vLLM）走 HTTP 是常规用法，
/// 流量不出本地网络，一刀切会误伤，故放行本机与私有网段。
func isTransportAcceptable(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    if scheme == "https" { return true }
    guard scheme == "http", let host = url.host?.lowercased() else { return false }
    return isLocalOrPrivateHost(host)
}

private func isLocalOrPrivateHost(_ host: String) -> Bool {
    if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
    // Bonjour / 内网域名
    if host.hasSuffix(".local") || host.hasSuffix(".localhost") { return true }

    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
        return false
    }
    switch (parts[0], parts[1]) {
    case (10, _): return true                   // 10.0.0.0/8
    case (192, 168): return true                // 192.168.0.0/16
    case (172, 16...31): return true            // 172.16.0.0/12
    case (127, _): return true                  // 回环
    case (169, 254): return true                // link-local
    default: return false
    }
}

enum AIRewriteConstants {
    static let defaultMaxContextTokens = 3000
    /// Planning should fail fast so a local fallback plan can continue the rewrite.
    static let planningTimeout: TimeInterval = 15
    /// Draft generation may be slower for local models, proxies, and long selections.
    static let llmTimeout: TimeInterval = 180
    /// Repair is optional; keep it shorter so a usable first draft is not held too long.
    static let repairTimeout: TimeInterval = 45
    static let maxRewriteHistory = 50
    static let maxLengthDeviation: Double = 0.5
    static let embeddingBatchSize = 16
    static let vectorTopK = 5
    static let vectorMinSimilarity: Float = 0.6
    static let chunkSize = 512
    static let chunkOverlap = 64
}

enum NetworkTTSConfig {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let openAIBaseURL = "tts.openAI.baseURL"
        static let openAIAPIKey = "tts.openAI.apiKey"
        static let openAIModel = "tts.openAI.model"
        static let miMoBaseURL = "tts.miMo.baseURL"
        static let miMoAPIKey = "tts.miMo.apiKey"
        static let miMoModel = "tts.miMo.model"
        static let fishBaseURL = "tts.fish.baseURL"
        static let fishAPIKey = "tts.fish.apiKey"
        static let fishModel = "tts.fish.model"
        static let fishReferenceID = "tts.fish.referenceID"
    }

    static var openAIBaseURL: String {
        get { value(for: Key.openAIBaseURL, fallback: "https://api.openai.com/v1") }
        set { defaults.set(clean(newValue), forKey: Key.openAIBaseURL) }
    }

    static var openAIAPIKey: String {
        get { keychainValue(for: Key.openAIAPIKey) }
        set { setKeychainValue(newValue, for: Key.openAIAPIKey) }
    }

    static var openAIModel: String {
        get { value(for: Key.openAIModel) }
        set { defaults.set(clean(newValue), forKey: Key.openAIModel) }
    }

    static var miMoBaseURL: String {
        get { value(for: Key.miMoBaseURL, fallback: "https://api.xiaomimimo.com/v1") }
        set { defaults.set(clean(newValue), forKey: Key.miMoBaseURL) }
    }

    static var miMoAPIKey: String {
        get { keychainValue(for: Key.miMoAPIKey) }
        set { setKeychainValue(newValue, for: Key.miMoAPIKey) }
    }

    static var miMoModel: String {
        get { value(for: Key.miMoModel) }
        set { defaults.set(clean(newValue), forKey: Key.miMoModel) }
    }

    static var fishBaseURL: String {
        get { value(for: Key.fishBaseURL, fallback: "https://api.fish.audio/v1") }
        set { defaults.set(clean(newValue), forKey: Key.fishBaseURL) }
    }

    static var fishAPIKey: String {
        get { keychainValue(for: Key.fishAPIKey) }
        set { setKeychainValue(newValue, for: Key.fishAPIKey) }
    }

    static var fishModel: String {
        get { value(for: Key.fishModel) }
        set { defaults.set(clean(newValue), forKey: Key.fishModel) }
    }

    static var fishReferenceID: String {
        get {
            (defaults.string(forKey: Key.fishReferenceID) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set { defaults.set(
            newValue.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Key.fishReferenceID
        ) }
    }

    static func isConfigured(for provider: TTSProvider) -> Bool {
        switch provider {
        case .system:
            return true
        case .openAICompatible:
            return !openAIAPIKey.isEmpty
                && !openAIModel.isEmpty
                && resolvedBaseURL(for: provider) != nil
        case .xiaomiMiMo:
            return !miMoAPIKey.isEmpty
                && !miMoModel.isEmpty
                && resolvedBaseURL(for: provider) != nil
        case .fishAudio:
            return !fishAPIKey.isEmpty
                && !fishModel.isEmpty
                && resolvedBaseURL(for: provider) != nil
        }
    }

    static func resolvedBaseURL(for provider: TTSProvider) -> URL? {
        let raw: String
        switch provider {
        case .system: return nil
        case .openAICompatible: raw = openAIBaseURL
        case .xiaomiMiMo: raw = miMoBaseURL
        case .fishAudio: raw = fishBaseURL
        }
        guard let url = URL(string: clean(raw)),
              url.host != nil,
              isTransportAcceptable(url)
        else { return nil }
        return url
    }

    static func apiKey(for provider: TTSProvider) -> String {
        switch provider {
        case .system: return ""
        case .openAICompatible: return openAIAPIKey
        case .xiaomiMiMo: return miMoAPIKey
        case .fishAudio: return fishAPIKey
        }
    }

    static func model(for provider: TTSProvider) -> String {
        switch provider {
        case .system: return ""
        case .openAICompatible: return openAIModel
        case .xiaomiMiMo: return miMoModel
        case .fishAudio: return fishModel
        }
    }

    static func setModel(_ model: String, for provider: TTSProvider) {
        switch provider {
        case .system: break
        case .openAICompatible: openAIModel = model
        case .xiaomiMiMo: miMoModel = model
        case .fishAudio: fishModel = model
        }
    }

    static func defaultVoice(for provider: TTSProvider) -> String {
        switch provider {
        case .fishAudio: return fishReferenceID
        default: return provider.defaultVoice
        }
    }

    private static func clean(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func value(for key: String) -> String {
        clean(defaults.string(forKey: key) ?? "")
    }

    private static func value(for key: String, fallback: String) -> String {
        let stored = value(for: key)
        return stored.isEmpty ? fallback : stored
    }

    private static func keychainValue(for key: String) -> String {
        KeychainManager.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func setKeychainValue(_ value: String, for key: String) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            KeychainManager.delete(key)
        } else {
            KeychainManager.set(cleaned, forKey: key)
        }
    }
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
