import Foundation

enum SourceType: String, Codable, CaseIterable, Sendable {
    case local
    case url
    case booksource
}

enum BookFormat: String, Codable, CaseIterable, Sendable {
    case txt
    case epub
    case online
}

enum MarginMode: String, Codable, CaseIterable, Sendable {
    case compact
    case normal
    case wide

    var displayName: String {
        switch self {
        case .compact: return String(localized: "紧凑")
        case .normal: return String(localized: "适中")
        case .wide: return String(localized: "宽松")
        }
    }

    var edgeInset: CGFloat {
        switch self {
        case .compact: return 12
        case .normal: return 20
        case .wide: return 32
        }
    }
}

enum BackgroundType: String, Codable, CaseIterable, Sendable {
    case white
    case cream
    case green
    case dark
    case paperTexture
    case parchment

    var displayName: String {
        switch self {
        case .white: return String(localized: "纯白")
        case .cream: return String(localized: "米黄")
        case .green: return String(localized: "护眼绿")
        case .dark: return String(localized: "夜间")
        case .paperTexture: return String(localized: "纸张纹理")
        case .parchment: return String(localized: "羊皮纸")
        }
    }
}

enum PageTurnMode: String, Codable, CaseIterable, Sendable {
    case scroll
    case pageCurl
    case verticalScroll

    var displayName: String {
        switch self {
        case .scroll: return String(localized: "左右滑动")
        case .pageCurl: return String(localized: "仿真翻页")
        case .verticalScroll: return String(localized: "上下滚动")
        }
    }
}

/// 书架排序
enum BookshelfSort: String, CaseIterable, Identifiable, Sendable {
    case lastRead
    case recentlyAdded
    case title
    case author

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastRead: return String(localized: "最近阅读")
        case .recentlyAdded: return String(localized: "最近添加")
        case .title: return String(localized: "书名")
        case .author: return String(localized: "作者")
        }
    }
}

/// 书架布局
enum BookshelfLayout: String, CaseIterable, Identifiable, Sendable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return String(localized: "网格")
        case .list: return String(localized: "列表")
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

/// 内置分组名（`group == nil` 视为默认）
enum BuiltInGroup {
    static let `default` = String(localized: "默认")
    static let reading = String(localized: "正在读")
    static let finished = String(localized: "已读完")

    static var all: [String] { [`default`, reading, finished] }

    static func displayName(for stored: String?) -> String {
        if let stored, !stored.isEmpty { return stored }
        return `default`
    }
}

enum ImportError: LocalizedError, Sendable {
    case unsupportedFormat
    case emptyFile
    case unreadableEncoding
    case unreadableFile(String)
    case accessDenied(String)
    case epubInvalid
    case downloadFailed(String)
    case invalidURL
    case saveFailed(String)
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return String(localized: "仅支持 TXT / EPUB 文件")
        case .emptyFile:
            return String(localized: "文件内容为空或未识别到章节")
        case .unreadableEncoding:
            return String(localized: "无法识别文本编码（请尝试 UTF-8 / GBK）")
        case .unreadableFile(let msg):
            return String(localized: "无法读取文件：\(msg)")
        case .accessDenied(let msg):
            return String(localized: "无法访问所选文件：\(msg)")
        case .epubInvalid:
            return String(localized: "EPUB 文件损坏或格式不正确")
        case .downloadFailed(let msg):
            return String(localized: "下载失败：\(msg)")
        case .invalidURL:
            return String(localized: "请输入有效的 HTTPS 直链")
        case .saveFailed(let msg):
            return String(localized: "保存失败：\(msg)")
        case .fileTooLarge:
            return String(localized: "文件过大（上限 50 MB）")
        }
    }
}

/// 解析出的章节（导入阶段 DTO，非 SwiftData）
struct ParsedChapter: Sendable, Equatable {
    var index: Int
    var title: String
    var content: String
}

struct ParsedBook: Sendable {
    var title: String
    var author: String
    var format: BookFormat
    var chapters: [ParsedChapter]
    var coverImageData: Data?
}
