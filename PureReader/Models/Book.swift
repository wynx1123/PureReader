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
    var book: Book?

    init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        content: String = ""
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.content = content
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
    var ttsRate: Double
    var ttsVoice: String

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

    init(
        fontSize: Double = 18,
        lineSpacing: Double = 1.6,
        pageMargin: MarginMode = .normal,
        backgroundColor: BackgroundType = .cream,
        pageTurnMode: PageTurnMode = .scroll,
        ttsRate: Double = 0.5,
        ttsVoice: String = ""
    ) {
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.pageMarginRaw = pageMargin.rawValue
        self.backgroundColorRaw = backgroundColor.rawValue
        self.pageTurnModeRaw = pageTurnMode.rawValue
        self.ttsRate = ttsRate
        self.ttsVoice = ttsVoice
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
