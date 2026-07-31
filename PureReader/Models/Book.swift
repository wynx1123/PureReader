import Foundation
import SwiftData

@Model
final class Book {
    var id: UUID
    var title: String
    var author: String
    /// 封面图（建议 external storage）
    @Attribute(.externalStorage) var coverImageData: Data?
    var sourceTypeRaw: String
    var sourceName: String?
    var sourceURL: String?
    /// ID of the online source used for lazy chapter downloads.
    var bookSourceID: UUID? = nil
    /// App 沙盒内相对路径（Books/<uuid>/...）
    var filePath: String?
    var formatRaw: String
    var totalChapters: Int
    var currentChapterIndex: Int
    var currentPageOffset: Int
    var lastReadAt: Date?
    var addedAt: Date
    var totalReadingSeconds: Int
    /// nil 或空 = 默认分组
    var group: String?
    var tags: [String]
    /// 进度 0...1（章节进度近似）
    var readingProgress: Double

    // PureReader 1.1 online-library state. Defaults are required for lightweight
    // migration of libraries created by earlier releases.
    var updateTrackingEnabled: Bool = true
    var lastUpdateCheckedAt: Date? = nil
    var unreadChapterCount: Int = 0
    var firstUnreadChapterIndex: Int = -1
    var highestReadChapterIndex: Int = -1

    @Relationship(deleteRule: .cascade, inverse: \Chapter.book)
    var chapters: [Chapter]?

    @Relationship(deleteRule: .cascade, inverse: \ReadingRecord.book)
    var records: [ReadingRecord]?

    var sourceType: SourceType {
        get { SourceType(rawValue: sourceTypeRaw) ?? .local }
        set { sourceTypeRaw = newValue.rawValue }
    }

    var format: BookFormat {
        get { BookFormat(rawValue: formatRaw) ?? .txt }
        set { formatRaw = newValue.rawValue }
    }

    var groupDisplayName: String {
        BuiltInGroup.displayName(for: group)
    }

    var progressFraction: Double {
        if readingProgress > 0 { return min(1, max(0, readingProgress)) }
        guard totalChapters > 0 else { return 0 }
        return min(1, Double(currentChapterIndex + 1) / Double(totalChapters))
    }

    init(
        id: UUID = UUID(),
        title: String,
        author: String = "",
        coverImageData: Data? = nil,
        sourceType: SourceType = .local,
        sourceName: String? = nil,
        sourceURL: String? = nil,
        bookSourceID: UUID? = nil,
        filePath: String? = nil,
        format: BookFormat = .txt,
        totalChapters: Int = 0,
        currentChapterIndex: Int = 0,
        currentPageOffset: Int = 0,
        lastReadAt: Date? = nil,
        addedAt: Date = Date(),
        totalReadingSeconds: Int = 0,
        group: String? = nil,
        tags: [String] = [],
        readingProgress: Double = 0
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverImageData = coverImageData
        self.sourceTypeRaw = sourceType.rawValue
        self.sourceName = sourceName
        self.sourceURL = sourceURL
        self.bookSourceID = bookSourceID
        self.filePath = filePath
        self.formatRaw = format.rawValue
        self.totalChapters = totalChapters
        self.currentChapterIndex = currentChapterIndex
        self.currentPageOffset = currentPageOffset
        self.lastReadAt = lastReadAt
        self.addedAt = addedAt
        self.totalReadingSeconds = totalReadingSeconds
        self.group = group
        self.tags = tags
        self.readingProgress = readingProgress
    }
}

@Model
final class Chapter {
    var id: UUID
    var index: Int
    var title: String
    /// 正文可能很大，走外部存储
    @Attribute(.externalStorage) var content: String
    /// EPUB 正文图片的位置与原始数据。
    @Attribute(.externalStorage) var richContentData: Data?
    /// Original online chapter URL used for on-demand content loading.
    var sourceURL: String? = nil
    /// Relative path below Application Support/OfflineChapters. The complete
    /// body is deliberately kept outside SwiftData and loaded only when read.
    var offlineCachePath: String? = nil
    var offlineCachedAt: Date? = nil
    var book: Book?

    init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        content: String = "",
        richContentData: Data? = nil,
        sourceURL: String? = nil
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.content = content
        self.richContentData = richContentData
        self.sourceURL = sourceURL
    }
}

@Model
final class ReadingRecord {
    var id: UUID
    var date: Date
    var durationSeconds: Int
    var book: Book?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        durationSeconds: Int = 0
    ) {
        self.id = id
        self.date = date
        self.durationSeconds = durationSeconds
    }
}

@Model
final class ReadingSettings {
    var fontSize: Double
    var lineSpacing: Double
    var pageMarginRaw: String
    var backgroundColorRaw: String
    var pageTurnModeRaw: String
    var showHeader: Bool = true
    var showPageNumber: Bool = true
    var ttsRate: Double
    var ttsProviderRaw: String = TTSProvider.system.rawValue
    var ttsVoice: String

    // 以下字段均带默认值，SwiftData 才能对存量库做轻量迁移。
    /// 阅读时禁用自动锁屏。
    var keepScreenOn: Bool = false
    /// 应用内阅读亮度覆盖；<0 表示跟随系统、不接管。
    var brightnessOverride: Double = -1
    /// 段落首行缩进（字符数，按当前字号换算）。
    var firstLineIndentChars: Double = 2
    /// 段间距（相对字号的倍数）。
    var paragraphSpacingRatio: Double = 0.35
    /// 听书睡眠定时：分钟数；0 = 关闭。
    var sleepTimerMinutes: Int = 0
    /// 听书睡眠定时：读完本章即停。
    var sleepAfterChapter: Bool = false

    var pageMargin: MarginMode {
        get { MarginMode(rawValue: pageMarginRaw) ?? .normal }
        set { pageMarginRaw = newValue.rawValue }
    }

    var backgroundColor: BackgroundType {
        get { BackgroundType(rawValue: backgroundColorRaw) ?? .cream }
        set { backgroundColorRaw = newValue.rawValue }
    }

    var pageTurnMode: PageTurnMode {
        get { PageTurnMode(rawValue: pageTurnModeRaw) ?? .scroll }
        set { pageTurnModeRaw = newValue.rawValue }
    }

    var ttsProvider: TTSProvider {
        get { TTSProvider(rawValue: ttsProviderRaw) ?? .system }
        set { ttsProviderRaw = newValue.rawValue }
    }

    init(
        fontSize: Double = 18,
        lineSpacing: Double = 1.6,
        pageMargin: MarginMode = .normal,
        backgroundColor: BackgroundType = .cream,
        pageTurnMode: PageTurnMode = .scroll,
        showHeader: Bool = true,
        showPageNumber: Bool = true,
        ttsRate: Double = 0.5,
        ttsProvider: TTSProvider = .system,
        ttsVoice: String = "",
        keepScreenOn: Bool = false,
        brightnessOverride: Double = -1,
        firstLineIndentChars: Double = 2,
        paragraphSpacingRatio: Double = 0.35,
        sleepTimerMinutes: Int = 0,
        sleepAfterChapter: Bool = false
    ) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.pageMarginRaw = pageMargin.rawValue
        self.backgroundColorRaw = backgroundColor.rawValue
        self.pageTurnModeRaw = pageTurnMode.rawValue
        self.showHeader = showHeader
        self.showPageNumber = showPageNumber
        self.ttsRate = ttsRate
        self.ttsProviderRaw = ttsProvider.rawValue
        self.ttsVoice = ttsVoice
        self.keepScreenOn = keepScreenOn
        self.brightnessOverride = brightnessOverride
        self.firstLineIndentChars = firstLineIndentChars
        self.paragraphSpacingRatio = paragraphSpacingRatio
        self.sleepTimerMinutes = sleepTimerMinutes
        self.sleepAfterChapter = sleepAfterChapter
    }
}

/// 书签与划线。
///
/// 用章内 UTF-16 偏移定位，与 `Book.currentPageOffset`、`ReaderPage.location`
/// 同一套坐标系，可直接经 `TextPaginator.pageIndex(forCharacterOffset:in:)` 换算成页。
@Model
final class Bookmark {
    var id: UUID
    var bookID: UUID
    var chapterID: UUID
    var chapterIndex: Int
    var chapterTitle: String
    /// 章内 UTF-16 起始偏移。
    var utf16Location: Int
    /// 选区长度；0 表示这是一个位置书签而非划线。
    var utf16Length: Int
    /// 摘录的原文，用于列表展示与原文漂移后的重定位。
    var excerpt: String
    /// 用户笔记，可空。
    var note: String = ""
    /// 划线颜色标识；位置书签忽略此字段。
    var colorRaw: String = HighlightColor.yellow.rawValue
    var createdAt: Date

    var isHighlight: Bool { utf16Length > 0 }

    var color: HighlightColor {
        get { HighlightColor(rawValue: colorRaw) ?? .yellow }
        set { colorRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        chapterIndex: Int,
        chapterTitle: String,
        utf16Location: Int,
        utf16Length: Int = 0,
        excerpt: String = "",
        note: String = "",
        color: HighlightColor = .yellow,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
        self.excerpt = excerpt
        self.note = note
        self.colorRaw = color.rawValue
        self.createdAt = createdAt
    }
}

/// 用户自定义分组列表（单例行）
@Model
final class ShelfPreferences {
    var id: UUID
    var customGroups: [String]
    /// 已知标签全集（便于筛选）
    var knownTags: [String]

    init(
        id: UUID = UUID(),
        customGroups: [String] = [],
        knownTags: [String] = []
    ) {
        self.id = id
        self.customGroups = customGroups
        self.knownTags = knownTags
    }
}
