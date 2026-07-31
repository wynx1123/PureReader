import Foundation
import SwiftData
import SwiftUI
import UIKit
import Observation

@MainActor
@Observable
final class ReaderViewModel {
    private struct ChapterPaginationSnapshot: Sendable {
        let index: Int
        let title: String
        let id: String
        let text: String
        let richContentData: Data?
    }

    let book: Book
    private let context: ModelContext

    // Settings (singleton row)
    private(set) var settings: ReadingSettings

    // Chapter / pages
    private(set) var chapters: [Chapter] = []
    private(set) var chapterIndex: Int = 0
    private(set) var pages: [ReaderPage] = []
    private(set) var verticalPages: [BookReaderPage] = []
    private(set) var pageIndex: Int = 0
    private(set) var isPaginating = false
    private(set) var isLoadingChapterContent = false
    var chapterLoadError: String?
    var verificationRequest: BookSourceVerificationRequest?
    private(set) var verificationSource: BookSource?
    private(set) var pageSize: CGSize = .zero

    // UI chrome
    var chromeVisible = true
    var showSettings = false
    var showChapterList = false
    var showTTSBar = false
    var showAIRewrite = false
    var showAIHistory = false
    private(set) var selectedRewriteText = ""
    private(set) var selectedRewriteOffset: Int?
    var rewriteSelectionErrorMessage: String?
    var ttsErrorMessage: String?
    var isTTSSpeaking = false
    var isTTSPaused = false

    /// 睡眠定时剩余秒数；0 表示未启用。UI 只读，倒计时完全由本类驱动。
    private(set) var sleepRemainingSeconds: Int = 0

    /// 本书全部书签与划线的内存副本。currentPageHasBookmark 会被 body 高频求值，
    /// 每次翻页都去 SwiftData 查一遍太亏；写入路径统一 reloadBookmarkCache() 维护一致性。
    private(set) var bookmarkCache: [Bookmark] = []

    // Engines
    let tts = TTSEngine()
    let timer = ReadingTimeTracker()

    /// 进入阅读器前的系统亮度。接管亮度是全局副作用，退出时必须还原成用户原本的值，
    /// 否则用户会带着阅读器的亮度回到桌面。
    private var originalBrightness: CGFloat?

    private var paginateTask: Task<Void, Never>?
    private var verticalPaginationTasks: [Int: Task<Void, Never>] = [:]
    private var verticalPageCache: [Int: [ReaderPage]] = [:]
    private var verticalSnapshots: [Int: ChapterPaginationSnapshot] = [:]
    private var verticalLayout: TextPaginator.Layout?
    private var verticalGenerationID = UUID()
    private var saveTask: Task<Void, Never>?
    private var ttsContinuationTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private var chapterFetchTask: Task<Void, Never>?
    private var loadingChapterID: UUID?

    init(book: Book, context: ModelContext) {
        self.book = book
        self.context = context
        self.settings = Self.loadOrCreateSettings(context: context)
        self.chapters = (book.chapters ?? []).sorted { $0.index < $1.index }
        let resumeIndex: Int
        if book.format == .online {
            if (0..<chapters.count).contains(book.firstUnreadChapterIndex) {
                resumeIndex = book.firstUnreadChapterIndex
            } else if let unread = OnlineLibraryService.firstUnreadIndex(
                totalChapters: chapters.count,
                highestReadIndex: book.highestReadChapterIndex,
                currentIndex: book.currentChapterIndex
            ) {
                resumeIndex = unread
            } else {
                resumeIndex = book.currentChapterIndex
            }
        } else {
            resumeIndex = book.currentChapterIndex
        }
        self.chapterIndex = min(max(0, resumeIndex), max(0, chapters.count - 1))
        if resumeIndex != book.currentChapterIndex { book.currentPageOffset = 0 }
        timer.attach(book: book, context: context)
        configureTTS()
        reloadBookmarkCache()
        tts.onFinishUtterance = { [weak self] in
            self?.syncTTSFlags()
            self?.handleTTSFinished()
        }
        tts.onBoundary = { [weak self] relativeOffset in
            self?.handleTTSBoundary(relativeOffset: relativeOffset)
        }
        tts.onError = { [weak self] message in
            guard let self else { return }
            self.syncTTSFlags()
            self.showTTSBar = false
            self.ttsErrorMessage = message
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

    var currentVerticalPageID: BookPageID? {
        guard settings.pageTurnMode == .verticalScroll else { return nil }
        return BookPageID(chapterIndex: chapterIndex, pageIndex: pageIndex)
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
        persistProgress(immediate: true)
        applyScreenSettings()
        BookUnderstandingCoordinator.shared.scheduleIfNeeded(book: book, context: context)
        loadCurrentChapterContentIfNeeded(restoreOffset: book.currentPageOffset)
    }

    func onDisappear() {
        cancelPaginationTasks()
        ttsContinuationTask?.cancel()
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        chapterFetchTask?.cancel()
        chapterFetchTask = nil
        sleepRemainingSeconds = 0
        tts.stop()
        timer.stop()
        restoreScreenSettings()
        persistProgress(immediate: true)
        // 阅读器关闭后不再需要这本书的向量索引与锚点常驻内存。
        BookUnderstandingCoordinator.shared.releaseCaches(for: book.id)
    }

    func onScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            timer.start()
            applyScreenSettings()
        case .inactive:
            pauseTimerUnlessListening()
            persistProgress(immediate: true)
        case .background:
            pauseTimerUnlessListening()
            // 常亮与亮度覆盖都是全局状态，退到后台就该交还系统，
            // 否则用户切去别的 App 还得忍受阅读器的亮度和不熄屏。
            // 只在 .background 还原：.inactive 频繁触发（下拉通知中心、来通知横幅），
            // 在那里改亮度会让屏幕一闪一闪。
            restoreScreenSettings()
            persistProgress(immediate: true)
        @unknown default:
            break
        }
    }

    /// App 声明了 UIBackgroundModes=audio，退到后台时 TTS 仍在朗读，
    /// 此时用户确实在"听书"，一律 pause 会让这段时长凭空从统计里消失。
    private func pauseTimerUnlessListening() {
        guard !isTTSSpeaking else { return }
        timer.pause()
    }

    // MARK: - Screen (常亮 / 亮度)

    /// App 当前活跃场景所在的屏幕。
    ///
    /// `UIScreen.main` 在 iOS 16 起已弃用，且在台前调度/外接屏下可能不是用户正在看的那块屏。
    /// 与 ReaderSettingsPanel 里读取系统亮度的方式保持一致。
    private var activeScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
    }

    /// 把 keepScreenOn 与 brightnessOverride 落到系统上。
    /// 只在首次接管亮度时记录原值，重复调用（前后台切换）不会把覆盖值当成"原始亮度"。
    private func applyScreenSettings() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        guard settings.brightnessOverride >= 0, let screen = activeScreen else { return }
        if originalBrightness == nil {
            originalBrightness = screen.brightness
        }
        screen.brightness = CGFloat(min(1, settings.brightnessOverride))
    }

    private func restoreScreenSettings() {
        UIApplication.shared.isIdleTimerDisabled = false
        if let originalBrightness {
            // 退出时场景可能已非 foregroundActive，activeScreen 会是 nil；
            // 此时回退到主屏，否则用户的原始亮度就再也恢复不了了。
            (activeScreen ?? UIScreen.main).brightness = originalBrightness
            self.originalBrightness = nil
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
        if chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           chapter.sourceURL != nil {
            pages = []
            pageIndex = 0
            loadCurrentChapterContentIfNeeded(restoreOffset: restoreOffset)
            return
        }
        let size = pageSize
        guard size.width > 10, size.height > 10 else { return }

        isPaginating = true
        cancelPaginationTasks()

        // chapter 是 SwiftData @Model，不能被后台任务捕获；所有字段先在主 actor 取快照。
        let text = chapter.content
        let chapterID = chapter.id.uuidString
        let richContentData = chapter.richContentData
        let layout = TextPaginator.Layout(
            fontSize: settings.fontSize,
            lineSpacing: settings.lineSpacing,
            margin: settings.pageMargin,
            contentSize: size,
            isDark: settings.backgroundColor == .dark,
            showHeader: settings.showHeader,
            showPageNumber: settings.showPageNumber,
            firstLineIndentChars: settings.firstLineIndentChars,
            paragraphSpacingRatio: settings.paragraphSpacingRatio
        )
        let offsetToRestore = restoreOffset ?? currentPage?.location ?? book.currentPageOffset

        if settings.pageTurnMode == .verticalScroll {
            verticalGenerationID = UUID()
            let generation = verticalGenerationID
            verticalSnapshots = Dictionary(uniqueKeysWithValues: chapters.enumerated().map { index, chapter in
                (
                    index,
                    ChapterPaginationSnapshot(
                        index: index,
                        title: chapter.title,
                        id: chapter.id.uuidString,
                        text: chapter.content,
                        richContentData: chapter.richContentData
                    )
                )
            })
            verticalLayout = layout
            verticalPageCache = [:]
            pages = []
            verticalPages = []
            paginateVerticalChapter(
                chapterIndex,
                generation: generation,
                restoreOffset: offsetToRestore,
                isInitial: true,
                priority: .userInitiated
            )
            return
        }

        verticalPages = []
        verticalPageCache = [:]
        verticalSnapshots = [:]
        verticalLayout = nil

        paginateTask = Task.detached(priority: .userInitiated) {
            let result = TextPaginator.paginate(
                chapterID: chapterID,
                text: text,
                richContentData: richContentData,
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

        // 此处曾经"预加载"邻章，但 TextPaginator 没有缓存，结果被直接丢弃。
        // 那只是在拖动字号滑块时派发几十个无人取消的整章排版任务，纯耗电。
    }

    private func cancelPaginationTasks() {
        paginateTask?.cancel()
        paginateTask = nil
        for task in verticalPaginationTasks.values { task.cancel() }
        verticalPaginationTasks = [:]
    }

    private func paginateVerticalChapter(
        _ index: Int,
        generation: UUID,
        restoreOffset: Int? = nil,
        isInitial: Bool = false,
        priority: TaskPriority = .utility
    ) {
        guard generation == verticalGenerationID,
              verticalPageCache[index] == nil,
              verticalPaginationTasks[index] == nil,
              let snapshot = verticalSnapshots[index],
              let layout = verticalLayout
        else { return }

        let task = Task.detached(priority: priority) { [weak self] in
            let result = TextPaginator.paginate(
                chapterID: snapshot.id,
                text: snapshot.text,
                richContentData: snapshot.richContentData,
                layout: layout
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      generation == self.verticalGenerationID
                else { return }
                self.verticalPaginationTasks[index] = nil
                self.verticalPageCache[index] = result

                if isInitial {
                    self.pages = result
                    self.pageIndex = TextPaginator.pageIndex(
                        forCharacterOffset: restoreOffset ?? 0,
                        in: result
                    )
                }
                self.rebuildVerticalPages()

                if isInitial {
                    self.isPaginating = false
                    self.persistProgress(immediate: false)
                    self.preloadVerticalChapters(around: index)
                }
            }
        }
        verticalPaginationTasks[index] = task
    }

    private func rebuildVerticalPages() {
        guard verticalPageCache[chapterIndex] != nil else {
            verticalPages = []
            return
        }

        var first = chapterIndex
        var last = chapterIndex
        while verticalPageCache[first - 1] != nil { first -= 1 }
        while verticalPageCache[last + 1] != nil { last += 1 }

        verticalPages = (first...last).flatMap { index -> [BookReaderPage] in
            guard let chapterPages = verticalPageCache[index],
                  let snapshot = verticalSnapshots[index]
            else { return [] }
            return chapterPages.map { page in
                BookReaderPage(
                    id: BookPageID(chapterIndex: index, pageIndex: page.id),
                    chapterTitle: snapshot.title,
                    page: page,
                    chapterPageCount: chapterPages.count
                )
            }
        }
    }

    private func preloadVerticalChapters(around index: Int) {
        let generation = verticalGenerationID
        paginateVerticalChapter(index + 1, generation: generation, priority: .userInitiated)
        paginateVerticalChapter(index - 1, generation: generation)
    }

    func preloadVerticalPages(around id: BookPageID) {
        guard settings.pageTurnMode == .verticalScroll,
              let chapterPages = verticalPageCache[id.chapterIndex]
        else { return }

        let generation = verticalGenerationID
        if id.pageIndex >= max(0, chapterPages.count - 4) {
            paginateVerticalChapter(
                id.chapterIndex + 1,
                generation: generation,
                priority: .userInitiated
            )
            paginateVerticalChapter(id.chapterIndex + 2, generation: generation)
        }
        if id.pageIndex <= 3 {
            paginateVerticalChapter(id.chapterIndex - 1, generation: generation)
        }
    }

    // MARK: - Online chapter loading

    func loadCurrentChapterContentIfNeeded(restoreOffset: Int? = nil, force: Bool = false) {
        guard let chapter = currentChapter,
              let chapterURL = chapter.sourceURL,
              !chapterURL.isEmpty else { return }
        if !force, chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let path = chapter.offlineCachePath {
            do {
                chapter.content = try OnlineLibraryService.cachedText(relativePath: path)
                repaginate(restoreOffset: restoreOffset ?? 0)
                return
            } catch {
                chapter.offlineCachePath = nil
                chapter.offlineCachedAt = nil
                chapterLoadError = String(localized: "离线缓存损坏，将尝试重新下载：\(error.localizedDescription)")
            }
        }
        if !force, !chapter.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        if loadingChapterID == chapter.id { return }
        guard let source = resolveOnlineSource() else {
            chapterLoadError = String(localized: "\u{627e}\u{4e0d}\u{5230}\u{8fd9}\u{672c}\u{4e66}\u{5bf9}\u{5e94}\u{7684}\u{4e66}\u{6e90}\u{ff0c}\u{8bf7}\u{91cd}\u{65b0}\u{5bfc}\u{5165}\u{4e66}\u{6e90}\u{540e}\u{91cd}\u{8bd5}\u{3002}")
            return
        }

        chapterFetchTask?.cancel()
        loadingChapterID = chapter.id
        isLoadingChapterContent = true
        isPaginating = true
        chapterLoadError = nil
        let chapterID = chapter.id
        let sourceSnapshot = BookSourceSnapshot(source)
        chapterFetchTask = Task {
            defer {
                if loadingChapterID == chapterID {
                    loadingChapterID = nil
                    isLoadingChapterContent = false
                }
            }
            do {
                let text = try await BookSourceEngine.fetchContent(
                    chapterURL: chapterURL,
                    source: sourceSnapshot,
                    currentBookURL: book.sourceURL
                )
                guard !Task.isCancelled,
                      let target = chapters.first(where: { $0.id == chapterID }) else { return }
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else {
                    throw BookSourceError.empty
                }
                target.content = normalized
                try context.save()
                if currentChapter?.id == chapterID {
                    repaginate(restoreOffset: restoreOffset ?? 0)
                }
            } catch is CancellationError {
                return
            } catch {
                isPaginating = false
                if case BookSourceError.verificationRequired(let url) = error {
                    verificationSource = source
                    verificationRequest = BookSourceVerificationRequest(
                        sourceID: source.id,
                        sourceName: source.name,
                        url: url
                    )
                    chapterLoadError = nil
                } else {
                    chapterLoadError = error.localizedDescription
                }
            }
        }
    }

    func saveVerificationCookies(_ cookieHeader: String) {
        guard let source = verificationSource else { return }
        let trimmed = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var headers: [String: String] = [:]
        if let data = source.headerJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                if let text = value as? String { headers[key] = text }
            }
        }
        headers["Cookie"] = trimmed
        if let data = try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            source.headerJSON = text
        }
        source.enabled = true
        source.isValid = true
        source.lastCheckedAt = Date()
        do {
            try context.save()
        } catch {
            chapterLoadError = String(localized: "无法保存验证凭据：\(error.localizedDescription)")
            return
        }
        verificationRequest = nil
        chapterLoadError = nil
        loadCurrentChapterContentIfNeeded(restoreOffset: book.currentPageOffset, force: true)
    }

    private func resolveOnlineSource() -> BookSource? {
        let all = (try? context.fetch(FetchDescriptor<BookSource>())) ?? []
        if let id = book.bookSourceID, let exact = all.first(where: { $0.id == id }) {
            return exact
        }
        if let name = book.sourceName {
            return all.first { $0.name == name }
        }
        return nil
    }

    // MARK: - Navigation

    func goToPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        if index != pageIndex {
            clearRewriteSelection()
        }
        pageIndex = index
        persistProgress(immediate: false)
    }

    func goToVerticalPage(_ id: BookPageID) {
        guard settings.pageTurnMode == .verticalScroll,
              let target = verticalPages.first(where: { $0.id == id }) else { return }

        if id.chapterIndex != chapterIndex {
            clearRewriteSelection()
            chapterIndex = id.chapterIndex
            book.currentChapterIndex = id.chapterIndex
            pages = verticalPages
                .filter { $0.id.chapterIndex == id.chapterIndex }
                .map(\.page)
            rebuildVerticalPages()
            preloadVerticalChapters(around: id.chapterIndex)
            loadCurrentChapterContentIfNeeded(restoreOffset: 0)
        }
        pageIndex = id.pageIndex
        book.currentPageOffset = target.page.location
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
        clearRewriteSelection()
        chapterIndex = index
        book.currentChapterIndex = index
        book.currentPageOffset = 0
        pageIndex = 0
        if settings.pageTurnMode == .verticalScroll,
           let cachedPages = verticalPageCache[index] {
            pages = cachedPages
            rebuildVerticalPages()
            preloadVerticalChapters(around: index)
            persistProgress(immediate: false)
            showChapterList = false
            return
        }
        pages = []
        repaginate(restoreOffset: 0)
        showChapterList = false
    }

    func nextChapter() {
        guard chapterIndex + 1 < chapters.count else { return }
        goToChapter(chapterIndex + 1)
    }

    func previousChapter(atEnd: Bool = false) {
        guard chapterIndex > 0 else { return }
        let targetChapterIndex = chapterIndex - 1
        // 让 pageIndex 落在最后一页的哨兵值。仅用于内存中的分页定位，
        // 绝不能写进 book.currentPageOffset —— 否则会作为阅读进度落库。
        let restore = atEnd ? (Int.max / 4) : 0
        if settings.pageTurnMode == .verticalScroll,
           let cachedPages = verticalPageCache[targetChapterIndex],
           let target = cachedPages.last {
            clearRewriteSelection()
            chapterIndex = targetChapterIndex
            book.currentChapterIndex = targetChapterIndex
            pages = cachedPages
            pageIndex = atEnd ? target.id : 0
            book.currentPageOffset = atEnd ? target.location : 0
            rebuildVerticalPages()
            preloadVerticalChapters(around: targetChapterIndex)
            persistProgress(immediate: false)
            return
        }
        chapterIndex = targetChapterIndex
        book.currentChapterIndex = targetChapterIndex
        // 落库一个合法偏移；哨兵值只传给 repaginate，分页完成后会写回真实的页起点。
        book.currentPageOffset = 0
        pages = []
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
        guard settings.pageTurnMode != mode else { return }
        let offset = currentPage?.location ?? book.currentPageOffset
        settings.pageTurnMode = mode
        saveSettings()
        repaginate(restoreOffset: offset)
    }

    func setShowHeader(_ isVisible: Bool) {
        settings.showHeader = isVisible
        saveSettings()
        repaginate()
    }

    func setShowPageNumber(_ isVisible: Bool) {
        settings.showPageNumber = isVisible
        saveSettings()
        repaginate()
    }

    func setFirstLineIndent(_ chars: Double) {
        settings.firstLineIndentChars = min(6, max(0, chars))
        saveSettings()
        repaginate()
    }

    func setParagraphSpacing(_ ratio: Double) {
        settings.paragraphSpacingRatio = min(2, max(0, ratio))
        saveSettings()
        repaginate()
    }

    func setKeepScreenOn(_ on: Bool) {
        settings.keepScreenOn = on
        saveSettings()
        // 排版无关，但必须立刻生效：用户拨开关就是为了眼下这一次不熄屏。
        UIApplication.shared.isIdleTimerDisabled = on
    }

    /// - Parameter value: 0...1 的目标亮度；传负数表示交还系统亮度控制。
    func setBrightnessOverride(_ value: Double) {
        settings.brightnessOverride = value < 0 ? -1 : min(1, value)
        saveSettings()
        if settings.brightnessOverride < 0 {
            // 关闭覆盖 = 还原进入阅读器时的亮度，而不是停在当前拖到的值。
            restoreScreenSettings()
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        } else {
            applyScreenSettings()
        }
    }

    func setSleepTimer(minutes: Int) {
        settings.sleepTimerMinutes = max(0, minutes)
        saveSettings()
        restartSleepTimer()
    }

    func setSleepAfterChapter(_ on: Bool) {
        settings.sleepAfterChapter = on
        saveSettings()
    }

    func setTTSRate(_ value: Double) {
        settings.ttsRate = min(2.0, max(0.5, value))
        configureTTS()
        saveSettings()
    }

    func setTTSVoice(_ id: String) {
        settings.ttsVoice = id
        configureTTS()
        saveSettings()
    }

    func setTTSProvider(_ provider: TTSProvider) {
        guard provider != settings.ttsProvider else { return }
        if tts.isSpeaking || tts.isPaused {
            stopTTS()
        }
        settings.ttsProvider = provider
        settings.ttsVoice = NetworkTTSConfig.defaultVoice(for: provider)
        configureTTS()
        saveSettings()
    }

    var availableTTSVoices: [TTSVoiceOption] {
        TTSEngine.availableVoices(for: settings.ttsProvider)
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
        guard NetworkTTSConfig.isConfigured(for: settings.ttsProvider) else {
            ttsErrorMessage = String(
                localized: "请先在 AI 与语音设置中配置 \(settings.ttsProvider.displayName) 并拉取选择模型"
            )
            showTTSBar = false
            return
        }
        ttsContinuationTask?.cancel()
        showTTSBar = true
        let offset = currentPage?.location ?? 0
        configureTTS()
        tts.speak(
            text: chapter.content,
            bookTitle: book.title,
            chapterTitle: chapter.title,
            startOffset: offset
        )
        syncTTSFlags()
        // 定时是"从开始听算起"。续读下一章时 sleepTimerTask 还在跑，
        // 不能重启，否则每换一章都归零，定时永远走不到头。
        if settings.sleepTimerMinutes > 0, sleepTimerTask == nil {
            restartSleepTimer()
        }
    }

    func syncTTSFlags() {
        isTTSSpeaking = tts.isSpeaking
        isTTSPaused = tts.isPaused
    }

    func stopTTS() {
        ttsContinuationTask?.cancel()
        ttsContinuationTask = nil
        cancelSleepTimer()
        tts.stop()
        syncTTSFlags()
        showTTSBar = false
        // 计时器是靠"正在朗读"才被允许在后台继续跑的。朗读一停（典型场景：
        // 用户听着睡着、睡眠定时到点），后台就没人在读了，必须收住，
        // 否则这一夜都会被记进阅读时长。
        if UIApplication.shared.applicationState != .active {
            timer.pause()
        }
    }

    // MARK: - 睡眠定时

    /// 每秒自减一次而不是一次性 sleep 整段：UI 要显示剩余时间，
    /// 且用户随时可能改定时长度，逐秒推进比重算截止时间更好取消。
    private func restartSleepTimer() {
        cancelSleepTimer()
        let minutes = settings.sleepTimerMinutes
        guard minutes > 0 else { return }
        sleepRemainingSeconds = minutes * 60
        sleepTimerTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.sleepRemainingSeconds -= 1
                if self.sleepRemainingSeconds <= 0 { break }
            }
            guard !Task.isCancelled, let self else { return }
            // 到点即停；同时把设置复位，避免下次开始听书又被上一轮的定时掐断。
            self.settings.sleepTimerMinutes = 0
            self.saveSettings()
            self.stopTTS()
        }
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepRemainingSeconds = 0
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
        // "读完本章即停"是一次性意图，触发后复位，避免下次听书莫名其妙只读一章。
        if settings.sleepAfterChapter {
            settings.sleepAfterChapter = false
            saveSettings()
            stopTTS()
            return
        }
        // 本章读完 → 下一章继续
        if chapterIndex + 1 < chapters.count {
            goToChapter(chapterIndex + 1)
            // 等分页完成后自动继续
            ttsContinuationTask?.cancel()
            ttsContinuationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled, self.showTTSBar else { return }
                self.startTTSFromCurrentPage()
            }
        } else {
            showTTSBar = false
        }
    }

    private func configureTTS() {
        tts.configure(
            rate: settings.ttsRate,
            provider: settings.ttsProvider,
            voiceIdentifier: settings.ttsVoice.isEmpty ? nil : settings.ttsVoice
        )
    }


    // MARK: - AI Rewrite

    func updateRewriteSelection(text: String, utf16Offset: Int?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearRewriteSelection()
            return
        }
        selectedRewriteText = text
        selectedRewriteOffset = utf16Offset
    }

    func beginRewriteForSelection() {
        guard !selectedRewriteText.isEmpty, selectedRewriteOffset != nil else { return }
        guard !selectedRewriteText.contains(ChapterRichContent.imagePlaceholder) else {
            rewriteSelectionErrorMessage = String(
                localized: "所选内容包含图片，请只选择图片前后的一段文字"
            )
            clearRewriteSelection()
            return
        }
        showAIRewrite = true
    }

    func clearRewriteSelection() {
        selectedRewriteText = ""
        selectedRewriteOffset = nil
    }

    func applyRewrite(_ application: RewriteApplication) throws {
        guard let chapter = currentChapter else {
            throw RewriteApplyError.noChapter
        }
        let content = chapter.content
        let original = application.originalText
        if let range = closestRange(
            of: original,
            in: content,
            expectedUTF16Offset: application.expectedUTF16Offset
        ) {
            try applyReplace(
                in: chapter,
                range: range,
                rewritten: application.rewrittenText,
                original: original,
                userRequest: application.userRequest,
                style: application.style
            )
            return
        }

        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let trimmedRange = closestRange(
                of: trimmed,
                in: content,
                expectedUTF16Offset: application.expectedUTF16Offset
              ) else {
            throw RewriteApplyError.originalNotFound
        }
        try applyReplace(
            in: chapter,
            range: trimmedRange,
            rewritten: application.rewrittenText,
            original: trimmed,
            userRequest: application.userRequest,
            style: application.style
        )
    }

    /// 兼容旧调用方。
    func applyRewrite(original: String, rewritten: String) throws {
        try applyRewrite(
            RewriteApplication(
                originalText: original,
                rewrittenText: rewritten,
                userRequest: "",
                style: AIConfig.stylePreset,
                expectedUTF16Offset: currentPage?.location
            )
        )
    }

    private func closestRange(
        of needle: String,
        in content: String,
        expectedUTF16Offset: Int?
    ) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        let contentLength = (content as NSString).length
        let needleLength = (needle as NSString).length

        if let expectedUTF16Offset {
            let location = min(max(0, expectedUTF16Offset), contentLength)
            if location + needleLength <= contentLength,
               let exact = Range(
                    NSRange(location: location, length: needleLength),
                    in: content
               ),
               String(content[exact]) == needle {
                return exact
            }
        }

        var best: (range: Range<String.Index>, distance: Int)?
        var searchStart = content.startIndex
        while searchStart < content.endIndex,
              let found = content.range(
                of: needle,
                options: [],
                range: searchStart..<content.endIndex
              ) {
            let offset = content.utf16.distance(
                from: content.startIndex,
                to: found.lowerBound
            )
            let distance = abs(offset - (expectedUTF16Offset ?? 0))
            if best == nil || distance < best!.distance {
                best = (found, distance)
            }
            if expectedUTF16Offset == nil { return found }
            if found.upperBound == content.endIndex { break }
            searchStart = found.upperBound
        }
        return best?.range
    }

    private func applyReplace(
        in chapter: Chapter,
        range: Range<String.Index>,
        rewritten: String,
        original: String,
        userRequest: String,
        style: RewriteStylePreset
    ) throws {
        let previousContent = chapter.content
        let previousRichContentData = chapter.richContentData
        var updatedContent = previousContent
        let replacementRange = NSRange(range, in: previousContent)
        let richContent = ChapterRichContent.decode(previousRichContentData)
        guard richContent?.containsImage(in: replacementRange) != true else {
            throw RewriteApplyError.containsInlineImage
        }
        let utf16Offset = replacementRange.location
        updatedContent.replaceSubrange(range, with: rewritten)
        chapter.content = updatedContent
        if let richContent {
            let adjusted = richContent.adjustingForReplacement(
                range: replacementRange,
                replacementUTF16Length: (rewritten as NSString).length
            )
            chapter.richContentData = adjusted.images.isEmpty ? nil : adjusted.encoded()
        }

        let record = RewriteRecord(
            bookID: book.id,
            chapterID: chapter.id,
            originalText: original,
            rewrittenText: rewritten,
            userRequest: userRequest,
            stylePreset: style,
            originalUTF16Offset: utf16Offset
        )
        context.insert(record)
        do {
            try context.save()
        } catch {
            chapter.content = previousContent
            chapter.richContentData = previousRichContentData
            context.delete(record)
            throw RewriteApplyError.saveFailed(error.localizedDescription)
        }
        trimRewriteHistory()
        try? context.save()

        BookUnderstandingCoordinator.shared.onChapterRewritten(
            bookID: book.id,
            chapterID: chapter.id,
            chapterIndex: chapter.index,
            content: updatedContent
        )
        // 不在此重建全书锚点：onChapterRewritten 已标脏受影响批次并增量更新了向量索引，
        // 锚点重建要跑「全部批次摘要 + 全量锚点提取」两轮 LLM 调用，
        // 推迟到下次打开本书时由 scheduleIfNeeded 统一进行。

        // 尽量保持当前页附近
        let restore = min(utf16Offset, (updatedContent as NSString).length)
        book.currentPageOffset = restore
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
        let previousContent = chapter.content
        let previousRichContentData = chapter.richContentData
        var content = previousContent
        let replacementRange: Range<String.Index>
        if let range = closestRange(
            of: record.rewrittenText,
            in: content,
            expectedUTF16Offset: record.originalUTF16Offset
        ) {
            replacementRange = range
        } else if let range = closestRange(
            of: record.rewrittenText.trimmingCharacters(in: .whitespacesAndNewlines),
            in: content,
            expectedUTF16Offset: record.originalUTF16Offset
        ) {
            replacementRange = range
        } else {
            throw RewriteApplyError.originalNotFound
        }
        let replacementNSRange = NSRange(replacementRange, in: previousContent)
        let previousPageOffset = book.currentPageOffset
        let richContent = ChapterRichContent.decode(previousRichContentData)
        guard richContent?.containsImage(in: replacementNSRange) != true else {
            throw RewriteApplyError.containsInlineImage
        }
        content.replaceSubrange(replacementRange, with: record.originalText)
        chapter.content = content
        if let richContent {
            let adjusted = richContent.adjustingForReplacement(
                range: replacementNSRange,
                replacementUTF16Length: (record.originalText as NSString).length
            )
            chapter.richContentData = adjusted.images.isEmpty ? nil : adjusted.encoded()
        }
        record.isUndone = true
        do {
            try context.save()
        } catch {
            chapter.content = previousContent
            chapter.richContentData = previousRichContentData
            record.isUndone = false
            throw RewriteApplyError.saveFailed(error.localizedDescription)
        }

        BookUnderstandingCoordinator.shared.onChapterRewritten(
            bookID: book.id,
            chapterID: chapter.id,
            chapterIndex: chapter.index,
            content: content
        )
        if chapter.index == chapterIndex {
            let delta = (record.originalText as NSString).length - replacementNSRange.length
            let restoreOffset: Int
            if previousPageOffset >= NSMaxRange(replacementNSRange) {
                restoreOffset = max(0, previousPageOffset + delta)
            } else if previousPageOffset >= replacementNSRange.location {
                restoreOffset = replacementNSRange.location
            } else {
                restoreOffset = previousPageOffset
            }
            book.currentPageOffset = restoreOffset
            repaginate(restoreOffset: restoreOffset)
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

    // MARK: - 书签与划线

    /// 在当前页起始位置打一个位置书签。同一页已有书签时不重复插入。
    func addBookmark() {
        guard let chapter = currentChapter, let page = currentPage else { return }
        guard !currentPageHasBookmark else { return }
        let bookmark = Bookmark(
            bookID: book.id,
            chapterID: chapter.id,
            chapterIndex: chapter.index,
            chapterTitle: chapter.title,
            utf16Location: page.location,
            utf16Length: 0,
            excerpt: makeExcerpt(in: chapter.content, utf16Location: page.location)
        )
        context.insert(bookmark)
        try? context.save()
        reloadBookmarkCache()
    }

    /// - Parameter utf16Offset: 选区在**章节全文**中的起始偏移，与 `ReaderPage.location` 同坐标系。
    func addHighlight(
        text: String,
        utf16Offset: Int,
        color: HighlightColor,
        note: String = ""
    ) {
        guard let chapter = currentChapter else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let content = chapter.content as NSString
        let location = min(max(0, utf16Offset), content.length)
        // 长度按传入原文算，不能用 trimmed —— 渲染层要按这个长度回贴到正文上。
        let length = min((text as NSString).length, content.length - location)
        guard length > 0 else { return }
        let highlight = Bookmark(
            bookID: book.id,
            chapterID: chapter.id,
            chapterIndex: chapter.index,
            chapterTitle: chapter.title,
            utf16Location: location,
            utf16Length: length,
            excerpt: text,
            note: note,
            color: color
        )
        context.insert(highlight)
        try? context.save()
        reloadBookmarkCache()
    }

    /// 当前书的全部书签与划线，按章序、章内位置排序。
    func fetchBookmarks() -> [Bookmark] {
        let bid = book.id
        let descriptor = FetchDescriptor<Bookmark>(
            sortBy: [
                SortDescriptor(\Bookmark.chapterIndex),
                SortDescriptor(\Bookmark.utf16Location)
            ]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.bookID == bid }
    }

    func deleteBookmark(_ bookmark: Bookmark) {
        context.delete(bookmark)
        try? context.save()
        // 缓存里留着已删除的 @Model 会在读属性时崩，删完必须立刻重建。
        reloadBookmarkCache()
    }

    func updateNote(_ bookmark: Bookmark, note: String) {
        bookmark.note = note
        try? context.save()
    }

    func goToBookmark(_ bookmark: Bookmark) {
        // chapterID 才是权威定位；chapterIndex 只作后备，
        // 书籍重新解析后章节数组可能整体位移，按下标跳会跳错章。
        let fallback: Int? = chapters.indices.contains(bookmark.chapterIndex)
            ? bookmark.chapterIndex
            : nil
        guard let target = chapters.firstIndex(where: { $0.id == bookmark.chapterID }) ?? fallback
        else { return }
        let location = max(0, bookmark.utf16Location)
        if target != chapterIndex {
            goToChapter(target)
        }
        book.currentPageOffset = location
        if pages.isEmpty {
            // 跨章跳转时 goToChapter 派发的重排版是按偏移 0 走的，
            // 这里用书签偏移再发一次（内部会取消上一个任务），分页完成后才落在目标页。
            repaginate(restoreOffset: location)
        } else {
            goToPage(TextPaginator.pageIndex(forCharacterOffset: location, in: pages))
        }
        showChapterList = false
    }

    /// 按章号取划线。上下滚动模式会同屏渲染多个章节的页，
    /// 只有当前章的划线不够用。
    func highlights(forChapterIndex index: Int) -> [Bookmark] {
        guard chapters.indices.contains(index) else { return [] }
        let id = chapters[index].id
        return bookmarkCache.filter { $0.chapterID == id && $0.isHighlight }
    }

    /// 供渲染层给正文上色：只返回当前章的划线，位置书签不参与着色。
    func highlightsForCurrentChapter() -> [Bookmark] {
        guard let chapter = currentChapter else { return [] }
        return bookmarkCache.filter { $0.chapterID == chapter.id && $0.isHighlight }
    }

    /// 顶栏书签按钮的实心/空心状态。
    var currentPageHasBookmark: Bool {
        guard let chapter = currentChapter, let page = currentPage else { return false }
        let start = page.location
        let end = max(start + 1, page.location + page.length)
        return bookmarkCache.contains {
            $0.chapterID == chapter.id
                && !$0.isHighlight
                && $0.utf16Location >= start
                && $0.utf16Location < end
        }
    }

    /// 顶栏按钮用：当前页有书签就删掉，没有就加上。
    func toggleBookmarkAtCurrentPage() {
        guard let chapter = currentChapter, let page = currentPage else { return }
        let start = page.location
        let end = max(start + 1, page.location + page.length)
        let existing = bookmarkCache.filter {
            $0.chapterID == chapter.id
                && !$0.isHighlight
                && $0.utf16Location >= start
                && $0.utf16Location < end
        }
        guard existing.isEmpty else {
            for bookmark in existing { context.delete(bookmark) }
            try? context.save()
            reloadBookmarkCache()
            return
        }
        addBookmark()
    }

    /// 缓存只在本类的增删后重建：所有写入都走这里，无需在读取路径上反复查库，
    /// 也避免在 SwiftUI 求值 body 时改状态。
    private func reloadBookmarkCache() {
        bookmarkCache = fetchBookmarks()
    }

    private func makeExcerpt(
        in content: String,
        utf16Location: Int,
        limit: Int = 40
    ) -> String {
        let source = content as NSString
        guard source.length > 0 else { return "" }
        let start = min(max(0, utf16Location), source.length)
        // 多取一些再截：前导空白会被 trim 掉，且 emoji 一个字占两个 UTF-16 单元。
        let length = min(limit * 3, source.length - start)
        guard length > 0 else { return "" }
        // 直接按 UTF-16 下标切会劈开代理对，得对齐到完整字符边界。
        let range = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: start, length: length)
        )
        let raw = source.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(raw.prefix(limit))
    }

    // MARK: - Persist

    func persistProgress(immediate: Bool) {
        book.currentChapterIndex = chapterIndex
        if let page = currentPage {
            book.currentPageOffset = page.location
        }
        book.lastReadAt = Date()
        if book.format == .online {
            book.highestReadChapterIndex = max(book.highestReadChapterIndex, chapterIndex)
            let nextUnread = book.highestReadChapterIndex + 1
            book.firstUnreadChapterIndex = nextUnread < chapters.count ? nextUnread : -1
            book.unreadChapterCount = max(0, chapters.count - nextUnread)
        }
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
    case containsInlineImage
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noChapter: return String(localized: "当前无章节")
        case .originalNotFound: return String(localized: "未在章节中找到原文，请缩短选择范围后重试")
        case .containsInlineImage:
            return String(localized: "所选内容包含图片，请只改写图片前后的一段文字")
        case .saveFailed(let message): return String(localized: "保存改写失败：\(message)")
        }
    }
}
