import Foundation
import SwiftData

/// 书源类型 / 格式
enum BookSourceFormat: String, Codable, CaseIterable, Sendable {
    case pureReader
    case legado
    case aiYueJi

    var displayName: String {
        switch self {
        case .pureReader: return "PureReader"
        case .legado: return "Legado 阅读3.0"
        case .aiYueJi: return "爱阅记"
        }
    }
}

/// Native adapters for sources whose Legado files depend on JavaScript APIs.
/// The adapter is derived from the imported source identity and is not persisted
/// as a separate SwiftData field, so existing stores do not need a migration.
enum NativeBookSourceAdapter: String, Sendable {
    case pixivNovel
    case linpx
    case furryNovel

    static func detect(name: String, bookSourceURL: String) -> Self? {
        let lowerName = name.lowercased()
        let lowerURL = bookSourceURL.lowercased()
        if lowerURL.contains("/manga") { return nil }
        if lowerName.contains("pixiv") && (lowerURL.contains("pixiv.net") || lowerURL.isEmpty) {
            return .pixivNovel
        }
        if lowerName.contains("linpx") || lowerURL.contains("furrynovel.ink")
            || lowerURL.contains("api.linpx.ink") {
            return .linpx
        }
        if lowerName.contains("furrynovel") || lowerName.contains("兽人小说")
            || lowerURL.contains("furrynovel.com") || lowerURL.contains("api.furrynovel.com") {
            return .furryNovel
        }
        return nil
    }

    var baseURL: String {
        switch self {
        case .pixivNovel: return "https://www.pixiv.net"
        case .linpx: return "https://api.linpx.ink"
        case .furryNovel: return "https://api.furrynovel.com"
        }
    }

    var searchURLTemplate: String {
        switch self {
        case .pixivNovel:
            return "https://www.pixiv.net/ajax/search/novels/{{key}}?order=date_d&mode=all&p={{page}}&s_mode=s_tag&lang=zh"
        case .linpx:
            return "https://api.linpx.ink/pixiv/search/novel/{{key}}/cache?page={{page}}"
        case .furryNovel:
            return "https://api.furrynovel.com/api/zh/novel?page={{page}}&order_by=popular&keyword={{key}}"
        }
    }

    var displayName: String {
        switch self {
        case .pixivNovel: return "Pixiv 小说原生适配"
        case .linpx: return "Linpx 原生适配"
        case .furryNovel: return "FurryNovel 原生适配"
        }
    }
}

/// 解析规则（搜索 / 详情 / 目录 / 正文）
struct ParseRule: Codable, Hashable, Sendable {
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var coverUrl: String?
    var bookUrl: String?
    var tocUrl: String?
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var content: String?
    /// 下一页（可选）
    var nextPage: String?
    /// 替换规则 `old##new@@old2##new2`
    var replaceRegex: String?

    static let empty = ParseRule()
}

@Model
final class BookSource {
    @Attribute(.unique) var id: UUID
    var name: String
    var groupName: String
    /// 搜索 URL，`{{key}}` 为关键词，`{{page}}` 为页码
    var searchURL: String
    /// Discover/category URL. Legado commonly uses title::URL&&title2::URL.
    var exploreURL: String = ""
    var bookURL: String
    var tocURL: String
    var contentURL: String
    /// 书源级请求头，保存为 JSON 字符串以兼容 Legado 的 header 字段。
    var headerJSON: String = ""
    /// JSON 序列化的 ParseRule
    var ruleJSON: String
    /// Discover-page rules; falls back to search rules when empty.
    var exploreRuleJSON: String = ""
    var enabled: Bool
    var formatRaw: String
    var bookCount: Int
    var lastCheckedAt: Date?
    var isValid: Bool
    var comment: String
    var weight: Int
    var createdAt: Date

    var format: BookSourceFormat {
        get { BookSourceFormat(rawValue: formatRaw) ?? .pureReader }
        set { formatRaw = newValue.rawValue }
    }

    var exploreRules: ParseRule {
        get {
            guard !exploreRuleJSON.isEmpty,
                  let data = exploreRuleJSON.data(using: .utf8),
                  let value = try? JSONDecoder().decode(ParseRule.self, from: data) else {
                return rules
            }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let text = String(data: data, encoding: .utf8) {
                exploreRuleJSON = text
            }
        }
    }

    var rules: ParseRule {
        get {
            guard let data = ruleJSON.data(using: .utf8),
                  let r = try? JSONDecoder().decode(ParseRule.self, from: data) else {
                return .empty
            }
            return r
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let s = String(data: data, encoding: .utf8) {
                ruleJSON = s
            }
        }
    }

    init(
        id: UUID = UUID(),
        name: String,
        groupName: String = "",
        searchURL: String = "",
        exploreURL: String = "",
        bookURL: String = "",
        tocURL: String = "",
        contentURL: String = "",
        headerJSON: String = "",
        rules: ParseRule = .empty,
        exploreRules: ParseRule? = nil,
        enabled: Bool = true,
        format: BookSourceFormat = .pureReader,
        comment: String = "",
        weight: Int = 0
    ) {
        self.id = id
        self.name = name
        self.groupName = groupName
        self.searchURL = searchURL
        self.exploreURL = exploreURL
        self.bookURL = bookURL
        self.tocURL = tocURL
        self.contentURL = contentURL
        self.headerJSON = headerJSON
        if let data = try? JSONEncoder().encode(rules),
           let s = String(data: data, encoding: .utf8) {
            self.ruleJSON = s
        } else {
            self.ruleJSON = "{}"
        }
        if let exploreRules,
           let data = try? JSONEncoder().encode(exploreRules),
           let text = String(data: data, encoding: .utf8) {
            self.exploreRuleJSON = text
        } else {
            self.exploreRuleJSON = ""
        }
        self.enabled = enabled
        self.formatRaw = format.rawValue
        self.bookCount = 0
        self.lastCheckedAt = nil
        self.isValid = true
        self.comment = comment
        self.weight = weight
        self.createdAt = Date()
    }
}

/// 搜索结果条目（非持久）
struct SourceSearchResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    var name: String
    var author: String
    var intro: String
    var coverURL: String?
    var bookURL: String
    var sourceID: UUID
    var sourceName: String
}

/// 目录章节条目
struct SourceChapterItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    var url: String
    var index: Int
}


/// Discover-page category entry.
struct SourceExploreCategory: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    var url: String
    var sourceID: UUID
    var sourceName: String
}

/// Request used to open a source URL in the verification screen.
struct BookSourceVerificationRequest: Identifiable, Hashable, Sendable {
    let id = UUID()
    var sourceID: UUID
    var sourceName: String
    var url: URL
}

// MARK: - Health check types

/// 检测步骤。
enum CheckStep: String, Sendable, CaseIterable {
    case search
    case detail
    case catalog
    case content

    var displayName: String {
        switch self {
        case .search: return String(localized: "搜索")
        case .detail: return String(localized: "详情")
        case .catalog: return String(localized: "目录")
        case .content: return String(localized: "正文")
        }
    }
}

/// 检测状态。
enum CheckStatus: String, Codable, Sendable, CaseIterable {
    case notRun
    case running
    case passed
    case failed
    case verificationRequired
    case rateLimited
    case unsupported

    var displayName: String {
        switch self {
        case .notRun: return String(localized: "未检测")
        case .running: return String(localized: "检测中…")
        case .passed: return String(localized: "通过")
        case .failed: return String(localized: "失败")
        case .verificationRequired: return String(localized: "需验证")
        case .rateLimited: return String(localized: "被限流")
        case .unsupported: return String(localized: "不支持")
        }
    }
}

/// 单步检测结果。
struct CheckResult: Sendable {
    let status: CheckStatus
    let durationMilliseconds: Int
    let message: String?
}

/// 建议操作。
enum HealthAction: String, Sendable {
    case none
    case enable
    case disable
    case verify
    case retry
    case updateRules

    var displayName: String {
        switch self {
        case .none: return String(localized: "无需操作")
        case .enable: return String(localized: "建议启用")
        case .disable: return String(localized: "建议停用")
        case .verify: return String(localized: "需要人机验证")
        case .retry: return String(localized: "建议重试")
        case .updateRules: return String(localized: "建议更新规则")
        }
    }
}

/// 完整健康检测报告。
struct BookSourceHealthReport: Sendable {
    let sourceID: UUID
    let checkedAt: Date
    let search: CheckResult
    let detail: CheckResult
    let catalog: CheckResult
    let content: CheckResult
    let totalDurationMilliseconds: Int
    let recommendedAction: HealthAction

    var isFullyHealthy: Bool {
        search.status == .passed
            && detail.status == .passed
            && catalog.status == .passed
            && content.status == .passed
    }

    static func recommendAction(
        search: CheckResult,
        detail: CheckResult,
        catalog: CheckResult,
        content: CheckResult
    ) -> HealthAction {
        // 任一步骤需要验证
        if search.status == .verificationRequired
            || detail.status == .verificationRequired
            || content.status == .verificationRequired {
            return .verify
        }
        // 搜索失败 → 建议停用
        if search.status == .failed {
            return .disable
        }
        // 搜索通过，但后续失败 → 建议更新规则
        if search.status == .passed
            && (detail.status == .failed || catalog.status == .failed || content.status == .failed) {
            return .updateRules
        }
        // 全部通过
        if search.status == .passed
            && detail.status == .passed
            && catalog.status == .passed
            && content.status == .passed {
            return .none
        }
        return .retry
    }
}
