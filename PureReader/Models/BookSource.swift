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
    var bookURL: String
    var tocURL: String
    var contentURL: String
    /// JSON 序列化的 ParseRule
    var ruleJSON: String
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
        bookURL: String = "",
        tocURL: String = "",
        contentURL: String = "",
        rules: ParseRule = .empty,
        enabled: Bool = true,
        format: BookSourceFormat = .pureReader,
        comment: String = "",
        weight: Int = 0
    ) {
        self.id = id
        self.name = name
        self.groupName = groupName
        self.searchURL = searchURL
        self.bookURL = bookURL
        self.tocURL = tocURL
        self.contentURL = contentURL
        if let data = try? JSONEncoder().encode(rules),
           let s = String(data: data, encoding: .utf8) {
            self.ruleJSON = s
        } else {
            self.ruleJSON = "{}"
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
