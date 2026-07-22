import SwiftUI
import SwiftData

struct ReaderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel: ReaderViewModel
    @State private var curlIndex: Int = 0

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

            // 触控层：左/中/右
            if !viewModel.showSettings && !viewModel.showChapterList {
                tapZones
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
        .sheet(isPresented: $viewModel.showAIRewrite) {
            if let chapter = viewModel.currentChapter {
                AIRewriteSheet(
                    pageText: viewModel.currentPage?.attributedText.string ?? chapter.content,
                    chapterContent: chapter.content,
                    chapterTitle: chapter.title,
                    chapterIndex: viewModel.chapterIndex,
                    chapterID: chapter.id,
                    book: viewModel.book,
                    onConfirm: { original, rewritten in
                        try await MainActor.run {
                            try viewModel.applyRewrite(original: original, rewritten: rewritten)
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
        .contextMenu {
            Button {
                viewModel.showAIRewrite = true
            } label: {
                Label(String(localized: "AI 改写"), systemImage: "sparkles")
            }
            Button {
                viewModel.showAIHistory = true
            } label: {
                Label(String(localized: "改写历史"), systemImage: "clock.arrow.circlepath")
            }
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
                onIndexChange: { idx in
                    viewModel.goToPage(idx)
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
            set: { viewModel.goToPage($0) }
        )) {
            ForEach(Array(viewModel.pages.enumerated()), id: \.element.id) { idx, page in
                PageContent(
                    page: page,
                    background: bg,
                    margin: viewModel.settings.pageMargin,
                    pageLabel: "\(idx + 1) / \(viewModel.pages.count)"
                )
                .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var verticalScroller: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.pages.enumerated()), id: \.element.id) { idx, page in
                    PageContent(
                        page: page,
                        background: bg,
                        margin: viewModel.settings.pageMargin,
                        pageLabel: "\(idx + 1) / \(viewModel.pages.count)"
                    )
                    .frame(minHeight: max(viewModel.pageSize.height, 200))
                    .id(idx)
                    .onAppear {
                        if abs(idx - viewModel.pageIndex) > 0 {
                            // 粗略同步进度
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Tap zones

    private var tapZones: some View {
        GeometryReader { geo in
            if viewModel.settings.pageTurnMode == .pageCurl {
                // 仿真翻页：仅中间区域点出菜单，左右交给 UIPageViewController
                HStack(spacing: 0) {
                    Color.clear.frame(width: geo.size.width * 0.28)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.toggleChrome() }
                        .frame(width: geo.size.width * 0.44)
                    Color.clear.frame(width: geo.size.width * 0.28)
                }
            } else {
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.previousPage() }
                        .frame(width: geo.size.width * 0.28)

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.toggleChrome() }
                        .frame(width: geo.size.width * 0.44)

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.nextPage() }
                        .frame(width: geo.size.width * 0.28)
                }
            }
        }
        .opacity(0.01)
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
                    viewModel.showAIRewrite = true
                } label: {
                    Image(systemName: "sparkles")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "AI 改写"))
                .contextMenu {
                    Button {
                        viewModel.showAIRewrite = true
                    } label: {
                        Label(String(localized: "AI 改写本页"), systemImage: "sparkles")
                    }
                    Button {
                        viewModel.showAIHistory = true
                    } label: {
                        Label(String(localized: "改写历史 / 撤销"), systemImage: "clock.arrow.circlepath")
                    }
                }

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
