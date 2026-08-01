import SwiftUI
import SwiftData

struct DiscoveryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookSource.weight, order: .reverse) private var sources: [BookSource]
    @State private var viewModel = DiscoveryViewModel()
    @State private var showSourceManager = false
    @State private var detailItem: SourceSearchResult?

    private var isSearchMode: Bool {
        !viewModel.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.isSearching
            || !viewModel.results.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSearchMode {
                    searchContent
                } else {
                    discoveryContent
                }
            }
            .navigationTitle(String(localized: "发现"))
            .searchable(text: $viewModel.keyword, prompt: String(localized: "搜索书名 / 作者"))
            .onSubmit(of: .search) {
                viewModel.search(sources: sources)
            }
            .onChange(of: viewModel.keyword) { _, value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    viewModel.results = []
                    viewModel.errorMessage = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSourceManager = true
                    } label: {
                        Image(systemName: "server.rack")
                    }
                    .accessibilityLabel(String(localized: "书源管理"))
                }
            }
            .sheet(isPresented: $showSourceManager, onDismiss: {
                viewModel.loadDiscovery(sources: sources, force: true)
            }) {
                BookSourceManagerView()
            }
            .sheet(item: $detailItem) { item in
                SearchDetailSheet(item: item, sources: sources, viewModel: viewModel)
            }
            .sheet(item: $viewModel.verificationRequest) { request in
                if let source = sources.first(where: { $0.id == request.sourceID }) {
                    BookSourceVerificationView(
                        request: request,
                        headerJSON: source.headerJSON,
                        onComplete: { cookie in
                            viewModel.saveVerificationCookies(cookie, for: source, context: modelContext)
                        }
                    )
                } else {
                    ContentUnavailableView(
                        String(localized: "书源已不存在"),
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
            .alert(
                String(localized: "提示"),
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button(String(localized: "好"), role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .task {
                BookSourceImporter.seedBuiltInIfNeeded(context: modelContext)
                viewModel.loadDiscovery(sources: sources)
            }
            .onChange(of: sources.count) { _, _ in
                viewModel.loadDiscovery(sources: sources, force: true)
            }
            .overlay {
                if viewModel.isAdding {
                    processingOverlay
                }
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if viewModel.isSearching {
            ProgressView(String(localized: "正在搜索多个书源…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.results.isEmpty {
            ContentUnavailableView.search(text: viewModel.keyword)
        } else {
            resultsList(viewModel.results, ranked: false)
        }
    }

    private var discoveryContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                categoryBar

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(viewModel.selectedCategory?.isRanking == true
                             ? String(localized: "书源排行榜")
                             : String(localized: "分类书库"))
                            .font(.title2.bold())
                        Text(viewModel.selectedCategory?.title ?? String(localized: "推荐"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        viewModel.loadDiscovery(sources: sources, force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(String(localized: "刷新发现页"))
                }
                .padding(.horizontal, 16)

                if viewModel.isLoadingDiscovery {
                    ProgressView(String(localized: "正在从书源拉取书库…"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if viewModel.discoveryResults.isEmpty {
                    discoveryEmptyState
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.discoveryResults.enumerated()), id: \.element.id) { index, item in
                            Button {
                                detailItem = item
                            } label: {
                                DiscoveryBookRow(
                                    item: item,
                                    rank: viewModel.selectedCategory?.isRanking == true ? index + 1 : nil
                                )
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 88)
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12)
                }

                if let status = viewModel.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable {
            viewModel.loadDiscovery(sources: sources, force: true)
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.categories) { category in
                    Button {
                        viewModel.selectCategory(category, sources: sources)
                    } label: {
                        Text(category.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(viewModel.selectedCategoryID == category.id ? Color.white : Color.primary)
                            .padding(.horizontal, 15)
                            .frame(height: 36)
                            .background(
                                viewModel.selectedCategoryID == category.id
                                    ? Color.accentColor
                                    : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var discoveryEmptyState: some View {
        let enabledCount = sources.filter { $0.enabled && $0.isValid }.count
        return ContentUnavailableView {
            Label(
                enabledCount > 0
                    ? String(localized: "暂未拉取到书籍")
                    : String(localized: "暂无可用书源"),
                systemImage: enabledCount > 0 ? "books.vertical" : "server.rack"
            )
        } description: {
            if let status = viewModel.statusMessage {
                Text(status)
            } else if sources.isEmpty {
                Text(String(localized: "尚未安装书源，请先导入书源 JSON。"))
            } else if enabledCount == 0 {
                Text(String(localized: "已安装 \(sources.count) 个书源，但没有可用于搜索的书源。脚本型书源会为安全起见自动停用；重新导入可重新评估兼容性。"))
            } else {
                Text(String(localized: "切换分类、刷新，或到书源管理检查可用性。"))
            }
        } actions: {
            Button(String(localized: "管理书源")) { showSourceManager = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func resultsList(_ items: [SourceSearchResult], ranked: Bool) -> some View {
        List {
            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    detailItem = item
                } label: {
                    DiscoveryBookRow(item: item, rank: ranked ? index + 1 : nil)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(viewModel.statusMessage ?? String(localized: "处理中…"))
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct DiscoveryBookRow: View {
    let item: SourceSearchResult
    let rank: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let rank {
                Text("\(rank)")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(rank <= 3 ? Color.orange : Color.secondary)
                    .frame(width: 24, alignment: .center)
                    .padding(.top, 22)
            }

            CoverView(url: item.coverURL, width: 58, height: 78)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !item.author.isEmpty {
                        Text(item.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(item.sourceName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .lineLimit(1)
                }
                if !item.intro.isEmpty {
                    Text(item.intro)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct SearchDetailSheet: View {
    let item: SourceSearchResult
    let sources: [BookSource]
    @Bindable var viewModel: DiscoveryViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DiscoveryBookRow(item: item, rank: nil)
                    if !item.intro.isEmpty {
                        Text(item.intro)
                            .font(.body)
                    }
                }

                Section(String(localized: "目录预览")) {
                    if viewModel.isLoadingTOC {
                        HStack {
                            ProgressView()
                            Text(String(localized: "正在获取目录…"))
                        }
                    } else if viewModel.tocChapters.isEmpty {
                        Text(String(localized: "暂无目录"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(viewModel.tocChapters.prefix(60))) { chapter in
                            Text(chapter.title).font(.subheadline)
                        }
                        if viewModel.tocChapters.count > 60 {
                            Text(String(localized: "共 \(viewModel.tocChapters.count) 章，加入书架后可查看完整目录"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "书籍详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "加入书架")) {
                        Task {
                            await viewModel.addToBookshelf(item: item, sources: sources, context: modelContext)
                            if viewModel.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(viewModel.isAdding || viewModel.isLoadingTOC)
                }
            }
            .task {
                await viewModel.loadTOC(for: item, sources: sources)
            }
        }
    }
}
