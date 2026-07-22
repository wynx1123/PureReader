import Foundation
import SwiftData
import SwiftUI
import Observation

@MainActor
@Observable
final class ReaderViewModel {
    let book: Book
    private let context: ModelContext

    // Settings (singleton row)
    private(set) var settings: ReadingSettings

    // Chapter / pages
    private(set) var chapters: [Chapter] = []
    private(set) var chapterIndex: Int = 0
    private(set) var pages: [ReaderPage] = []
    private(set) var pageIndex: Int = 0
    private(set) var isPaginating = false
    private(set) var pageSize: CGSize = .zero

    // UI chrome
    var chromeVisible = true
    var showSettings = false
    var showChapterList = false
    var showTTSBar = false
    var showAIRewrite = false
    var showAIHistory = false
    var isTTSSpeaking = false
    var isTTSPaused = false

    // Engines
    let tts = TTSEngine()
    let timer = ReadingTimeTracker()

    private var paginateTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(book: Book, context: ModelContext) {
        self.book = book
        self.context = context
        self.settings = Self.loadOrCreateSettings(context: context)
        self.chapters = (book.chapters ?? []).sorted { $0.index < $1.index }
        self.chapterIndex = min(max(0, book.currentChapterIndex), max(0, chapters.count - 1))
        timer.attach(book: book, context: context)
        tts.configure(rate: settings.ttsRate, voiceIdentifier: settings.ttsVoice.isEmpty ? nil : settings.ttsVoice)
        tts.onFinishUtterance = { [weak self] in
            self?.syncTTSFlags()
            self?.handleTTSFinished()
        }
        tts.onBoundary = { [weak self] relativeOffset in
            self?.handleTTSBoundary(relativeOffset: relativeOffset)
        }
    }

    var currentChapter: Chapter? {
        guard chapters.indices.contains(chapterIndex) else { return nil }
        return chapters[chapterIndex]
    }

    var currentPage: ReaderPage? {
        guard pages.indices.contains(pageIndex) else { return nil }
        return pages[pageIndex]
    }

    var progressText: String {
        let ch = chapters.isEmpty ? 0 : chapterIndex + 1
        let pg = pages.isEmpty ? 0 : pageIndex + 1
        return String(localized: "第 \(ch)/\(max(chapters.count, 1)) 章 · \(pg)/\(max(pages.count, 1)) 页")
    }

    // MARK: - Lifecycle

    func onAppear() {
        timer.start()
        book.lastReadAt = Date()
        try? context.save()
        BookUnderstandingCoordinator.shared.scheduleIfNeeded(book: book, context: context)
    }

    func onDisappear() {
        paginateTask?.cancel()
        tts.stop()
        timer.stop()
        persistProgress(immediate: true)
    }

    func onScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            timer.start()
        case .inactive, .background:
            timer.pause()
            persistProgress(immediate: true)
        @unknown default:
            break
        }
    }

    // MARK: - Layout / Pagination

    func updatePageSize(_ size: CGSize) {
        let rounded = CGSize(width: floor(size.width), height: floor(size.height))
        guard rounded.width > 10, rounded.height > 10 else { return }
        if abs(rounded.width - pageSize.width) < 1,
           abs(rounded.height - pageSize.height) < 1 {
            return
        }
        pageSize = rounded
        repaginate(restoreOffset: book.currentPageOffset)
    }

    func repaginate(restoreOffset: Int? = nil) {
        guard let chapter = currentChapter else {
            pages = []
            pageIndex = 0
            return
        }
        let size = pageSize
        guard size.width > 10, size.height > 10 else { return }

        isPaginating = true
        paginateTask?.cancel()

        let text = chapter.content
        let chapterID = chapter.id.uuidString
        let layout = TextPaginator.Layout(
            fontSize: settings.fontSize,
            lineSpacing: settings.lineSpacing,
            margin: settings.pageMargin,
            contentSize: size,
            isDark: settings.backgroundColor == .dark
        )
        let offsetToRestore = restoreOffset ?? currentPage?.location ?? book.currentPageOffset

        paginateTask = Task.detached(priority: .userInitiated) {
            let result = TextPaginator.paginate(
                chapterID: chapterID,
                text: text,
                layout: layout
            )
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.pages = result
                self.pageIndex = TextPaginator.pageIndex(
                    forCharacterOffset: offsetToRestore,
                    in: result
                )
                self.isPaginating = false
                self.persistProgress(immediate: false)
            }
        }

        // 预加载邻章
        preloadAdjacentChapters(layout: layout)
    }

    private func preloadAdjacentChapters(layout: TextPaginator.Layout) {
        let neighbors = [chapterIndex - 1, chapterIndex + 1]
            .filter { chapters.indices.contains($0) }
        for idx in neighbors {
            let ch = chapters[idx]
            let id = ch.id.uuidString
            let text = ch.content
            Task.detached(priority: .utility) {
                _ = TextPaginator.paginate(chapterID: id, text: text, layout: layout)
            }
        }
    }

    // MARK: - Navigation

    func goToPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        pageIndex = index
        persistProgress(immediate: false)
    }

    func nextPage() {
        if pageIndex + 1 < pages.count {
            goToPage(pageIndex + 1)
        } else {
            nextChapter()
        }
    }

    func previousPage() {
        if pageIndex > 0 {
            goToPage(pageIndex - 1)
        } else {
            previousChapter(atEnd: true)
        }
    }

    func goToChapter(_ index: Int) {
        guard chapters.indices.contains(index) else { return }
        chapterIndex = index
        book.currentChapterIndex = index
        book.currentPageOffset = 0
        pageIndex = 0
        repaginate(restoreOffset: 0)
        showChapterList = false
    }

    func nextChapter() {
        guard chapterIndex + 1 < chapters.count else { return }
        goToChapter(chapterIndex + 1)
    }

    func previousChapter(atEnd: Bool = false) {
        guard chapterIndex > 0 else { return }
        chapterIndex -= 1
        book.currentChapterIndex = chapterIndex
        // Int.max/4 让 pageIndex 落在最后一页
        let restore = atEnd ? (Int.max / 4) : 0
        book.currentPageOffset = restore
        repaginate(restoreOffset: restore)
    }

    func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible.toggle()
        }
    }

    // MARK: - Settings mutations

    func setFontSize(_ value: Double) {
        settings.fontSize = min(28, max(14, value))
        saveSettings()
        repaginate()
    }

    func setLineSpacing(_ value: Double) {
        settings.lineSpacing = min(2.5, max(1.2, value))
        saveSettings()
        repaginate()
    }

    func setMargin(_ mode: MarginMode) {
        settings.pageMargin = mode
        saveSettings()
        repaginate()
    }

    func setBackground(_ type: BackgroundType) {
        settings.backgroundColor = type
        saveSettings()
        // 颜色变化需重分页（前景色）
        repaginate()
    }

    func setPageTurnMode(_ mode: PageTurnMode) {
        settings.pageTurnMode = mode
        saveSettings()
    }

    func setTTSRate(_ value: Double) {
        settings.ttsRate = min(2.0, max(0.5, value))
        tts.configure(rate: settings.ttsRate, voiceIdentifier: settings.ttsVoice.isEmpty ? nil : settings.ttsVoice)
        saveSettings()
    }

    func setTTSVoice(_ id: String) {
        settings.ttsVoice = id
        tts.configure(rate: settings.ttsRate, voiceIdentifier: id.isEmpty ? nil : id)
        saveSettings()
    }

    // MARK: - TTS

    func toggleTTS() {
        if tts.isSpeaking && !tts.isPaused {
            tts.pause()
            syncTTSFlags()
            return
        }
        if tts.isPaused {
            tts.resume()
            syncTTSFlags()
            return
        }
        startTTSFromCurrentPage()
    }

    func startTTSFromCurrentPage() {
        guard let chapter = currentChapter else { return }
        showTTSBar = true
        let offset = currentPage?.location ?? 0
        tts.configure(rate: settings.ttsRate, voiceIdentifier: settings.ttsVoice.isEmpty ? nil : settings.ttsVoice)
        tts.speak(
            text: chapter.content,
            bookTitle: book.title,
            chapterTitle: chapter.title,
            startOffset: offset
        )
        syncTTSFlags()
    }

    func syncTTSFlags() {
        isTTSSpeaking = tts.isSpeaking
        isTTSPaused = tts.isPaused
    }

    func stopTTS() {
        tts.stop()
        syncTTSFlags()
        showTTSBar = false
    }

    private func handleTTSBoundary(relativeOffset: Int) {
        // relativeOffset 相对 utterance 文本；speak 时从当前页 location 起切片
        let start = tts.spokenOffset
        let absolute = start + relativeOffset
        let idx = TextPaginator.pageIndex(forCharacterOffset: absolute, in: pages)
        if idx != pageIndex {
            goToPage(idx)
        }
        book.currentPageOffset = absolute
    }

    private func handleTTSFinished() {
        // 本章读完 → 下一章继续
        if chapterIndex + 1 < chapters.count {
            goToChapter(chapterIndex + 1)
            // 等分页完成后自动继续
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                startTTSFromCurrentPage()
            }
        } else {
            showTTSBar = false
        }
    }


    // MARK: - AI Rewrite

    func applyRewrite(original: String, rewritten: String) throws {
        guard let chapter = currentChapter else {
            throw RewriteApplyError.noChapter
        }
        let content = chapter.content
        guard let range = content.range(of: original) else {
            // fallback: try trimmed
            let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let r2 = content.range(of: trimmed) else {
                throw RewriteApplyError.originalNotFound
            }
            applyReplace(in: chapter, range: r2, rewritten: rewritten, original: trimmed)
            return
        }
        applyReplace(in: chapter, range: range, rewritten: rewritten, original: original)
    }

    private func applyReplace(
        in chapter: Chapter,
        range: Range<String.Index>,
        rewritten: String,
        original: String
    ) {
        var content = chapter.content
        let utf16Offset = content.utf16.distance(from: content.startIndex, to: range.lowerBound)
        content.replaceSubrange(range, with: rewritten)
        chapter.content = content

        let record = RewriteRecord(
            bookID: book.id,
            chapterID: chapter.id,
            originalText: original,
            rewrittenText: rewritten,
            userRequest: "",
            stylePreset: AIConfig.stylePreset,
            originalUTF16Offset: utf16Offset
        )
        context.insert(record)
        trimRewriteHistory()

        try? context.save()

        BookUnderstandingCoordinator.shared.onChapterRewritten(
            bookID: book.id,
            chapterID: chapter.id,
            chapterIndex: chapter.index,
            content: content
        )

        // 尽量保持当前页附近
        let restore = book.currentPageOffset
        repaginate(restoreOffset: restore)
        persistProgress(immediate: true)
    }

    private func trimRewriteHistory() {
        let bid = book.id
        let descriptor = FetchDescriptor<RewriteRecord>(
            sortBy: [SortDescriptor(\RewriteRecord.timestamp, order: .reverse)]
        )
        guard let all = try? context.fetch(descriptor) else { return }
        let mine = all.filter { $0.bookID == bid }
        if mine.count > AIRewriteConstants.maxRewriteHistory {
            for extra in mine.dropFirst(AIRewriteConstants.maxRewriteHistory) {
                context.delete(extra)
            }
        }
    }

    /// 撤销单条改写：将 rewritten 还原为 original
    @discardableResult
    func undoRewrite(_ record: RewriteRecord) throws -> Bool {
        guard !record.isUndone else { return false }
        let chapters = book.chapters ?? []
        guard let chapter = chapters.first(where: { $0.id == record.chapterID }) else {
            throw RewriteApplyError.noChapter
        }
        var content = chapter.content
        if let range = content.range(of: record.rewrittenText) {
            content.replaceSubrange(range, with: record.originalText)
        } else if let range = content.range(of: record.rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            content.replaceSubrange(range, with: record.originalText)
        } else {
            throw RewriteApplyError.originalNotFound
        }
        chapter.content = content
        record.isUndone = true
        try? context.save()

        BookUnderstandingCoordinator.shared.onChapterRewritten(
            bookID: book.id,
            chapterID: chapter.id,
            chapterIndex: chapter.index,
            content: content
        )
        if chapter.index == chapterIndex {
            repaginate(restoreOffset: book.currentPageOffset)
        }
        persistProgress(immediate: true)
        return true
    }

    /// 一键还原本书全部未撤销的改写（按时间逆序）
    func undoAllRewrites() throws -> Int {
        let bid = book.id
        let descriptor = FetchDescriptor<RewriteRecord>(
            sortBy: [SortDescriptor(\RewriteRecord.timestamp, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        let mine = all.filter { $0.bookID == bid && !$0.isUndone }
        var count = 0
        for record in mine {
            do {
                if try undoRewrite(record) { count += 1 }
            } catch {
                // 继续尝试其余
            }
        }
        return count
    }

    func fetchRewriteRecords() -> [RewriteRecord] {
        let bid = book.id
        let descriptor = FetchDescriptor<RewriteRecord>(
            sortBy: [SortDescriptor(\RewriteRecord.timestamp, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.bookID == bid }
    }

    func toggleFavorite(_ record: RewriteRecord) {
        record.isFavorite.toggle()
        try? context.save()
    }

    // MARK: - Persist

    func persistProgress(immediate: Bool) {
        book.currentChapterIndex = chapterIndex
        if let page = currentPage {
            book.currentPageOffset = page.location
        }
        book.lastReadAt = Date()
        if chapters.count > 0 {
            book.readingProgress = Double(chapterIndex) / Double(chapters.count)
                + (pages.isEmpty ? 0 : Double(pageIndex) / Double(pages.count) / Double(chapters.count))
        }

        saveTask?.cancel()
        if immediate {
            try? context.save()
            return
        }
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            try? context.save()
        }
    }

    private func saveSettings() {
        try? context.save()
    }

    private static func loadOrCreateSettings(context: ModelContext) -> ReadingSettings {
        var descriptor = FetchDescriptor<ReadingSettings>()
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let created = ReadingSettings()
        context.insert(created)
        try? context.save()
        return created
    }
}


enum RewriteApplyError: LocalizedError {
    case noChapter
    case originalNotFound

    var errorDescription: String? {
        switch self {
        case .noChapter: return String(localized: "当前无章节")
        case .originalNotFound: return String(localized: "未在章节中找到原文，请缩短选择范围后重试")
        }
    }
}
