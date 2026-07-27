import Foundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - 归档结构（纯值类型）

/// 备份文件顶层结构。
///
/// 全部字段都是值类型且 `Sendable`：主 actor 只负责把 SwiftData 模型读成这些 struct，
/// 真正耗时的 JSON 编解码交给后台线程，避免把非 Sendable 的 `ModelContext` 跨线程传递。
///
/// 新增字段请一律用 Optional 或在 `init(from:)` 里给默认值，
/// 否则旧版本备份文件会在新版本上解码失败。
struct BackupArchive: Codable, Sendable {
    /// 当前写出的结构版本。读取时允许 <= 此值。
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var createdAt: Date
    /// 生成备份的 App 版本，仅供排查问题时参考。
    var appVersion: String
    var books: [BackupBook]
    var bookSources: [BackupBookSource]
    var rewriteRecords: [BackupRewriteRecord]
    var bookmarks: [BackupBookmark]
    var shelfPreferences: BackupShelfPreferences?
    var readingSettings: BackupReadingSettings?

    var chapterCount: Int { books.reduce(0) { $0 + $1.chapters.count } }
    var readingRecordCount: Int { books.reduce(0) { $0 + $1.records.count } }

    // 手写 init(from:) 时显式声明键名，不依赖「Encodable 合成顺带把 CodingKeys 带出来」。
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case createdAt
        case appVersion
        case books
        case bookSources
        case rewriteRecords
        case bookmarks
        case shelfPreferences
        case readingSettings
    }

    init(
        schemaVersion: Int = BackupArchive.currentSchemaVersion,
        createdAt: Date = Date(),
        appVersion: String,
        books: [BackupBook],
        bookSources: [BackupBookSource],
        rewriteRecords: [BackupRewriteRecord],
        bookmarks: [BackupBookmark],
        shelfPreferences: BackupShelfPreferences?,
        readingSettings: BackupReadingSettings?
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.books = books
        self.bookSources = bookSources
        self.rewriteRecords = rewriteRecords
        self.bookmarks = bookmarks
        self.shelfPreferences = shelfPreferences
        self.readingSettings = readingSettings
    }

    // 手写解码：任何一节缺失都退化成空集合，而不是整份备份读不出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        books = try c.decodeIfPresent([BackupBook].self, forKey: .books) ?? []
        bookSources = try c.decodeIfPresent([BackupBookSource].self, forKey: .bookSources) ?? []
        rewriteRecords = try c.decodeIfPresent([BackupRewriteRecord].self, forKey: .rewriteRecords) ?? []
        bookmarks = try c.decodeIfPresent([BackupBookmark].self, forKey: .bookmarks) ?? []
        shelfPreferences = try c.decodeIfPresent(BackupShelfPreferences.self, forKey: .shelfPreferences)
        readingSettings = try c.decodeIfPresent(BackupReadingSettings.self, forKey: .readingSettings)
    }
}

struct BackupBook: Codable, Sendable {
    var id: UUID
    var title: String
    var author: String
    /// 封面二进制；`BackupOptions.includeCovers` 关闭时为 nil。
    var coverImageData: Data?
    /// 存 raw 值而不是枚举，未知取值也能原样带回来。
    var sourceTypeRaw: String
    var sourceName: String?
    var sourceURL: String?
    var filePath: String?
    var formatRaw: String
    var totalChapters: Int
    var currentChapterIndex: Int
    var currentPageOffset: Int
    var lastReadAt: Date?
    var addedAt: Date
    var totalReadingSeconds: Int
    var group: String?
    var tags: [String]
    var readingProgress: Double
    var chapters: [BackupChapter]
    var records: [BackupReadingRecord]
}

struct BackupChapter: Codable, Sendable {
    var id: UUID
    var index: Int
    var title: String
    /// 正文是备份体积的大头。
    var content: String
    /// EPUB 内嵌图片，Base64 存储。
    var richContentData: Data?
}

struct BackupReadingRecord: Codable, Sendable {
    var id: UUID
    var date: Date
    var durationSeconds: Int
}

struct BackupShelfPreferences: Codable, Sendable {
    var id: UUID
    var customGroups: [String]
    var knownTags: [String]
}

struct BackupRewriteRecord: Codable, Sendable {
    var id: UUID
    var bookID: UUID
    var chapterID: UUID
    var originalText: String
    var rewrittenText: String
    var userRequest: String
    var stylePresetRaw: String
    var timestamp: Date
    var originalUTF16Offset: Int
    var isUndone: Bool
    var isFavorite: Bool
    var branchLabel: String
}

struct BackupBookmark: Codable, Sendable {
    var id: UUID
    var bookID: UUID
    var chapterID: UUID
    var chapterIndex: Int
    var chapterTitle: String
    var utf16Location: Int
    var utf16Length: Int
    var excerpt: String
    var note: String
    var colorRaw: String
    var createdAt: Date
}

/// 书源。与 `BookSourceImporter.exportJSON` 的社区互通格式不同，
/// 这里是「原样往返」用的内部格式，连 `isValid` / `lastCheckedAt` 都一起带走。
struct BackupBookSource: Codable, Sendable {
    var id: UUID
    var name: String
    var groupName: String
    var searchURL: String
    var bookURL: String
    var tocURL: String
    var contentURL: String
    var headerJSON: String
    var ruleJSON: String
    var enabled: Bool
    var formatRaw: String
    var bookCount: Int
    var lastCheckedAt: Date?
    var isValid: Bool
    var comment: String
    var weight: Int
    var createdAt: Date
}

/// 阅读排版与听书偏好（单例行）。密钥类配置在 Keychain，不在此列。
struct BackupReadingSettings: Codable, Sendable {
    var fontSize: Double
    var lineSpacing: Double
    var pageMarginRaw: String
    var backgroundColorRaw: String
    var pageTurnModeRaw: String
    var showHeader: Bool
    var showPageNumber: Bool
    var ttsRate: Double
    var ttsProviderRaw: String
    var ttsVoice: String
    var keepScreenOn: Bool
    var brightnessOverride: Double
    var firstLineIndentChars: Double
    var paragraphSpacingRatio: Double
    var sleepTimerMinutes: Int
    var sleepAfterChapter: Bool
}

// MARK: - 选项与结果

struct BackupOptions: Sendable {
    /// 封面图往往占整份备份一半以上体积，允许用户关掉。
    var includeCovers: Bool = true

    init(includeCovers: Bool = true) {
        self.includeCovers = includeCovers
    }
}

enum RestoreStrategy: String, CaseIterable, Identifiable, Sendable {
    /// 按 id 去重，已存在的条目原样保留。
    case merge
    /// 清空现有全部数据后导入。
    case replace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .merge: return String(localized: "合并到当前书库")
        case .replace: return String(localized: "清空后完全覆盖")
        }
    }

    var detail: String {
        switch self {
        case .merge:
            return String(localized: "只补齐书库里没有的条目，已存在的书籍与进度不会被改动。")
        case .replace:
            return String(localized: "先删除当前全部书籍、进度、书签与书源，再写入备份内容。不可撤销。")
        }
    }
}

/// 备份产物。
struct BackupFile: Sendable {
    var url: URL
    var byteCount: Int
    var bookCount: Int
    var chapterCount: Int

    var message: String {
        String(localized: "已生成备份：\(bookCount) 本书、\(chapterCount) 章，\(BackupService.formatBytes(byteCount))")
    }
}

struct RestoreResult: Sendable {
    var insertedBooks = 0
    var skippedBooks = 0
    var insertedChapters = 0
    var insertedRecords = 0
    var insertedBookmarks = 0
    var insertedRewrites = 0
    var insertedSources = 0
    var deletedBooks = 0

    var message: String {
        var parts: [String] = [
            String(localized: "恢复完成：新增 \(insertedBooks) 本书、\(insertedChapters) 章")
        ]
        if insertedRecords > 0 {
            parts.append(String(localized: "阅读记录 \(insertedRecords) 条"))
        }
        if insertedBookmarks > 0 {
            parts.append(String(localized: "书签 \(insertedBookmarks) 条"))
        }
        if insertedRewrites > 0 {
            parts.append(String(localized: "改写记录 \(insertedRewrites) 条"))
        }
        if insertedSources > 0 {
            parts.append(String(localized: "书源 \(insertedSources) 个"))
        }
        if skippedBooks > 0 {
            parts.append(String(localized: "另有 \(skippedBooks) 本已存在已跳过"))
        }
        if deletedBooks > 0 {
            parts.append(String(localized: "已清除原有 \(deletedBooks) 本书"))
        }
        return parts.joined(separator: "，")
    }
}

/// 书库概况，用于在备份前告诉用户「这次要打包多少东西」。
struct LibraryOverview: Sendable {
    var bookCount = 0
    var chapterCount = 0
    var readingRecordCount = 0
    var bookmarkCount = 0
    var rewriteCount = 0
    var sourceCount = 0
    var totalReadingSeconds = 0
    /// 抽样估算的备份体积，只是量级参考。
    var estimatedBytes = 0

    var isEmpty: Bool {
        bookCount == 0 && sourceCount == 0 && bookmarkCount == 0 && rewriteCount == 0
    }
}

/// 进度回调载荷。
struct BackupProgress: Sendable {
    enum Stage: Sendable {
        case reading
        case encoding
        case decoding
        case applying
        case saving

        var text: String {
            switch self {
            case .reading: return String(localized: "正在读取书库…")
            case .encoding: return String(localized: "正在生成备份文件…")
            case .decoding: return String(localized: "正在解析备份文件…")
            case .applying: return String(localized: "正在写入书库…")
            case .saving: return String(localized: "正在保存…")
            }
        }
    }

    var stage: Stage
    var completed: Int = 0
    var total: Int = 0

    /// 总数未知时返回 nil，交给 UI 显示不确定进度。
    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

// MARK: - 服务

/// 整库备份与恢复。
///
/// 设计要点：
/// 1. `ModelContext` 不是 `Sendable`，所有 SwiftData 读写都留在主 actor；
///    主 actor 把模型读成上面那批 DTO 之后，JSON 编解码与文件 IO 才交给 `Task.detached`。
/// 2. 备份文件是单个 JSON，后缀 `.purereaderbackup`，顶层带 `schemaVersion` 与 `createdAt`。
///    仓库里的 `ZIPUtility` 只有解压没有压缩侧，所以不打 zip 包。
/// 3. 恢复全程只 `save()` 一次；中途任意一步抛错立即 `rollback()`，
///    不会留下一个「导了一半」的书库。
/// 4. AI 接口密钥存在 Keychain，备份完全不触碰；向量索引与记忆锚点是可再生的
///    派生数据，也不进备份。
enum BackupService {
    /// 备份文件后缀。
    static let fileExtension = "purereaderbackup"
    /// 恢复时允许读取的最大文件体积。整库 JSON 会比原库大（Base64 膨胀 4/3），留足余量。
    static let maxRestoreBytes = 300 * 1024 * 1024

    // MARK: - 概况

    @MainActor
    static func overview(context: ModelContext, options: BackupOptions = BackupOptions()) -> LibraryOverview {
        var overview = LibraryOverview()
        overview.bookCount = (try? context.fetchCount(FetchDescriptor<Book>())) ?? 0
        overview.chapterCount = (try? context.fetchCount(FetchDescriptor<Chapter>())) ?? 0
        overview.readingRecordCount = (try? context.fetchCount(FetchDescriptor<ReadingRecord>())) ?? 0
        overview.bookmarkCount = (try? context.fetchCount(FetchDescriptor<Bookmark>())) ?? 0
        overview.rewriteCount = (try? context.fetchCount(FetchDescriptor<RewriteRecord>())) ?? 0
        overview.sourceCount = (try? context.fetchCount(FetchDescriptor<BookSource>())) ?? 0
        overview.totalReadingSeconds = totalReadingSeconds(context: context)
        overview.estimatedBytes = estimatedBackupBytes(
            bookCount: overview.bookCount,
            chapterCount: overview.chapterCount,
            includeCovers: options.includeCovers,
            context: context
        )
        return overview
    }

    /// 只取 `totalReadingSeconds` 一列，用不着连正文一起读。
    @MainActor
    private static func totalReadingSeconds(context: ModelContext) -> Int {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        return books.reduce(0) { $0 + $1.totalReadingSeconds }
    }

    /// 抽样估算体积。
    ///
    /// 全量统计要把每一章正文都从 external storage 里读出来，几百本书就是几百 MB 的
    /// 无谓 IO —— 只是给用户一个量级参考，抽几段算平均即可。
    @MainActor
    private static func estimatedBackupBytes(
        bookCount: Int,
        chapterCount: Int,
        includeCovers: Bool,
        context: ModelContext
    ) -> Int {
        guard bookCount > 0 || chapterCount > 0 else { return 0 }

        var sampledChapters = 0
        var sampledChapterBytes = 0
        if chapterCount > 0 {
            for offset in sampleOffsets(total: chapterCount, windows: 3, span: 4) {
                var descriptor = FetchDescriptor<Chapter>(sortBy: [SortDescriptor(\Chapter.index)])
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = 4
                guard let rows = try? context.fetch(descriptor) else { continue }
                for chapter in rows {
                    sampledChapterBytes += chapter.content.utf8.count
                        + chapter.title.utf8.count
                        + base64Size(chapter.richContentData?.count ?? 0)
                    sampledChapters += 1
                }
            }
        }
        let perChapter = sampledChapters > 0 ? sampledChapterBytes / sampledChapters : 0

        var sampledBooks = 0
        var sampledCoverBytes = 0
        if includeCovers && bookCount > 0 {
            var descriptor = FetchDescriptor<Book>(sortBy: [SortDescriptor(\Book.addedAt, order: .reverse)])
            descriptor.fetchLimit = 6
            for book in (try? context.fetch(descriptor)) ?? [] {
                sampledCoverBytes += base64Size(book.coverImageData?.count ?? 0)
                sampledBooks += 1
            }
        }
        let perCover = sampledBooks > 0 ? sampledCoverBytes / sampledBooks : 0

        // 每章 ~120 字节 JSON 键名与括号，每本书 ~400 字节元数据。
        let raw = perChapter * chapterCount
            + 120 * chapterCount
            + perCover * bookCount
            + 400 * bookCount
        return raw
    }

    /// 在 [0, total) 上取若干个等距窗口起点。
    private static func sampleOffsets(total: Int, windows: Int, span: Int) -> [Int] {
        guard total > 0, windows > 0 else { return [] }
        if total <= span * windows { return [0] }
        return (0..<windows).map { index in
            max(0, min(total - span, total * index / windows))
        }
    }

    private static func base64Size(_ byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        return (byteCount + 2) / 3 * 4
    }

    static func formatBytes(_ byteCount: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(max(0, byteCount)))
    }

    // MARK: - 备份

    /// 生成备份文件并返回临时目录中的 URL（可直接丢给 ShareSheet）。
    @MainActor
    static func exportBackup(
        context: ModelContext,
        options: BackupOptions = BackupOptions(),
        progress: (BackupProgress) -> Void = { _ in }
    ) async throws -> BackupFile {
        let archive = try await makeSnapshot(context: context, options: options, progress: progress)
        guard !archive.books.isEmpty
            || !archive.bookSources.isEmpty
            || !archive.bookmarks.isEmpty
            || !archive.rewriteRecords.isEmpty else {
            throw BackupError.emptyLibrary
        }

        progress(BackupProgress(stage: .encoding))
        let url = try prepareExportURL()
        let bookCount = archive.books.count
        let chapterCount = archive.chapterCount

        // 编码 + 落盘一起放后台：几十 MB 的 Data 不必在 actor 之间搬来搬去。
        let byteCount: Int
        do {
            byteCount = try await Task.detached(priority: .userInitiated) { () -> Int in
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.withoutEscapingSlashes]
                let data = try encoder.encode(archive)
                try data.write(to: url, options: .atomic)
                return data.count
            }.value
        } catch {
            throw BackupError.writeFailed(error.localizedDescription)
        }

        return BackupFile(
            url: url,
            byteCount: byteCount,
            bookCount: bookCount,
            chapterCount: chapterCount
        )
    }

    /// 把整库读成纯值类型。必须在主 actor 上跑（ModelContext 非 Sendable）。
    @MainActor
    static func makeSnapshot(
        context: ModelContext,
        options: BackupOptions = BackupOptions(),
        progress: (BackupProgress) -> Void = { _ in }
    ) async throws -> BackupArchive {
        let books = (try? context.fetch(
            FetchDescriptor<Book>(sortBy: [SortDescriptor(\Book.addedAt)])
        )) ?? []

        progress(BackupProgress(stage: .reading, completed: 0, total: books.count))

        var backupBooks: [BackupBook] = []
        backupBooks.reserveCapacity(books.count)
        for (offset, book) in books.enumerated() {
            backupBooks.append(snapshot(book, options: options))
            progress(BackupProgress(stage: .reading, completed: offset + 1, total: books.count))
            // 让出主线程，几百本书时 UI 才不会整段卡住。
            if offset % 5 == 4 { await Task.yield() }
        }

        let sources = (try? context.fetch(FetchDescriptor<BookSource>())) ?? []
        let rewrites = (try? context.fetch(FetchDescriptor<RewriteRecord>())) ?? []
        let bookmarks = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        let prefs = (try? context.fetch(FetchDescriptor<ShelfPreferences>()))?.first
        let settings = (try? context.fetch(FetchDescriptor<ReadingSettings>()))?.first

        return BackupArchive(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            books: backupBooks,
            bookSources: sources.map(snapshot),
            rewriteRecords: rewrites.map(snapshot),
            bookmarks: bookmarks.map(snapshot),
            shelfPreferences: prefs.map(snapshot),
            readingSettings: settings.map(snapshot)
        )
    }

    @MainActor
    private static func snapshot(_ book: Book, options: BackupOptions) -> BackupBook {
        let chapters = (book.chapters ?? [])
            .sorted { $0.index < $1.index }
            .map { chapter in
                BackupChapter(
                    id: chapter.id,
                    index: chapter.index,
                    title: chapter.title,
                    content: chapter.content,
                    richContentData: chapter.richContentData
                )
            }
        let records = (book.records ?? []).map { record in
            BackupReadingRecord(
                id: record.id,
                date: record.date,
                durationSeconds: record.durationSeconds
            )
        }
        return BackupBook(
            id: book.id,
            title: book.title,
            author: book.author,
            coverImageData: options.includeCovers ? book.coverImageData : nil,
            sourceTypeRaw: book.sourceTypeRaw,
            sourceName: book.sourceName,
            sourceURL: book.sourceURL,
            filePath: book.filePath,
            formatRaw: book.formatRaw,
            totalChapters: book.totalChapters,
            currentChapterIndex: book.currentChapterIndex,
            currentPageOffset: book.currentPageOffset,
            lastReadAt: book.lastReadAt,
            addedAt: book.addedAt,
            totalReadingSeconds: book.totalReadingSeconds,
            group: book.group,
            tags: book.tags,
            readingProgress: book.readingProgress,
            chapters: chapters,
            records: records
        )
    }

    @MainActor
    private static func snapshot(_ source: BookSource) -> BackupBookSource {
        BackupBookSource(
            id: source.id,
            name: source.name,
            groupName: source.groupName,
            searchURL: source.searchURL,
            bookURL: source.bookURL,
            tocURL: source.tocURL,
            contentURL: source.contentURL,
            headerJSON: source.headerJSON,
            ruleJSON: source.ruleJSON,
            enabled: source.enabled,
            formatRaw: source.formatRaw,
            bookCount: source.bookCount,
            lastCheckedAt: source.lastCheckedAt,
            isValid: source.isValid,
            comment: source.comment,
            weight: source.weight,
            createdAt: source.createdAt
        )
    }

    @MainActor
    private static func snapshot(_ record: RewriteRecord) -> BackupRewriteRecord {
        BackupRewriteRecord(
            id: record.id,
            bookID: record.bookID,
            chapterID: record.chapterID,
            originalText: record.originalText,
            rewrittenText: record.rewrittenText,
            userRequest: record.userRequest,
            stylePresetRaw: record.stylePresetRaw,
            timestamp: record.timestamp,
            originalUTF16Offset: record.originalUTF16Offset,
            isUndone: record.isUndone,
            isFavorite: record.isFavorite,
            branchLabel: record.branchLabel
        )
    }

    @MainActor
    private static func snapshot(_ mark: Bookmark) -> BackupBookmark {
        BackupBookmark(
            id: mark.id,
            bookID: mark.bookID,
            chapterID: mark.chapterID,
            chapterIndex: mark.chapterIndex,
            chapterTitle: mark.chapterTitle,
            utf16Location: mark.utf16Location,
            utf16Length: mark.utf16Length,
            excerpt: mark.excerpt,
            note: mark.note,
            colorRaw: mark.colorRaw,
            createdAt: mark.createdAt
        )
    }

    @MainActor
    private static func snapshot(_ prefs: ShelfPreferences) -> BackupShelfPreferences {
        BackupShelfPreferences(
            id: prefs.id,
            customGroups: prefs.customGroups,
            knownTags: prefs.knownTags
        )
    }

    @MainActor
    private static func snapshot(_ settings: ReadingSettings) -> BackupReadingSettings {
        BackupReadingSettings(
            fontSize: settings.fontSize,
            lineSpacing: settings.lineSpacing,
            pageMarginRaw: settings.pageMarginRaw,
            backgroundColorRaw: settings.backgroundColorRaw,
            pageTurnModeRaw: settings.pageTurnModeRaw,
            showHeader: settings.showHeader,
            showPageNumber: settings.showPageNumber,
            ttsRate: settings.ttsRate,
            ttsProviderRaw: settings.ttsProviderRaw,
            ttsVoice: settings.ttsVoice,
            keepScreenOn: settings.keepScreenOn,
            brightnessOverride: settings.brightnessOverride,
            firstLineIndentChars: settings.firstLineIndentChars,
            paragraphSpacingRatio: settings.paragraphSpacingRatio,
            sleepTimerMinutes: settings.sleepTimerMinutes,
            sleepAfterChapter: settings.sleepAfterChapter
        )
    }

    // MARK: - 读取备份文件

    /// 后台读取 + 解码备份文件。会自行申请与释放安全作用域。
    static func loadArchive(from url: URL) async throws -> BackupArchive {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let limit = maxRestoreBytes
        let archive = try await Task.detached(priority: .userInitiated) { () -> BackupArchive in
            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw BackupError.unreadableFile(error.localizedDescription)
            }
            guard !data.isEmpty else { throw BackupError.invalidFormat }
            guard data.count <= limit else { throw BackupError.fileTooLarge }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                return try decoder.decode(BackupArchive.self, from: stripBOM(data))
            } catch let error as BackupError {
                throw error
            } catch {
                throw BackupError.invalidFormat
            }
        }.value

        guard archive.schemaVersion <= BackupArchive.currentSchemaVersion else {
            throw BackupError.unsupportedSchema(archive.schemaVersion)
        }
        return archive
    }

    private static func stripBOM(_ data: Data) -> Data {
        guard data.starts(with: [0xEF, 0xBB, 0xBF]) else { return data }
        return data.dropFirst(3)
    }

    // MARK: - 恢复

    /// 把归档写回 SwiftData。
    ///
    /// 整个过程只在最后 `save()` 一次；任何一步失败都 `rollback()`，
    /// 保证不会出现「导了一半」的书库。
    @MainActor
    @discardableResult
    static func restore(
        _ archive: BackupArchive,
        strategy: RestoreStrategy,
        into context: ModelContext,
        progress: (BackupProgress) -> Void = { _ in }
    ) async throws -> RestoreResult {
        guard archive.schemaVersion <= BackupArchive.currentSchemaVersion else {
            throw BackupError.unsupportedSchema(archive.schemaVersion)
        }

        var result = RestoreResult()
        // 先读出现有 id 集合，再执行清空 —— 顺序反了会拿到已删除对象。
        let existingBooks = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        let existingSources = (try? context.fetch(FetchDescriptor<BookSource>())) ?? []
        let existingMarks = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        let existingRewrites = (try? context.fetch(FetchDescriptor<RewriteRecord>())) ?? []
        let existingPrefs = (try? context.fetch(FetchDescriptor<ShelfPreferences>())) ?? []
        let existingSettings = (try? context.fetch(FetchDescriptor<ReadingSettings>())) ?? []

        var bookIDs = Set(existingBooks.map(\.id))
        var markIDs = Set(existingMarks.map(\.id))
        var rewriteIDs = Set(existingRewrites.map(\.id))
        // `BookSource.id` 带 @Attribute(.unique)，同一次事务里「删掉再插入同 id」
        // 会撞上唯一约束的 upsert 语义。改成按 id 就地更新，只删除备份里没有的行。
        var existingSourceByID: [UUID: BookSource] = [:]
        for source in existingSources where existingSourceByID[source.id] == nil {
            existingSourceByID[source.id] = source
        }
        let archiveSourceIDs = Set(archive.bookSources.map(\.id))
        // 覆盖模式下派生数据也要清；但要等 save() 成功后再删磁盘文件，
        // 否则中途 rollback 会白白毁掉还在用的向量索引。
        var purgedBookIDs: [UUID] = []

        let totalUnits = archive.books.count
            + archive.bookSources.count
            + archive.bookmarks.count
            + archive.rewriteRecords.count
        var done = 0
        progress(BackupProgress(stage: .applying, completed: 0, total: totalUnits))

        do {
            if strategy == .replace {
                for book in existingBooks {
                    purgedBookIDs.append(book.id)
                    context.delete(book)
                }
                result.deletedBooks = existingBooks.count
                // 备份里不再出现的书源整行删除；仍存在的留给下面按 id 覆盖更新。
                for source in existingSources where !archiveSourceIDs.contains(source.id) {
                    context.delete(source)
                    existingSourceByID[source.id] = nil
                }
                for mark in existingMarks { context.delete(mark) }
                for record in existingRewrites { context.delete(record) }
                if archive.shelfPreferences != nil {
                    for prefs in existingPrefs { context.delete(prefs) }
                }
                if archive.readingSettings != nil {
                    for settings in existingSettings { context.delete(settings) }
                }
                bookIDs = []
                markIDs = []
                rewriteIDs = []
            }

            for (offset, dto) in archive.books.enumerated() {
                done += 1
                guard !bookIDs.contains(dto.id) else {
                    result.skippedBooks += 1
                    progress(BackupProgress(stage: .applying, completed: done, total: totalUnits))
                    continue
                }
                bookIDs.insert(dto.id)
                let counts = insert(dto, into: context)
                result.insertedBooks += 1
                result.insertedChapters += counts.chapters
                result.insertedRecords += counts.records
                progress(BackupProgress(stage: .applying, completed: done, total: totalUnits))
                // 单本 500 章的插入不便宜，隔几本让出一次主线程刷新进度条。
                if offset % 3 == 2 { await Task.yield() }
            }

            for dto in archive.bookSources {
                done += 1
                if let current = existingSourceByID[dto.id] {
                    // 合并模式保留用户现有书源（可能已手动改过规则或开关）。
                    guard strategy == .replace else { continue }
                    overwrite(current, with: dto)
                } else {
                    let source = makeSource(dto)
                    context.insert(source)
                    existingSourceByID[dto.id] = source
                }
                result.insertedSources += 1
            }
            progress(BackupProgress(stage: .applying, completed: done, total: totalUnits))

            for dto in archive.bookmarks {
                done += 1
                guard !markIDs.contains(dto.id) else { continue }
                markIDs.insert(dto.id)
                context.insert(makeBookmark(dto))
                result.insertedBookmarks += 1
            }

            for dto in archive.rewriteRecords {
                done += 1
                guard !rewriteIDs.contains(dto.id) else { continue }
                rewriteIDs.insert(dto.id)
                context.insert(makeRewriteRecord(dto))
                result.insertedRewrites += 1
            }
            progress(BackupProgress(stage: .applying, completed: done, total: totalUnits))

            if let dto = archive.shelfPreferences {
                applyShelfPreferences(dto, strategy: strategy, existing: existingPrefs, context: context)
            }
            if let dto = archive.readingSettings {
                applyReadingSettings(dto, strategy: strategy, existing: existingSettings, context: context)
            }

            progress(BackupProgress(stage: .saving))
            try context.save()
        } catch {
            context.rollback()
            throw BackupError.restoreFailed(error.localizedDescription)
        }

        // 事务已落盘，此时清理被覆盖书籍的向量索引与记忆锚点才安全。
        for id in purgedBookIDs {
            BookUnderstandingCoordinator.shared.purge(bookID: id)
        }
        return result
    }

    @MainActor
    private static func insert(
        _ dto: BackupBook,
        into context: ModelContext
    ) -> (chapters: Int, records: Int) {
        let book = Book(
            id: dto.id,
            title: dto.title.isEmpty ? String(localized: "未命名") : dto.title,
            author: dto.author,
            coverImageData: dto.coverImageData,
            sourceType: SourceType(rawValue: dto.sourceTypeRaw) ?? .local,
            sourceName: dto.sourceName,
            sourceURL: dto.sourceURL,
            filePath: dto.filePath,
            format: BookFormat(rawValue: dto.formatRaw) ?? .txt,
            totalChapters: dto.totalChapters,
            currentChapterIndex: dto.currentChapterIndex,
            currentPageOffset: dto.currentPageOffset,
            lastReadAt: dto.lastReadAt,
            addedAt: dto.addedAt,
            totalReadingSeconds: dto.totalReadingSeconds,
            group: BuiltInGroup.normalize(dto.group),
            tags: dto.tags,
            readingProgress: dto.readingProgress
        )
        context.insert(book)

        var chapters: [Chapter] = []
        chapters.reserveCapacity(dto.chapters.count)
        for source in dto.chapters.sorted(by: { $0.index < $1.index }) {
            let chapter = Chapter(
                id: source.id,
                index: source.index,
                title: source.title,
                // 与 BookImportService.save 保持一致：空正文写一个空格，避免分页器拿到零长度串。
                content: source.content.isEmpty ? " " : source.content,
                richContentData: source.richContentData
            )
            chapter.book = book
            context.insert(chapter)
            chapters.append(chapter)
        }
        book.chapters = chapters

        var records: [ReadingRecord] = []
        records.reserveCapacity(dto.records.count)
        for source in dto.records {
            let record = ReadingRecord(
                id: source.id,
                date: source.date,
                durationSeconds: source.durationSeconds
            )
            record.book = book
            context.insert(record)
            records.append(record)
        }
        book.records = records

        return (chapters.count, records.count)
    }

    @MainActor
    private static func makeSource(_ dto: BackupBookSource) -> BookSource {
        let source = BookSource(
            id: dto.id,
            name: dto.name,
            groupName: dto.groupName,
            searchURL: dto.searchURL,
            bookURL: dto.bookURL,
            tocURL: dto.tocURL,
            contentURL: dto.contentURL,
            headerJSON: dto.headerJSON,
            enabled: dto.enabled,
            format: BookSourceFormat(rawValue: dto.formatRaw) ?? .pureReader,
            comment: dto.comment,
            weight: dto.weight
        )
        // 规则原样回填，避免 ParseRule 结构升级后往返丢字段。
        source.ruleJSON = dto.ruleJSON.isEmpty ? "{}" : dto.ruleJSON
        source.bookCount = dto.bookCount
        source.lastCheckedAt = dto.lastCheckedAt
        source.isValid = dto.isValid
        source.createdAt = dto.createdAt
        return source
    }

    /// 覆盖模式下把备份内容写回同 id 的现有书源（避开唯一约束的删除+插入）。
    @MainActor
    private static func overwrite(_ target: BookSource, with dto: BackupBookSource) {
        target.name = dto.name
        target.groupName = dto.groupName
        target.searchURL = dto.searchURL
        target.bookURL = dto.bookURL
        target.tocURL = dto.tocURL
        target.contentURL = dto.contentURL
        target.headerJSON = dto.headerJSON
        target.ruleJSON = dto.ruleJSON.isEmpty ? "{}" : dto.ruleJSON
        target.enabled = dto.enabled
        target.formatRaw = dto.formatRaw
        target.bookCount = dto.bookCount
        target.lastCheckedAt = dto.lastCheckedAt
        target.isValid = dto.isValid
        target.comment = dto.comment
        target.weight = dto.weight
        target.createdAt = dto.createdAt
    }

    @MainActor
    private static func makeBookmark(_ dto: BackupBookmark) -> Bookmark {
        Bookmark(
            id: dto.id,
            bookID: dto.bookID,
            chapterID: dto.chapterID,
            chapterIndex: dto.chapterIndex,
            chapterTitle: dto.chapterTitle,
            utf16Location: dto.utf16Location,
            utf16Length: dto.utf16Length,
            excerpt: dto.excerpt,
            note: dto.note,
            color: HighlightColor(rawValue: dto.colorRaw) ?? .yellow,
            createdAt: dto.createdAt
        )
    }

    @MainActor
    private static func makeRewriteRecord(_ dto: BackupRewriteRecord) -> RewriteRecord {
        RewriteRecord(
            id: dto.id,
            bookID: dto.bookID,
            chapterID: dto.chapterID,
            originalText: dto.originalText,
            rewrittenText: dto.rewrittenText,
            userRequest: dto.userRequest,
            stylePreset: RewriteStylePreset(rawValue: dto.stylePresetRaw) ?? .default,
            timestamp: dto.timestamp,
            originalUTF16Offset: dto.originalUTF16Offset,
            isUndone: dto.isUndone,
            isFavorite: dto.isFavorite,
            branchLabel: dto.branchLabel
        )
    }

    @MainActor
    private static func applyShelfPreferences(
        _ dto: BackupShelfPreferences,
        strategy: RestoreStrategy,
        existing: [ShelfPreferences],
        context: ModelContext
    ) {
        // 覆盖模式下旧行已在前面删掉，这里 current 一定为 nil。
        let current = strategy == .replace ? nil : existing.first
        guard let current else {
            context.insert(
                ShelfPreferences(
                    id: dto.id,
                    customGroups: dto.customGroups,
                    knownTags: dto.knownTags
                )
            )
            return
        }
        // 合并模式取并集：用户当前的自定义分组不该因为恢复而消失。
        current.customGroups = mergedUnique(current.customGroups, dto.customGroups)
        current.knownTags = mergedUnique(current.knownTags, dto.knownTags).sorted()
    }

    @MainActor
    private static func applyReadingSettings(
        _ dto: BackupReadingSettings,
        strategy: RestoreStrategy,
        existing: [ReadingSettings],
        context: ModelContext
    ) {
        // 合并模式不动当前排版偏好，只在书库里根本没有设置行时补一条。
        if strategy == .merge, existing.first != nil { return }
        let settings = ReadingSettings(
            fontSize: dto.fontSize,
            lineSpacing: dto.lineSpacing,
            pageMargin: MarginMode(rawValue: dto.pageMarginRaw) ?? .normal,
            backgroundColor: BackgroundType(rawValue: dto.backgroundColorRaw) ?? .cream,
            pageTurnMode: PageTurnMode(rawValue: dto.pageTurnModeRaw) ?? .scroll,
            showHeader: dto.showHeader,
            showPageNumber: dto.showPageNumber,
            ttsRate: dto.ttsRate,
            ttsProvider: TTSProvider(rawValue: dto.ttsProviderRaw) ?? .system,
            ttsVoice: dto.ttsVoice,
            keepScreenOn: dto.keepScreenOn,
            brightnessOverride: dto.brightnessOverride,
            firstLineIndentChars: dto.firstLineIndentChars,
            paragraphSpacingRatio: dto.paragraphSpacingRatio,
            sleepTimerMinutes: dto.sleepTimerMinutes,
            sleepAfterChapter: dto.sleepAfterChapter
        )
        context.insert(settings)
    }

    private static func mergedUnique(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set<String>()
        return (lhs + rhs).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - 文件

    /// 备份写在 tmp/Backups 下；每次备份前清空，避免多次导出把临时目录撑爆。
    private static func prepareExportURL() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("Backups", isDirectory: true)
        if let stale = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in stale { try? fm.removeItem(at: file) }
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw BackupError.writeFailed(error.localizedDescription)
        }
        return dir.appendingPathComponent("\(exportFilename()).\(fileExtension)")
    }

    /// 与 `BookImportService` 同一套思路：白名单化字符（黑名单挡不住 `..`、NUL、
    /// RTL override 等），再追加时间戳与短 UUID 避免同名覆盖。
    /// 那边是 private，这里保持独立实现，不去改现有文件。
    private static func exportFilename() -> String {
        let base = String(localized: "纯享阅读备份")
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -_()[]（）【】"))
        var sanitized = String(
            base.unicodeScalars
                .map { allowed.contains($0) || $0.value > 0x2FFF ? Character($0) : "_" }
                .prefix(40)
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if sanitized.isEmpty
            || sanitized.hasPrefix(".")
            || sanitized.allSatisfy({ $0 == "_" }) {
            sanitized = "PureReader"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "\(sanitized)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))"
    }

    /// fileImporter 允许的类型。
    ///
    /// `.purereaderbackup` 没有在 Info.plist 里声明 UTI，系统会把它归到 `public.data`，
    /// 所以这里放宽到 data / item，否则用户在「文件」里根本点不动自己的备份。
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.json, .plainText, .text, .data, .item]
        if let declared = UTType(filenameExtension: fileExtension) {
            types.insert(declared, at: 0)
        }
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }

    // MARK: - 错误

    enum BackupError: LocalizedError, Sendable {
        case emptyLibrary
        case unreadableFile(String)
        case invalidFormat
        case unsupportedSchema(Int)
        case fileTooLarge
        case writeFailed(String)
        case restoreFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyLibrary:
                return String(localized: "书库是空的，没有可备份的内容")
            case .unreadableFile(let message):
                return String(localized: "无法读取备份文件：\(message)")
            case .invalidFormat:
                return String(localized: "这不是有效的纯享阅读备份文件")
            case .unsupportedSchema(let version):
                return String(localized: "备份文件版本（v\(version)）高于当前 App，请先升级后再恢复")
            case .fileTooLarge:
                return String(localized: "备份文件超过 300 MB，已停止恢复")
            case .writeFailed(let message):
                return String(localized: "写入备份文件失败：\(message)")
            case .restoreFailed(let message):
                return String(localized: "恢复失败，已回滚到恢复前的状态：\(message)")
            }
        }
    }
}
