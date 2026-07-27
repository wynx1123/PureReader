import SwiftUI
import SwiftData

extension HighlightColor {
    /// 正文划线底色。
    ///
    /// 用低不透明度的实色而不是系统语义色：正文背景从纯白一直到夜间的近黑，
    /// 只有半透明底色才能在两端都保证文字对比度不被压掉。
    var tint: Color {
        switch self {
        case .yellow: return Color(red: 1.00, green: 0.84, blue: 0.25).opacity(0.35)
        case .green: return Color(red: 0.36, green: 0.84, blue: 0.45).opacity(0.35)
        case .blue: return Color(red: 0.30, green: 0.66, blue: 1.00).opacity(0.35)
        case .pink: return Color(red: 1.00, green: 0.45, blue: 0.66).opacity(0.35)
        }
    }

    /// 列表左侧的颜色条。这里不叠在文字下方，浓度拉高才辨得出是哪一种颜色。
    var swatch: Color {
        switch self {
        case .yellow: return Color(red: 0.98, green: 0.74, blue: 0.08)
        case .green: return Color(red: 0.20, green: 0.72, blue: 0.33)
        case .blue: return Color(red: 0.11, green: 0.52, blue: 0.95)
        case .pink: return Color(red: 0.93, green: 0.29, blue: 0.53)
        }
    }
}

/// 书签与划线列表：分类浏览、跳转、编辑笔记、删除。
struct BookmarkListView: View {
    @Bindable var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var items: [Bookmark] = []
    @State private var filter: Filter = .all
    /// 正在编辑笔记的目标。删除时必须一并清空，否则 alert 会去读已被 SwiftData 删掉的对象。
    @State private var editingBookmark: Bookmark?
    @State private var noteDraft = ""

    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case bookmark
        case highlight

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return String(localized: "全部")
            case .bookmark: return String(localized: "书签")
            case .highlight: return String(localized: "划线")
            }
        }
    }

    private var filtered: [Bookmark] {
        switch filter {
        case .all: return items
        case .bookmark: return items.filter { !$0.isHighlight }
        case .highlight: return items.filter(\.isHighlight)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(String(localized: "分类"), selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if filtered.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered, id: \.persistentModelID) { bookmark in
                            row(bookmark)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        delete(bookmark)
                                    } label: {
                                        Label(String(localized: "删除"), systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(String(localized: "书签与划线"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
            }
            .onAppear { reload() }
            .alert(String(localized: "笔记"), isPresented: Binding(
                get: { editingBookmark != nil },
                set: { if !$0 { editingBookmark = nil } }
            )) {
                TextField(String(localized: "写点什么…"), text: $noteDraft)
                Button(String(localized: "取消"), role: .cancel) {
                    editingBookmark = nil
                }
                Button(String(localized: "保存")) {
                    if let target = editingBookmark {
                        viewModel.updateNote(
                            target,
                            note: noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    editingBookmark = nil
                    reload()
                }
            } message: {
                Text(editingBookmark?.excerpt ?? "")
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ bookmark: Bookmark) -> some View {
        HStack(alignment: .top, spacing: 10) {
            marker(bookmark)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bookmark.chapterTitle.isEmpty
                         ? String(localized: "第 \(bookmark.chapterIndex + 1) 章")
                         : bookmark.chapterTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(bookmark.createdAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if bookmark.excerpt.isEmpty {
                    Text(String(localized: "（无摘录）"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(bookmark.excerpt)
                        .font(.footnote)
                        .lineLimit(4)
                }

                noteArea(bookmark)
            }
        }
        .padding(.vertical, 4)
        // 整行可点，命中区域比只让摘录可点大得多；
        // 笔记区是独立 Button，落在它上面的点击由它优先处理，不会误跳转。
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { jump(to: bookmark) }
    }

    /// 两类条目共用一列定宽标记，缩进对齐才不会在长列表里显得参差。
    @ViewBuilder
    private func marker(_ bookmark: Bookmark) -> some View {
        Group {
            if bookmark.isHighlight {
                // 划线用整条色带（长度即条目高度），位置书签用图标，一眼可分。
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(bookmark.color.swatch)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel(
                        Text(String(localized: "划线颜色：\(bookmark.color.displayName)"))
                    )
            } else {
                Image(systemName: "bookmark.fill")
                    .font(.footnote)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(Text(String(localized: "书签")))
            }
        }
        .frame(width: 14)
    }

    @ViewBuilder
    private func noteArea(_ bookmark: Bookmark) -> some View {
        // Spacer 放在 Button 外面：若给 Button 加 maxWidth 撑满，它的点击区会盖住整行右侧，
        // 让「点行跳转」在那一片失效。
        HStack(spacing: 0) {
            Button {
                noteDraft = bookmark.note
                editingBookmark = bookmark
            } label: {
                if bookmark.note.isEmpty {
                    Label(String(localized: "添加笔记"), systemImage: "square.and.pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "text.quote")
                            .font(.caption2)
                        Text(bookmark.note)
                            .font(.caption)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(.tint)
                }
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch filter {
        case .all:
            ContentUnavailableView(
                String(localized: "还没有书签"),
                systemImage: "bookmark",
                description: Text(String(localized: "点顶栏书签按钮记住当前页；在阅读页长按选中文字可添加划线。"))
            )
        case .bookmark:
            ContentUnavailableView(
                String(localized: "还没有书签"),
                systemImage: "bookmark",
                description: Text(String(localized: "点顶栏的书签按钮，即可记住当前页。"))
            )
        case .highlight:
            ContentUnavailableView(
                String(localized: "还没有划线"),
                systemImage: "highlighter",
                description: Text(String(localized: "在阅读页长按选中文字可添加划线。"))
            )
        }
    }

    // MARK: - Actions

    private func jump(to bookmark: Bookmark) {
        viewModel.goToBookmark(bookmark)
        dismiss()
    }

    private func delete(_ bookmark: Bookmark) {
        // 待编辑的引用可能正好是这一条，先断开再删，避免 alert 读到已删除的模型。
        if editingBookmark?.persistentModelID == bookmark.persistentModelID {
            editingBookmark = nil
        }
        viewModel.deleteBookmark(bookmark)
        reload()
    }

    private func reload() {
        items = viewModel.fetchBookmarks()
    }
}
