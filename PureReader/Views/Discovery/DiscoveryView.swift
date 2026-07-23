import SwiftUI
import SwiftData

struct DiscoveryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookSource.weight, order: .reverse) private var sources: [BookSource]
    @State private var viewModel = DiscoveryViewModel()
    @State private var showSourceManager = false
    @State private var detailItem: SourceSearchResult?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isSearching {
                    ProgressView(String(localized: "搜索中…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.results.isEmpty {
                    emptyState
                } else {
                    resultsList
                }
            }
            .navigationTitle(String(localized: "发现"))
            .searchable(text: $viewModel.keyword, prompt: String(localized: "搜索书名 / 作者"))
            .onSubmit(of: .search) {
                viewModel.search(sources: sources)
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
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "搜索")) {
                        viewModel.search(sources: sources)
                    }
                    .disabled(viewModel.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showSourceManager) {
                BookSourceManagerView()
            }
            .sheet(item: $detailItem) { item in
                SearchDetailSheet(item: item, sources: sources, viewModel: viewModel)
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
            .onAppear {
                BookSourceImporter.seedBuiltInIfNeeded(context: modelContext)
            }
            .overlay {
                if viewModel.isAdding {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(viewModel.statusMessage ?? String(localized: "处理中…"))
                                .font(.subheadline)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        let enabledCount = sources.filter { $0.enabled && $0.isValid }.count
        return ContentUnavailableView {
            Label(
                enabledCount > 0
                    ? String(localized: "发现书籍")
                    : String(localized: "暂无可用书源"),
                systemImage: enabledCount > 0 ? "magnifyingglass" : "server.rack"
            )
        } description: {
            if let status = viewModel.statusMessage {
                Text(status)
            } else if sources.isEmpty {
                Text(String(localized: "尚未安装书源，请先导入书源 JSON。"))
            } else if enabledCount == 0 {
                Text(String(localized: "已安装 \(sources.count) 个书源，但没有可用于搜索的书源。脚本型书源会为安全起见自动停用；重新导入可重新评估兼容性。"))
            } else {
                Text(String(localized: "已启用 \(enabledCount) 个书源。输入关键词并点击搜索，不会自动展示推荐书库。"))
            }
        } actions: {
            Button(String(localized: "管理书源")) {
                showSourceManager = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var resultsList: some View {
        List {
            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.results) { item in
                Button {
                    detailItem = item
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        HStack {
                            if !item.author.isEmpty {
                                Text(item.author)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.sourceName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        if !item.intro.isEmpty {
                            Text(item.intro)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Detail

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
                    LabeledContent(String(localized: "书名"), value: item.name)
                    if !item.author.isEmpty {
                        LabeledContent(String(localized: "作者"), value: item.author)
                    }
                    LabeledContent(String(localized: "书源"), value: item.sourceName)
                    if !item.intro.isEmpty {
                        Text(item.intro)
                            .font(.body)
                    }
                }

                Section(String(localized: "目录预览")) {
                    if viewModel.isLoadingTOC {
                        ProgressView()
                    } else if viewModel.tocChapters.isEmpty {
                        Text(String(localized: "暂无目录"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(viewModel.tocChapters.prefix(40))) { ch in
                            Text(ch.title)
                                .font(.subheadline)
                        }
                        if viewModel.tocChapters.count > 40 {
                            Text(String(localized: "共 \(viewModel.tocChapters.count) 章…"))
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
                            await viewModel.addToBookshelf(
                                item: item,
                                sources: sources,
                                context: modelContext
                            )
                            if viewModel.errorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(viewModel.isAdding)
                }
            }
            .task {
                await viewModel.loadTOC(for: item, sources: sources)
            }
        }
    }
}
