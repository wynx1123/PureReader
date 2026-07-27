import Foundation
import SwiftData
import SwiftUI

/// 导入完成后保留在书架上的结果卡片，避免系统 Alert 被 Sheet / 文件选择器吞掉。
struct ImportReport: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let details: [String]
    let isSuccess: Bool
}

@MainActor
@Observable
final class BookshelfViewModel {
    var sort: BookshelfSort = .lastRead
    var layout: BookshelfLayout = .grid
    var selectedGroup: String? = nil // nil = 全部
    var selectedTag: String? = nil
    var searchText: String = ""

    var isImporting = false
    /// 兼容 URL 导入页的行内错误展示
    var importErrorMessage: String?
    var importSuccessMessage: String?
    /// 文件选择完成后的可见状态（不依赖 Alert）
    var importProgressText: String?
    var importProgressDetail: String?
    var importReport: ImportReport?

    /// 文件选择器必须挂在根视图（不要放在 sheet 内）
    var showImporter = false
    var showURLImporter = false
    var showAddSheet = false
    var urlString = ""
    var pendingTags: String = ""
    var pendingGroup: String = BuiltInGroup.defaultKey

    var isCheckingUpdates = false
    var updateStatusMessage: String?
    var onlineOperationError: String?
    var downloadingBookID: UUID?
    var downloadCompleted = 0
    var downloadTotal = 0
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]
    private var downloadGenerations: [UUID: UInt64] = [:]

    func filteredSorted(_ books: [Book]) -> [Book] {
        var list = books

        if let g = selectedGroup {
            // 两侧都先归一到稳定 key，存量的中文名与 "__default" 才能和当前选中值对上。
            let target = BuiltInGroup.normalize(g)
            list = list.filter { BuiltInGroup.normalize($0.group) == target }
        }

        if let tag = selectedTag, !tag.isEmpty {
            list = list.filter { $0.tags.contains(tag) }
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(q)
                    || $0.author.localizedCaseInsensitiveContains(q)
                    || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(q) })
            }
        }

        switch sort {
        case .lastRead:
            list.sort { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
        case .recentlyAdded:
            list.sort { $0.addedAt > $1.addedAt }
        case .title:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            list.sort { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        }
        return list
    }

    /// 书架筛选栏用的分组全集：内置三组 + 书上出现过的分组 + 用户自定义组。
    /// 返回的都是可直接写进 `Book.group` 的稳定 key（默认组用 `BuiltInGroup.defaultKey`）。
    func allGroups(from books: [Book], prefs: ShelfPreferences?) -> [String] {
        var set = Set(BuiltInGroup.allKeys)
        for b in books {
            // 存量的中文名先归一，避免「默认 / __default」并排出现两个胶囊。
            if let g = BuiltInGroup.normalize(b.group) { set.insert(g) }
        }
        for g in prefs?.customGroups ?? [] {
            if let normalized = BuiltInGroup.normalize(g) { set.insert(normalized) }
        }
        return set.sorted { a, b in
            // 默认组恒定排第一，其余内置组优先于自定义组。
            if a == BuiltInGroup.defaultKey { return true }
            if b == BuiltInGroup.defaultKey { return false }
            let aBuiltIn = BuiltInGroup.isBuiltIn(a)
            let bBuiltIn = BuiltInGroup.isBuiltIn(b)
            if aBuiltIn != bBuiltIn { return aBuiltIn }
            return BuiltInGroup.displayName(for: a)
                .localizedStandardCompare(BuiltInGroup.displayName(for: b)) == .orderedAscending
        }
    }

    // MARK: - 自定义分组

    /// 新建自定义分组。去空白、去重，并拒绝与内置组重名（含本地化显示名）。
    /// 返回是否真正写入了新分组。
    @discardableResult
    func createGroup(_ name: String, context: ModelContext) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // 不允许伪造内置 key，也不允许用「默认 / 正在读 / 已读完」这类显示名占位。
        guard !BuiltInGroup.isBuiltIn(trimmed) else { return false }
        let builtInDisplayNames = BuiltInGroup.allKeys.map { BuiltInGroup.displayName(for: $0) }
        guard !builtInDisplayNames.contains(trimmed) else { return false }

        let prefs = shelfPreferences(in: context)
        guard !prefs.customGroups.contains(trimmed) else { return false }
        prefs.customGroups.append(trimmed)
        prefs.customGroups.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        try? context.save()
        return true
    }

    /// 删除自定义分组，并把该组下的书归回默认分组（`group = nil`）。
    func deleteGroup(_ name: String, context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !BuiltInGroup.isBuiltIn(trimmed) else { return }

        let prefs = shelfPreferences(in: context)
        prefs.customGroups.removeAll { $0 == trimmed }

        for book in fetchBooks(in: context) where BuiltInGroup.normalize(book.group) == trimmed {
            book.group = nil
        }
        if BuiltInGroup.normalize(selectedGroup) == trimmed { selectedGroup = nil }
        if BuiltInGroup.normalize(pendingGroup) == trimmed { pendingGroup = BuiltInGroup.defaultKey }
        try? context.save()
    }

    /// 重命名自定义分组，同步迁移该组下所有书的 `group` 字段。
    /// 返回是否重命名成功（新名为空/重名/旧名不是自定义组时失败）。
    @discardableResult
    func renameGroup(_ old: String, to new: String, context: ModelContext) -> Bool {
        let oldTrimmed = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTrimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldTrimmed.isEmpty, !newTrimmed.isEmpty, oldTrimmed != newTrimmed else { return false }
        // 内置组不可改名，也不能改成内置组的 key / 显示名。
        guard !BuiltInGroup.isBuiltIn(oldTrimmed), !BuiltInGroup.isBuiltIn(newTrimmed) else { return false }
        let builtInDisplayNames = BuiltInGroup.allKeys.map { BuiltInGroup.displayName(for: $0) }
        guard !builtInDisplayNames.contains(newTrimmed) else { return false }

        let prefs = shelfPreferences(in: context)
        guard !prefs.customGroups.contains(newTrimmed) else { return false }
        prefs.customGroups.removeAll { $0 == oldTrimmed }
        prefs.customGroups.append(newTrimmed)
        prefs.customGroups.sort { $0.localizedStandardCompare($1) == .orderedAscending }

        for book in fetchBooks(in: context) where BuiltInGroup.normalize(book.group) == oldTrimmed {
            book.group = newTrimmed
        }
        if BuiltInGroup.normalize(selectedGroup) == oldTrimmed { selectedGroup = newTrimmed }
        if BuiltInGroup.normalize(pendingGroup) == oldTrimmed { pendingGroup = newTrimmed }
        try? context.save()
        return true
    }

    /// 读取（必要时创建）书架偏好单例行。与 BookImportService.updateKnownTags 同一套模板。
    private func shelfPreferences(in context: ModelContext) -> ShelfPreferences {
        let descriptor = FetchDescriptor<ShelfPreferences>()
        if let existing = (try? context.fetch(descriptor))?.first { return existing }
        let created = ShelfPreferences()
        context.insert(created)
        return created
    }

    private func fetchBooks(in context: ModelContext) -> [Book] {
        (try? context.fetch(FetchDescriptor<Book>())) ?? []
    }

    func allTags(from books: [Book], prefs: ShelfPreferences?) -> [String] {
        var set = Set(prefs?.knownTags ?? [])
        for b in books {
            for t in b.tags where !t.isEmpty { set.insert(t) }
        }
        return set.sorted()
    }

    /// 清空「导入后应用」的元数据，恢复为默认分组与空标签。
    func resetPendingMeta() {
        pendingTags = ""
        pendingGroup = BuiltInGroup.defaultKey
    }

    func parseTagsField(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Local file import

    /// 从 fileImporter completion 同步调用。
    /// 在回调当下取得 Security Scope，但将 iCloud 下载/复制放到后台；scope 会一直
    /// 保持到对应文件完成暂存，避免主线程卡住或异步开始前权限失效。
    func beginLocalImport(_ urls: [URL], context: ModelContext) {
        guard !urls.isEmpty else {
            showImportReport(
                title: String(localized: "没有选择文件"),
                message: String(localized: "请在“文件”中选择 TXT 或 EPUB 后重试。"),
                details: [],
                isSuccess: false
            )
            return
        }
        guard !isImporting else { return }

        isImporting = true
        importErrorMessage = nil
        importSuccessMessage = nil
        importReport = nil
        importProgressText = String(localized: "正在准备文件")
        importProgressDetail = urls.map(\.lastPathComponent).joined(separator: "、")

        // fileImporter 回调中立即取得权限，实际文件下载与复制在后台进行。
        let scopedURLs = urls.map { url in
            (url: url, accessed: url.startAccessingSecurityScopedResource())
        }

        Task { [weak self] in
            guard let self else {
                for item in scopedURLs where item.accessed {
                    item.url.stopAccessingSecurityScopedResource()
                }
                return
            }
            await self.performScopedImport(scopedURLs, context: context)
        }
    }

    private func performScopedImport(
        _ scopedURLs: [(url: URL, accessed: Bool)],
        context: ModelContext
    ) async {
        var staged: [(filename: String, url: URL)] = []
        var failures: [String] = []
        for scoped in scopedURLs {
            let sourceURL = scoped.url
            let filename = sourceURL.lastPathComponent
            do {
                importProgressDetail = filename
                let stagedURL = try await BookImportService.stageSecurityScopedFileAsync(sourceURL)
                staged.append((filename, stagedURL))
            } catch {
                failures.append("\(filename)：\(diagnosticMessage(for: error))")
            }
            if scoped.accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
            // UIDocumentPickerViewController(asCopy: true) 返回的是系统复制到本 App
            // tmp 目录下的副本，所有权归 App，必须自行删除，
            // 否则每导入一本就泄漏一份全量文件。
            try? FileManager.default.removeItem(at: sourceURL)
        }
        await performStagedImport(staged, stagingFailures: failures, context: context)
    }

    private func performStagedImport(
        _ stagedURLs: [(filename: String, url: URL)],
        stagingFailures: [String],
        context: ModelContext
    ) async {
        defer {
            for item in stagedURLs { try? FileManager.default.removeItem(at: item.url) }
            isImporting = false
            importProgressText = nil
            importProgressDetail = nil
        }

        let tags = parseTagsField(pendingTags)
        let group = BuiltInGroup.normalize(pendingGroup)
        var importedTitles: [String] = []
        var importedBooks: [Book] = []
        var failures = stagingFailures

        for (index, item) in stagedURLs.enumerated() {
            let filename = item.filename.isEmpty
                ? String(localized: "未命名文件")
                : item.filename
            importProgressText = String(localized: "正在导入 \(index + 1)/\(stagedURLs.count)")
            importProgressDetail = filename

            do {
                let parsed = try await BookImportService.parseStagedFile(
                    url: item.url,
                    originalFilename: filename
                )
                importProgressText = String(localized: "正在保存《\(parsed.title)》")
                let book = try BookImportService.save(
                    parsed: parsed,
                    sourceType: .local,
                    sourceURL: nil,
                    group: group,
                    tags: tags,
                    into: context
                )
                importedTitles.append(book.title)
                importedBooks.append(book)
            } catch {
                failures.append("\(filename)：\(diagnosticMessage(for: error))")
            }
        }

        if !importedTitles.isEmpty {
            let message = failures.isEmpty
                ? String(localized: "已成功加入书架。")
                : String(localized: "部分文件已成功加入书架；其余失败原因如下。")
            importSuccessMessage = String(localized: "成功导入 \(importedTitles.count) 本书")
            showAddSheet = false
            showImportReport(
                title: importSuccessMessage ?? String(localized: "导入完成"),
                message: message,
                details: importedTitles.map { "✓ 《\($0)》" } + failures,
                isSuccess: failures.isEmpty
            )
            for book in importedBooks {
                scheduleUnderstandingAfterImport(book, context: context)
            }
            // 待应用的元数据是「本批次」的，导入成功后必须清空。
            // 否则下一批导入会静默沿用上一批的标签与分组（用户毫无提示）。
            resetPendingMeta()
        } else {
            let message = String(localized: "没有任何书籍被导入。请查看下方诊断信息。")
            importErrorMessage = failures.joined(separator: "\n")
            showImportReport(
                title: String(localized: "导入失败"),
                message: message,
                details: failures.isEmpty
                    ? [String(localized: "文件选择器未返回可读取的文件 URL。")]
                    : failures,
                isSuccess: false
            )
        }
    }

    func handleFilePickerFailure(_ error: Error) {
        let nsError = error as NSError
        // 用户取消选择不作为失败提示。
        guard nsError.code != NSUserCancelledError else { return }
        showImportReport(
            title: String(localized: "无法打开文件"),
            message: String(localized: "“文件”App 未能把所选文件交给纯享阅读。"),
            details: [diagnosticMessage(for: error)],
            isSuccess: false
        )
    }

    func dismissImportReport() {
        importReport = nil
        importErrorMessage = nil
        importSuccessMessage = nil
    }

    private func showImportReport(
        title: String,
        message: String,
        details: [String],
        isSuccess: Bool
    ) {
        importReport = ImportReport(
            title: title,
            message: message,
            details: details,
            isSuccess: isSuccess
        )
    }

    private func diagnosticMessage(for error: Error) -> String {
        let userMessage = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let nsError = error as NSError
        return "\(userMessage)\n\(String(localized: "诊断代码"))：\(nsError.domain) (\(nsError.code))"
    }

    // MARK: - URL import

    func importFromURL(context: ModelContext) async {
        isImporting = true
        importErrorMessage = nil
        importSuccessMessage = nil
        defer { isImporting = false }

        let tags = parseTagsField(pendingTags)
        let group = BuiltInGroup.normalize(pendingGroup)
        let urlText = urlString

        do {
            let parsed = try await BookImportService.parseRemoteURL(urlText)
            let book = try BookImportService.save(
                parsed: parsed,
                sourceType: .url,
                sourceURL: urlText,
                group: group,
                tags: tags,
                into: context
            )
            scheduleUnderstandingAfterImport(book, context: context)
            urlString = ""
            showURLImporter = false
            showAddSheet = false
            resetPendingMeta()
            importSuccessMessage = String(localized: "成功导入《\(book.title)》")
        } catch {
            importErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func delete(_ book: Book, context: ModelContext) {
        let bookID = book.id
        invalidateDownloads(for: bookID)
        do {
            try BookImportService.deleteBook(book, context: context)
        } catch {
            importErrorMessage = error.localizedDescription
        }
        do { try OnlineLibraryService.purgeCache(bookID: bookID) }
        catch { importErrorMessage = String(localized: "书籍已删除，但缓存清理失败：\(error.localizedDescription)") }
    }

    // MARK: - Online updates and offline cache

    func checkUpdates(for book: Book, context: ModelContext) async {
        guard book.format == .online else { return }
        isCheckingUpdates = true
        onlineOperationError = nil
        updateStatusMessage = String(localized: "正在检查《\(book.title)》…")
        defer { isCheckingUpdates = false }
        do {
            let source = try sourceSnapshot(for: book, context: context)
            guard let bookURL = book.sourceURL else { throw OnlineLibraryError.notOnlineBook }
            let fetched = try await BookSourceEngine.fetchTOC(bookURL: bookURL, source: source)
            guard !fetched.isEmpty else { throw BookSourceError.empty }
            let existing = (book.chapters ?? []).sorted { $0.index < $1.index }
            let existingByKey = Dictionary(existing.compactMap { chapter in
                chapter.sourceURL.flatMap(OnlineLibraryService.stableChapterURL).map { ($0, chapter) }
            }, uniquingKeysWith: { first, _ in first })
            let alignment = OnlineLibraryService.alignCatalog(
                existingURLs: existing.compactMap(\.sourceURL),
                fetched: fetched
            )
            let currentID = existing.first(where: { $0.index == book.currentChapterIndex })?.id
            let previouslyReadIDs = Set(existing.filter { $0.index <= book.highestReadChapterIndex }.map(\.id))
            let oldUnreadCount = book.unreadChapterCount
            let oldFirstUnread = book.firstUnreadChapterIndex
            let oldTotal = book.totalChapters
            let oldCheckedAt = book.lastUpdateCheckedAt
            let oldCurrent = book.currentChapterIndex
            let oldHighestRead = book.highestReadChapterIndex
            let snapshots = existing.map { ($0, $0.index, $0.title, $0.sourceURL) }
            var inserted: [Chapter] = []
            do {
                var aligned: [Chapter] = []
                for item in alignment.items {
                    if let chapter = existingByKey[item.key] {
                        if !item.isRetainedRemoteDeletion {
                            chapter.title = item.title
                            chapter.sourceURL = item.url
                        }
                        aligned.append(chapter)
                    } else {
                        let chapter = Chapter(index: aligned.count, title: item.title, sourceURL: item.url)
                        chapter.book = book
                        context.insert(chapter)
                        inserted.append(chapter)
                        aligned.append(chapter)
                    }
                }
                for (index, chapter) in aligned.enumerated() { chapter.index = index }
                book.totalChapters = aligned.count
                if let currentID, let current = aligned.firstIndex(where: { $0.id == currentID }) {
                    book.currentChapterIndex = current
                }
                // The scalar read model can represent only a contiguous prefix.
                // Stop it at the first remotely inserted/unread chapter so a middle
                // insertion is not accidentally marked read. Keep current position
                // independently by chapter identity above.
                let firstUnread = aligned.firstIndex { !previouslyReadIDs.contains($0.id) }
                book.firstUnreadChapterIndex = firstUnread ?? -1
                book.unreadChapterCount = aligned.lazy.filter { !previouslyReadIDs.contains($0.id) }.count
                book.highestReadChapterIndex = (firstUnread ?? aligned.count) - 1
                book.lastUpdateCheckedAt = Date()
                try context.save()
            } catch {
                for chapter in inserted { context.delete(chapter) }
                for (chapter, index, title, url) in snapshots {
                    chapter.index = index
                    chapter.title = title
                    chapter.sourceURL = url
                }
                book.unreadChapterCount = oldUnreadCount
                book.firstUnreadChapterIndex = oldFirstUnread
                book.totalChapters = oldTotal
                book.lastUpdateCheckedAt = oldCheckedAt
                book.currentChapterIndex = oldCurrent
                book.highestReadChapterIndex = oldHighestRead
                throw error
            }
            updateStatusMessage = alignment.addedCount == 0
                ? String(localized: "《\(book.title)》已是最新")
                : String(localized: "《\(book.title)》新增 \(alignment.addedCount) 章")
        } catch is CancellationError {
            updateStatusMessage = String(localized: "已取消检查")
        } catch {
            onlineOperationError = String(localized: "更新失败：\(error.localizedDescription)；旧目录未改动")
        }
    }

    func checkAllUpdates(books: [Book], context: ModelContext) async {
        let tracked = books.filter { $0.format == .online && $0.updateTrackingEnabled }
        guard !tracked.isEmpty else {
            updateStatusMessage = String(localized: "没有开启追更的网络书籍")
            return
        }
        for book in tracked {
            guard !Task.isCancelled else { return }
            await checkUpdates(for: book, context: context)
        }
    }

    func setTracking(_ enabled: Bool, for book: Book, context: ModelContext) {
        book.updateTrackingEnabled = enabled
        do { try context.save() }
        catch { onlineOperationError = String(localized: "无法保存追更设置：\(error.localizedDescription)") }
    }

    func downloadCurrentChapter(for book: Book, context: ModelContext) {
        startDownload(book: book, range: book.currentChapterIndex...book.currentChapterIndex, context: context)
    }

    func downloadNextTwenty(for book: Book, context: ModelContext) {
        let lower = book.currentChapterIndex + 1
        let upper = min(book.totalChapters - 1, lower + 19)
        guard lower <= upper else {
            onlineOperationError = String(localized: "当前章之后没有可下载章节")
            return
        }
        startDownload(book: book, range: lower...upper, context: context)
    }

    func downloadWholeBook(for book: Book, context: ModelContext) {
        startDownload(book: book, range: 0...max(0, book.totalChapters - 1), context: context)
    }

    func cancelDownload() {
        guard let bookID = downloadingBookID else { return }
        invalidateDownloads(for: bookID)
    }

    func clearOfflineCache(for book: Book, context: ModelContext) {
        invalidateDownloads(for: book.id)
        do {
            try OnlineLibraryService.purgeCache(bookID: book.id)
            for chapter in book.chapters ?? [] {
                chapter.offlineCachePath = nil
                chapter.offlineCachedAt = nil
            }
            try context.save()
            updateStatusMessage = String(localized: "已清除《\(book.title)》离线缓存")
        } catch {
            onlineOperationError = String(localized: "清除离线缓存失败：\(error.localizedDescription)")
        }
    }

    private func startDownload(book: Book, range: ClosedRange<Int>, context: ModelContext) {
        invalidateDownloads(for: book.id)
        onlineOperationError = nil
        let chapters = (book.chapters ?? []).sorted { $0.index < $1.index }.filter { range.contains($0.index) }
        guard !chapters.isEmpty else {
            onlineOperationError = String(localized: "没有可下载的章节")
            return
        }
        let source: BookSourceSnapshot
        do { source = try sourceSnapshot(for: book, context: context) }
        catch { onlineOperationError = error.localizedDescription; return }
        downloadingBookID = book.id
        downloadCompleted = 0
        downloadTotal = chapters.count
        let generation = downloadGenerations[book.id, default: 0]
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if OnlineLibraryService.generationIsCurrent(
                    captured: generation,
                    current: downloadGenerations[book.id, default: 0]
                ) {
                    downloadingBookID = nil
                    downloadTasks[book.id] = nil
                }
            }
            do {
                // Intentionally serial: predictable load, straightforward cancellation,
                // and friendly to small community source servers.
                for chapter in chapters {
                    try Task.checkCancellation()
                    guard let chapterURL = chapter.sourceURL,
                          OnlineLibraryService.stableChapterURL(chapterURL) != nil else {
                        throw OnlineLibraryError.invalidScheme
                    }
                    let text = try await BookSourceEngine.fetchContent(
                        chapterURL: chapterURL,
                        source: source,
                        currentBookURL: book.sourceURL
                    )
                    try Task.checkCancellation()
                    guard OnlineLibraryService.generationIsCurrent(
                        captured: generation,
                        current: downloadGenerations[book.id, default: 0]
                    ) else { throw CancellationError() }
                    let relative = try OnlineLibraryService.writeCachedText(text, bookID: book.id, chapterID: chapter.id)
                    guard OnlineLibraryService.generationIsCurrent(
                        captured: generation,
                        current: downloadGenerations[book.id, default: 0]
                    ) else {
                        try? OnlineLibraryService.removeCachedText(relativePath: relative)
                        throw CancellationError()
                    }
                    chapter.offlineCachePath = relative
                    chapter.offlineCachedAt = Date()
                    try context.save()
                    downloadCompleted += 1
                }
                updateStatusMessage = String(localized: "《\(book.title)》离线下载完成")
            } catch is CancellationError {
                updateStatusMessage = String(localized: "已取消下载，已完成章节仍可离线阅读")
            } catch {
                onlineOperationError = String(localized: "下载到 \(downloadCompleted)/\(downloadTotal) 时失败：\(error.localizedDescription)。可重试同一范围。")
            }
        }
        downloadTasks[book.id] = task
    }

    private func invalidateDownloads(for bookID: UUID) {
        downloadGenerations[bookID, default: 0] &+= 1
        downloadTasks.removeValue(forKey: bookID)?.cancel()
        if downloadingBookID == bookID { downloadingBookID = nil }
    }

    private func sourceSnapshot(for book: Book, context: ModelContext) throws -> BookSourceSnapshot {
        let sources = try context.fetch(FetchDescriptor<BookSource>())
        let source = sources.first { $0.id == book.bookSourceID }
            ?? sources.first { $0.name == book.sourceName }
        guard let source else { throw OnlineLibraryError.sourceMissing }
        return BookSourceSnapshot(source)
    }

    private func scheduleUnderstandingAfterImport(_ book: Book, context: ModelContext) {
        // 先让导入结果和书架刷新完成，再启动可能较重的全书快照与索引任务。
        Task { @MainActor [weak book] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let book else { return }
            BookUnderstandingCoordinator.shared.scheduleIfNeeded(book: book, context: context)
        }
    }

    func updateMeta(
        _ book: Book,
        title: String,
        author: String,
        group: String?,
        tags: [String],
        context: ModelContext
    ) {
        book.title = title
        book.author = author
        book.group = group
        book.tags = tags
        try? context.save()
    }
}
