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

enum TTSProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case openAICompatible
    case xiaomiMiMo
    case fishAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "系统语音")
        case .openAICompatible: return String(localized: "OpenAI 兼容")
        case .xiaomiMiMo: return String(localized: "小米 MiMo")
        case .fishAudio: return "Fish Audio"
        }
    }

    var defaultVoice: String {
        switch self {
        case .system: return ""
        case .openAICompatible: return "marin"
        case .xiaomiMiMo: return "mimo_default"
        case .fishAudio: return ""
        }
    }
}

/// 划线颜色
enum HighlightColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow
    case green
    case blue
    case pink

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .yellow: return String(localized: "黄")
        case .green: return String(localized: "绿")
        case .blue: return String(localized: "蓝")
        case .pink: return String(localized: "粉")
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

/// 内置分组（`group == nil` 视为默认）。
///
/// 持久化的是稳定 key 而非本地化字符串。此前直接存 `String(localized:)` 的结果，
/// 用户切换系统语言后存量 `Book.group` 会与新的显示名对不上，书会从分组里「消失」。
enum BuiltInGroup {
    /// 存进 `Book.group` 的稳定标识。
    static let defaultKey = "__default"
    static let readingKey = "__reading"
    static let finishedKey = "__finished"

    static var allKeys: [String] { [defaultKey, readingKey, finishedKey] }

    /// 兼容旧版本：早期把本地化后的中文名直接存进了 group 字段。
    private static let legacyNames: [String: String] = [
        "默认": defaultKey,
        "正在读": readingKey,
        "已读完": finishedKey
    ]

    static func isBuiltIn(_ key: String?) -> Bool {
        guard let key else { return true }
        return key.isEmpty || allKeys.contains(key) || legacyNames.keys.contains(key)
    }

    /// 把存量值归一到稳定 key；自定义分组原样返回。
    static func normalize(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        if let mapped = legacyNames[stored] { return mapped == defaultKey ? nil : mapped }
        return stored == defaultKey ? nil : stored
    }

    static func displayName(for stored: String?) -> String {
        let key = normalize(stored)
        switch key {
        case .none: return String(localized: "默认")
        case .some(readingKey): return String(localized: "正在读")
        case .some(finishedKey): return String(localized: "已读完")
        case .some(let custom): return custom
        }
    }

    // 兼容旧调用方。
    static var `default`: String { defaultKey }
    static var all: [String] { allKeys }
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
    var richContentData: Data? = nil
}

struct ChapterInlineImage: Codable, Sendable, Equatable {
    var utf16Location: Int
    var data: Data
    var altText: String
}

struct ChapterRichContent: Codable, Sendable, Equatable {
    static let imagePlaceholder = "\u{FFFC}"

    var images: [ChapterInlineImage]

    static func decode(_ data: Data?) -> ChapterRichContent? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(ChapterRichContent.self, from: data)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    func adjustingForReplacement(
        range: NSRange,
        replacementUTF16Length: Int
    ) -> ChapterRichContent {
        let delta = replacementUTF16Length - range.length
        let replacedEnd = NSMaxRange(range)
        let adjusted = images.compactMap { image -> ChapterInlineImage? in
            if image.utf16Location < range.location { return image }
            if image.utf16Location < replacedEnd { return nil }
            var shifted = image
            shifted.utf16Location += delta
            return shifted
        }
        return ChapterRichContent(images: adjusted)
    }

    func containsImage(in range: NSRange) -> Bool {
        let end = NSMaxRange(range)
        return images.contains { image in
            image.utf16Location < end
                && image.utf16Location + 1 > range.location
        }
    }
}

struct ParsedBook: Sendable {
    var title: String
    var author: String
    var format: BookFormat
    var chapters: [ParsedChapter]
    var coverImageData: Data?
}
