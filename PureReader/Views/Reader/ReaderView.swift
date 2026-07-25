import SwiftUI
import SwiftData

struct ReaderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel: ReaderViewModel
    @State private var curlIndex: Int = 0
    @State private var verticalPageID: BookPageID?

    init(book: Book, context: ModelContext) {
        _viewModel = State(initialValue: ReaderViewModel(book: book, context: context))
    }

    private var bg: BackgroundType { viewModel.settings.backgroundColor }

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
        .alert(String(localized: "听书失败"), isPresented: Binding(
            get: { viewModel.ttsErrorMessage != nil },
            set: { if !$0 { viewModel.ttsErrorMessage = nil } }
        )) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(viewModel.ttsErrorMessage ?? "")
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
                    guard fraction >= 0.28, fraction <= 0.72 else { return }
                    viewModel.toggleChrome()
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
            guard !newValue.isEmpty else { return }
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

    private func handlePageTap(_ fraction: CGFloat) {
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
            HStack {
                Spacer()
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
        NavigationStack {
            List {
                ForEach(Array(viewModel.chapters.enumerated()), id: \.element.id) { idx, chapter in
                    Button {
                        viewModel.goToChapter(idx)
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer()
                            if idx == viewModel.chapterIndex {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle(String(localized: "目录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) {
                        viewModel.showChapterList = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
