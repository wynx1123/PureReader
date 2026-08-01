import SwiftUI
import SwiftData

/// 书籍详情页。
///
/// 把 `Book` 里已经存了、但书架上从没露过面的元数据（来源、加入时间、累计阅读时长…）
/// 集中展示。所有动作都通过闭包交给调用方（BookshelfView）执行，
/// 本视图不直接持有 ReaderSession、不写库、不删书。
struct BookDetailSheet: View {
    let book: Book
    let onRead: () -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var showDeleteConfirm = false
    /// 整本缓存进度（nil = 未在缓存）
    @State private var cacheProgress: (done: Int, total: Int)?
    @State private var cacheTask: Task<Void, Never>?
    @State private var cacheResultMessage: String?

    init(
        book: Book,
        onRead: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.book = book
        self.onRead = onRead
        self.onEdit = onEdit
        self.onExport = onExport
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                organizeSection
                sourceSection
                statsSection
                actionSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "书籍详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                        .frame(minWidth: PRTheme.touch, minHeight: PRTheme.touch)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "编辑")) {
                        dismiss()
                        onEdit()
                    }
                    .frame(minWidth: PRTheme.touch, minHeight: PRTheme.touch)
                }
            }
            .confirmationDialog(
                String(localized: "删除《\(book.title)》"),
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "删除"), role: .destructive) {
                    dismiss()
                    onDelete()
                }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                Text(String(localized: "将删除本书及全部章节，且不可恢复。"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 封面与标题

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                BookCoverView(
                    title: book.title,
                    author: book.author,
                    coverData: book.coverImageData,
                    progress: book.progressFraction
                )
                .frame(width: 96)

                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(PRTheme.primaryText)
                        .lineLimit(3)
                    Text(book.author.isEmpty ? String(localized: "佚名") : book.author)
                        .font(.subheadline)
                        .foregroundStyle(PRTheme.secondaryText)
                        .lineLimit(2)
                    Text(book.format.rawValue.uppercased())
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - 分组与标签

    private var organizeSection: some View {
        Section(String(localized: "整理")) {
            LabeledContent(String(localized: "分组"), value: book.groupDisplayName)
            if book.tags.isEmpty {
                LabeledContent(String(localized: "标签"), value: String(localized: "无"))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "标签"))
                        .font(.subheadline)
                    // 标签可能较多，用自动换行的流式排布代替单行 LabeledContent。
                    TagWrap(tags: book.tags)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 来源

    private var sourceSection: some View {
        Section(String(localized: "来源")) {
            LabeledContent(String(localized: "类型"), value: sourceTypeName)
            if book.sourceType == .booksource, let name = book.sourceName, !name.isEmpty {
                LabeledContent(String(localized: "书源"), value: name)
            }
            if let urlText = book.sourceURL, !urlText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "地址"))
                        .font(.subheadline)
                    if let url = URL(string: urlText) {
                        Link(urlText, destination: url)
                            .font(.footnote)
                            .lineLimit(3)
                    } else {
                        Text(urlText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var sourceTypeName: String {
        switch book.sourceType {
        case .local: return String(localized: "本地导入")
        case .url: return String(localized: "链接")
        case .booksource: return String(localized: "书源")
        }
    }

    // MARK: - 阅读数据

    private var statsSection: some View {
        Section(String(localized: "阅读")) {
            LabeledContent(String(localized: "章节数"), value: "\(book.totalChapters)")
            LabeledContent(
                String(localized: "阅读进度"),
                value: "\(Int((book.progressFraction * 100).rounded()))%"
            )
            ProgressView(value: book.progressFraction)
                .tint(Color.accentColor)
                .accessibilityLabel(String(localized: "阅读进度"))
            LabeledContent(
                String(localized: "累计阅读"),
                value: Self.formatDuration(book.totalReadingSeconds)
            )
            LabeledContent(
                String(localized: "最后阅读"),
                value: book.lastReadAt.map(Self.formatDate) ?? String(localized: "尚未开始")
            )
            LabeledContent(
                String(localized: "加入时间"),
                value: Self.formatDate(book.addedAt)
            )
        }
    }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            Button {
                dismiss()
                onRead()
            } label: {
                Label(
                    book.lastReadAt == nil
                        ? String(localized: "开始阅读")
                        : String(localized: "继续阅读"),
                    systemImage: "book"
                )
                .frame(maxWidth: .infinity, minHeight: PRTheme.touch)
                .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)

            if ChapterCacheService.isCacheable(book) {
                cacheButton
            }

            Button {
                dismiss()
                onEdit()
            } label: {
                Label(String(localized: "编辑信息"), systemImage: "pencil")
                    .frame(minHeight: PRTheme.touch)
            }

            Button {
                // 分享面板由书架弹出，必须先收起本页，否则同一视图上的两个 sheet 会冲突。
                dismiss()
                onExport()
            } label: {
                Label(String(localized: "导出 TXT"), systemImage: "square.and.arrow.up")
                    .frame(minHeight: PRTheme.touch)
            }

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label(String(localized: "删除书籍"), systemImage: "trash")
                    .frame(minHeight: PRTheme.touch)
            }
        }
    }

    // MARK: - 整本缓存

    private var cacheButton: some View {
        let total = (book.chapters ?? []).count
        let cached = ChapterCacheService.cachedCount(book)
        return Group {
            if let progress = cacheProgress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(localized: "正在缓存正文…"))
                            .font(.subheadline)
                        Spacer()
                        Text("\(progress.done)/\(progress.total)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Button(String(localized: "取消缓存"), role: .destructive) {
                        cacheTask?.cancel()
                        cacheTask = nil
                        cacheProgress = nil
                    }
                    .font(.subheadline)
                }
                .frame(minHeight: PRTheme.touch)
            } else {
                Button {
                    startCache()
                } label: {
                    Label(
                        cached >= total && total > 0
                            ? String(localized: "已缓存全部章节（\(cached)/\(total)）")
                            : String(localized: "缓存全书（已缓存 \(cached)/\(total)）"),
                        systemImage: "arrow.down.circle"
                    )
                    .frame(minHeight: PRTheme.touch)
                }
                .disabled(cached >= total && total > 0)
            }
        }
        .alert(String(localized: "缓存完成"), isPresented: Binding(
            get: { cacheResultMessage != nil },
            set: { if !$0 { cacheResultMessage = nil } }
        )) {
            Button(String(localized: "好"), role: .cancel) {}
        } message: {
            Text(cacheResultMessage ?? "")
        }
    }

    private func startCache() {
        cacheResultMessage = nil
        let total = (book.chapters ?? []).count
        cacheProgress = (ChapterCacheService.cachedCount(book), total)
        cacheTask = Task { @MainActor in
            let outcome = await ChapterCacheService.cacheAllChapters(
                of: book,
                context: modelContext,
                progress: { done, total in
                    cacheProgress = (done, total)
                },
                shouldCancel: { Task.isCancelled }
            )
            cacheTask = nil
            cacheProgress = nil
            if outcome.failed > 0 {
                cacheResultMessage = String(localized: "成功 \(outcome.cached) 章，失败 \(outcome.failed) 章。失败章节可在阅读时重新加载。")
            } else {
                cacheResultMessage = String(localized: "全部 \(outcome.cached + outcome.skipped) 章已可离线阅读。")
            }
        }
    }

    // MARK: - 格式化

    /// 与统计页 `StatsView.formatDuration` 保持一致的口径。
    static func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 {
            return String(localized: "\(h) 小时 \(m) 分")
        }
        if m > 0 {
            return String(localized: "\(m) 分钟")
        }
        return String(localized: "\(seconds) 秒")
    }

    static func formatDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 标签胶囊的简易自动换行排布。
private struct TagWrap: View {
    let tags: [String]

    var body: some View {
        // iOS 16 起 Layout 协议可用，但这里量级很小，用 flow 布局的等效实现即可。
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
    }
}

/// 从左到右排列、超出宽度自动换行。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
