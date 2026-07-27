import SwiftUI
import SwiftData

/// 一次阅读会话。
///
/// ViewModel 在这里创建，且只创建一次；`ReaderView` 本身只持有引用。
/// 这样即使 SwiftUI 反复重建 `ReaderView` struct，也不会重复构造 `TTSEngine`。
@MainActor
final class ReaderSession: Identifiable {
    let id: PersistentIdentifier
    let viewModel: ReaderViewModel

    init(book: Book, context: ModelContext) {
        self.id = book.persistentModelID
        self.viewModel = ReaderViewModel(book: book, context: context)
    }
}

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // 只持有引用，不负责创建 —— 见 ReaderSession。
    @Bindable private var viewModel: ReaderViewModel

    @State private var curlIndex: Int = 0
    @State private var verticalPageID: BookPageID?
    @State private var showBookmarks = false
    @State private var chapterListReversed = false

    init(session: ReaderSession) {
        self._viewModel = Bindable(session.viewModel)
    }

    private var bg: BackgroundType { viewModel.settings.backgroundColor }

    /// 当前章的划线快照。Bookmark 是 @Model，不能直接下发给渲染层，
    /// 在这里一次性转成值类型。
    private var currentHighlights: [HighlightSpan] {
        HighlightSpan.spans(from: viewModel.highlightsForCurrentChapter())
    }

    var body: some View {
        ZStack {
            ReaderTextureBackground(type: bg)

            contentLayer
                .opacity(viewModel.isPaginating && viewModel.pages.isEmpty ? 0.35 : 1)

            if viewModel.isPaginating && viewModel.pages.isEmpty {
                ProgressView()
                    .tint(Color.readerForeground(bg))
            }

            if !viewModel.selectedRewriteText.isEmpty {
                rewriteSelectionAction
            }

            // 顶部/底部 Chrome
            VStack(spacing: 0) {
                if viewModel.chromeVisible {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if viewModel.showTTSBar {
                    TTSControlBar(viewModel: viewModel, background: bg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if viewModel.chromeVisible {
                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .foregroundStyle(Color.readerForeground(bg))
        .statusBarHidden(!viewModel.chromeVisible)
        .navigationBarHidden(true)
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: scenePhase) { _, phase in
            viewModel.onScenePhase(phase)
        }
        .sheet(isPresented: $viewModel.showSettings) {
            ReaderSettingsPanel(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showChapterList) {
            chapterListSheet
        }
        .sheet(item: $viewModel.verificationRequest) { request in
            if let source = viewModel.verificationSource {
                BookSourceVerificationView(
                    request: request,
                    headerJSON: source.headerJSON,
                    onComplete: { cookie in viewModel.saveVerificationCookies(cookie) }
                )
            } else {
                ContentUnavailableView(
                    String(localized: "\u{4e66}\u{6e90}\u{5df2}\u{4e0d}\u{5b58}\u{5728}"),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .sheet(isPresented: $viewModel.showAIRewrite, onDismiss: {
            viewModel.clearRewriteSelection()
        }) {
            if let chapter = viewModel.currentChapter {
                AIRewriteSheet(
                    pageText: viewModel.selectedRewriteText,
                    pageUTF16Offset: viewModel.selectedRewriteOffset ?? 0,
                    chapterContent: chapter.content,
                    chapterTitle: chapter.title,
                    chapterIndex: viewModel.chapterIndex,
                    chapterID: chapter.id,
                    book: viewModel.book,
                    onConfirm: { application in
                        try await MainActor.run {
                            try viewModel.applyRewrite(application)
                        }
                    }
                )
            } else {
                Text(String(localized: "无章节内容"))
                    .padding()
            }
        }
        .sheet(isPresented: $viewModel.showAIHistory) {
            RewriteHistoryView(viewModel: viewModel)
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarkListView(viewModel: viewModel)
        }
        .alert(String(localized: "听书失败"), isPresented: Binding(
            get: { viewModel.ttsErrorMessage != nil },
            set: { if !$0 { viewModel.ttsErrorMessage = nil } }
        )) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(viewModel.ttsErrorMessage ?? "")
        }
        .alert(String(localized: "无法改写"), isPresented: Binding(
            get: { viewModel.rewriteSelectionErrorMessage != nil },
            set: { if !$0 { viewModel.rewriteSelectionErrorMessage = nil } }
        )) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(viewModel.rewriteSelectionErrorMessage ?? "")
        }
        .alert(String(localized: "\u{7ae0}\u{8282}\u{52a0}\u{8f7d}\u{5931}\u{8d25}"), isPresented: Binding(
            get: { viewModel.chapterLoadError != nil },
            set: { if !$0 { viewModel.chapterLoadError = nil } }
        )) {
            Button(String(localized: "\u{91cd}\u{8bd5}")) {
                viewModel.loadCurrentChapterContentIfNeeded(
                    restoreOffset: viewModel.book.currentPageOffset,
                    force: true
                )
            }
            Button(String(localized: "\u{53d6}\u{6d88}"), role: .cancel) {}
        } message: {
            Text(viewModel.chapterLoadError ?? "")
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        viewModel.updatePageSize(geo.size)
                    }
                    .onChange(of: geo.size) { _, size in
                        viewModel.updatePageSize(size)
                    }
            }
        }
    }

    // MARK: - Content modes

    @ViewBuilder
    private var contentLayer: some View {
        switch viewModel.settings.pageTurnMode {
        case .scroll:
            horizontalPager
        case .pageCurl:
            PageCurlView(
                pages: viewModel.pages,
                pageIndex: $curlIndex,
                background: bg,
                margin: viewModel.settings.pageMargin,
                bookTitle: viewModel.book.title,
                chapterTitle: viewModel.currentChapter?.title ?? "",
                showHeader: viewModel.settings.showHeader,
                showPageNumber: viewModel.settings.showPageNumber,
                canGoToPreviousChapter: viewModel.chapterIndex > 0,
                canGoToNextChapter: viewModel.chapterIndex + 1 < viewModel.chapters.count,
                highlights: currentHighlights,
                onIndexChange: { idx in
                    viewModel.goToPage(idx)
                },
                onPreviousChapter: {
                    viewModel.previousChapter(atEnd: true)
                },
                onNextChapter: {
                    viewModel.nextChapter()
                },
                onSelection: handleSelection,
                onTap: { fraction in
                    // 仿真翻页此前只响应中间区域，点两侧完全没反应，容易被当成失灵。
                    // 这里改为与「左右滑动」一致的三段分区：点两侧翻页、点中间呼出菜单。
                    // curlIndex 由 onChange(of: viewModel.pageIndex) 同步，
                    // UIPageViewController 会带卷曲动画跟随。
                    if fraction < 0.28 {
                        viewModel.previousPage()
                    } else if fraction > 0.72 {
                        viewModel.nextPage()
                    } else {
                        viewModel.toggleChrome()
                    }
                }
            )
            .onChange(of: viewModel.pageIndex) { _, new in
                curlIndex = new
            }
            .onAppear { curlIndex = viewModel.pageIndex }

        case .verticalScroll:
            verticalScroller
        }
    }

    private var horizontalPager: some View {
        TabView(selection: Binding(
            get: { viewModel.pageIndex },
            set: { newValue in
                if newValue < 0 {
                    viewModel.previousChapter(atEnd: true)
                } else if newValue >= viewModel.pages.count {
                    viewModel.nextChapter()
                } else {
                    viewModel.goToPage(newValue)
                }
            }
        )) {
            if viewModel.chapterIndex > 0 {
                chapterBoundaryPage(
                    title: viewModel.chapters[viewModel.chapterIndex - 1].title,
                    systemImage: "chevron.left.2"
                )
                .tag(-1)
            }

            ForEach(Array(viewModel.pages.enumerated()), id: \.element.id) { idx, page in
                PageContent(
                    page: page,
                    background: bg,
                    margin: viewModel.settings.pageMargin,
                    bookTitle: viewModel.book.title,
                    chapterTitle: viewModel.currentChapter?.title ?? "",
                    pageLabel: "\(idx + 1) / \(viewModel.pages.count)",
                    showHeader: viewModel.settings.showHeader,
                    showPageNumber: viewModel.settings.showPageNumber,
                    highlights: currentHighlights,
                    onSelection: handleSelection,
                    onTap: handlePageTap
                )
                .tag(idx)
            }

            if viewModel.chapterIndex + 1 < viewModel.chapters.count {
                chapterBoundaryPage(
                    title: viewModel.chapters[viewModel.chapterIndex + 1].title,
                    systemImage: "chevron.right.2"
                )
                .tag(viewModel.pages.count)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .id(viewModel.currentChapter?.id)
    }

    private var verticalScroller: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.verticalPages) { item in
                    PageContent(
                        page: item.page,
                        background: bg,
                        margin: viewModel.settings.pageMargin,
                        bookTitle: viewModel.book.title,
                        chapterTitle: item.chapterTitle,
                        pageLabel: "\(item.id.pageIndex + 1) / \(item.chapterPageCount)",
                        showHeader: viewModel.settings.showHeader,
                        showPageNumber: viewModel.settings.showPageNumber,
                        // 纵向模式同屏可见多个章节，按该页所属章取划线。
                        highlights: HighlightSpan.spans(
                            from: viewModel.highlights(forChapterIndex: item.id.chapterIndex)
                        ),
                        onSelection: { text, offset in
                            viewModel.goToVerticalPage(item.id)
                            handleSelection(text, offset)
                        },
                        onTap: { fraction in
                            viewModel.goToVerticalPage(item.id)
                            handlePageTap(fraction)
                        }
                    )
                    .frame(height: max(viewModel.pageSize.height, 200))
                    .id(item.id)
                    .onAppear {
                        viewModel.preloadVerticalPages(around: item.id)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollPosition(id: $verticalPageID)
        .onAppear { verticalPageID = viewModel.currentVerticalPageID }
        .onChange(of: verticalPageID) { _, newValue in
            if let newValue, newValue != viewModel.currentVerticalPageID {
                viewModel.goToVerticalPage(newValue)
            }
        }
        .onChange(of: viewModel.currentVerticalPageID) { _, newValue in
            if verticalPageID != newValue {
                verticalPageID = newValue
            }
        }
        .onChange(of: viewModel.verticalPages) { _, newValue in
            guard verticalPageID == nil, !newValue.isEmpty else { return }
            verticalPageID = viewModel.currentVerticalPageID
        }
    }

    private func chapterBoundaryPage(title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color.readerSecondary(bg))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(viewModel.settings.pageMargin.edgeInset)
    }

    // MARK: - Reading interactions

    private func handleSelection(_ text: String, _ offset: Int) {
        viewModel.updateRewriteSelection(text: text, utf16Offset: offset)
    }

    /// 用当前选区新建划线。选区状态与 AI 改写共用同一套（文本 + 章内绝对偏移）。
    private func addHighlight(color: HighlightColor) {
        guard let offset = viewModel.selectedRewriteOffset else { return }
        viewModel.addHighlight(
            text: viewModel.selectedRewriteText,
            utf16Offset: offset,
            color: color
        )
        viewModel.clearRewriteSelection()
    }

    /// 点击翻页的横向分区：左 28% 上一页、右 28% 下一页、中间呼出菜单。
    ///
    /// 只在「左右滑动」模式下启用。上下滚动模式若也接这套分区，用户滑动时
    /// 手指落在屏幕两侧就会被判成翻页，与滚动手势语义冲突且极易误触。
    private func handlePageTap(_ fraction: CGFloat) {
        guard viewModel.settings.pageTurnMode == .scroll else {
            viewModel.toggleChrome()
            return
        }
        if fraction < 0.28 {
            viewModel.previousPage()
        } else if fraction > 0.72 {
            viewModel.nextPage()
        } else {
            viewModel.toggleChrome()
        }
    }

    private var rewriteSelectionAction: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Spacer()

                // 划线不依赖 API Key，是选中文字后唯一零门槛的动作，放在改写左侧。
                Menu {
                    ForEach(HighlightColor.allCases) { color in
                        Button {
                            addHighlight(color: color)
                        } label: {
                            Label(color.displayName, systemImage: "highlighter")
                        }
                    }
                } label: {
                    Label(String(localized: "划线"), systemImage: "highlighter")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.beginRewriteForSelection()
                } label: {
                    Label(String(localized: "AI 改写"), systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, viewModel.chromeVisible || viewModel.showTTSBar ? 132 : 20)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(String(localized: "返回"))

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(viewModel.currentChapter?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(Color.readerSecondary(bg))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                viewModel.toggleBookmarkAtCurrentPage()
            } label: {
                // 实心/空心区分当前页是否已加书签，省去再点开列表确认。
                Image(systemName: viewModel.currentPageHasBookmark ? "bookmark.fill" : "bookmark")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(
                viewModel.currentPageHasBookmark
                    ? String(localized: "取消书签")
                    : String(localized: "添加书签")
            )

            Button {
                showBookmarks = true
            } label: {
                Image(systemName: "text.badge.star")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(String(localized: "书签与划线"))

            Button {
                viewModel.showChapterList = true
            } label: {
                Image(systemName: "list.bullet")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(String(localized: "目录"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if viewModel.pages.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(viewModel.pageIndex) },
                        set: { viewModel.goToPage(Int($0.rounded())) }
                    ),
                    in: 0...Double(max(viewModel.pages.count - 1, 1)),
                    step: 1
                )
                .tint(.accentColor)
                .padding(.horizontal, 16)
            }

            Text(viewModel.progressText)
                .font(.caption2)
                .foregroundStyle(Color.readerSecondary(bg))

            HStack(spacing: 28) {
                Button {
                    viewModel.previousChapter()
                } label: {
                    Image(systemName: "chevron.left.2")
                        .frame(width: 44, height: 44)
                }
                .disabled(viewModel.chapterIndex <= 0)

                Button {
                    viewModel.showSettings = true
                } label: {
                    Image(systemName: "textformat.size")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "阅读设置"))

                Button {
                    viewModel.showAIHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "改写历史"))

                Button {
                    viewModel.startTTSFromCurrentPage()
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "听书"))

                Button {
                    viewModel.nextChapter()
                } label: {
                    Image(systemName: "chevron.right.2")
                        .frame(width: 44, height: 44)
                }
                .disabled(viewModel.chapterIndex + 1 >= viewModel.chapters.count)
            }
        }
        .padding(.bottom, 8)
        .padding(.top, 6)
        .background(.ultraThinMaterial)
    }

    private var chapterListSheet: some View {
        let normal = Array(viewModel.chapters.enumerated())
        let displayed = chapterListReversed ? Array(normal.reversed()) : normal
        return NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(displayed, id: \.element.id) { index, chapter in
                        Button {
                            viewModel.goToChapter(index)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chapter.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(String(localized: "\u{7b2c} \(index + 1) \u{7ae0}"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if index == viewModel.chapterIndex {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .id(chapter.id)
                    }
                }
                .onAppear { scrollToCurrentChapter(proxy) }
                .onChange(of: chapterListReversed) { _, _ in
                    scrollToCurrentChapter(proxy)
                }
            }
            .navigationTitle(String(localized: "\u{76ee}\u{5f55}"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "\u{5173}\u{95ed}")) {
                        viewModel.showChapterList = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        chapterListReversed.toggle()
                    } label: {
                        Label(
                            chapterListReversed ? String(localized: "\u{6b63}\u{5e8f}") : String(localized: "\u{5012}\u{5e8f}"),
                            systemImage: chapterListReversed ? "arrow.up" : "arrow.down"
                        )
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func scrollToCurrentChapter(_ proxy: ScrollViewProxy) {
        guard let chapterID = viewModel.currentChapter?.id else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(chapterID, anchor: .center)
        }
    }
}
