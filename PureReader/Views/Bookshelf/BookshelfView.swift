import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct BookshelfView: View {
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @Query private var preferences: [ShelfPreferences]
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel = BookshelfViewModel()
    @State private var bookToEdit: Book?
    @State private var bookPendingDelete: Book?
    @State private var bookToRead: Book?
    @State private var exportURL: URL?
    @State private var showExportSheet = false
    @State private var expandedImportReport = false

    private var prefs: ShelfPreferences? { preferences.first }

    private var displayed: [Book] {
        viewModel.filteredSorted(books)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PRTheme.shelfBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    filterBar
                    content
                }
            }
            .navigationTitle(String(localized: "图书"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: String(localized: "搜索")
            )
            .toolbar { toolbarContent }
            // 关键：fileImporter 必须在根视图，不要放进 sheet
            .fileImporter(
                isPresented: $viewModel.showImporter,
                allowedContentTypes: BookImportService.allowedContentTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    // 安全作用域必须在回调当下开启；不可等到 Task 开始后。
                    viewModel.beginLocalImport(urls, context: modelContext)
                case .failure(let error):
                    viewModel.handleFilePickerFailure(error)
                }
            }
            .sheet(isPresented: $viewModel.showAddSheet) {
                AddBookSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showURLImporter) {
                URLImportSheet(viewModel: viewModel)
            }
            .sheet(isPresented: Binding(
                get: { bookToEdit != nil },
                set: { if !$0 { bookToEdit = nil } }
            )) {
                if let book = bookToEdit {
                    BookEditSheet(book: book)
                }
            }
            .sheet(isPresented: $showExportSheet) {
                if let exportURL {
                    ShareSheet(items: [exportURL])
                }
            }
            .sheet(item: $viewModel.importReport, onDismiss: {
                expandedImportReport = false
                viewModel.dismissImportReport()
            }) { report in
                ImportResultSheet(
                    report: report,
                    isExpanded: $expandedImportReport,
                    onDismiss: { viewModel.dismissImportReport() },
                    onRetry: {
                        viewModel.dismissImportReport()
                        // 让 result sheet 完全收起后再弹系统文件选择器。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            viewModel.showImporter = true
                        }
                    }
                )
            }
            .alert(
                String(localized: "删除书籍"),
                isPresented: Binding(
                    get: { bookPendingDelete != nil },
                    set: { if !$0 { bookPendingDelete = nil } }
                )
            ) {
                Button(String(localized: "删除"), role: .destructive) {
                    if let book = bookPendingDelete {
                        viewModel.delete(book, context: modelContext)
                    }
                    bookPendingDelete = nil
                }
                Button(String(localized: "取消"), role: .cancel) {
                    bookPendingDelete = nil
                }
            } message: {
                Text(String(localized: "将删除本书及全部章节，且不可恢复。"))
            }
            .alert(
                String(localized: "导入结果"),
                isPresented: Binding(
                    get: {
                        viewModel.importReport == nil
                            && !viewModel.showURLImporter
                            && (viewModel.importErrorMessage != nil
                                || viewModel.importSuccessMessage != nil)
                    },
                    set: { if !$0 {
                        viewModel.importErrorMessage = nil
                        viewModel.importSuccessMessage = nil
                    }}
                )
            ) {
                Button(String(localized: "好"), role: .cancel) {
                    viewModel.importErrorMessage = nil
                    viewModel.importSuccessMessage = nil
                }
            } message: {
                Text(importAlertMessage)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if viewModel.isImporting {
                    ImportProgressBanner(
                        title: viewModel.importProgressText ?? String(localized: "正在导入…"),
                        detail: viewModel.importProgressDetail ?? ""
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .overlay {
                if viewModel.isImporting {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .allowsHitTesting(true)
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { bookToRead != nil },
                set: { if !$0 { bookToRead = nil } }
            )) {
                if let book = bookToRead {
                    ReaderView(book: book, context: modelContext)
                }
            }
        }
    }

    private var importAlertMessage: String {
        if let s = viewModel.importSuccessMessage, let e = viewModel.importErrorMessage {
            return "\(s)\n\n\(e)"
        }
        return viewModel.importSuccessMessage
            ?? viewModel.importErrorMessage
            ?? ""
    }

    // MARK: - Filter

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(
                        title: String(localized: "全部"),
                        selected: viewModel.selectedGroup == nil
                    ) {
                        viewModel.selectedGroup = nil
                    }
                    ForEach(viewModel.allGroups(from: books, prefs: prefs), id: \.self) { g in
                        chip(title: g, selected: viewModel.selectedGroup == g) {
                            viewModel.selectedGroup = g
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            let tags = viewModel.allTags(from: books, prefs: prefs)
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(
                            title: String(localized: "全部标签"),
                            selected: viewModel.selectedTag == nil
                        ) {
                            viewModel.selectedTag = nil
                        }
                        ForEach(tags, id: \.self) { tag in
                            chip(title: "#\(tag)", selected: viewModel.selectedTag == tag) {
                                viewModel.selectedTag = tag
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func chip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 36)
                .background(
                    selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06),
                    in: Capsule()
                )
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if books.isEmpty {
            emptyState
        } else if displayed.isEmpty {
            ContentUnavailableView.search(
                text: viewModel.searchText.isEmpty
                    ? String(localized: "筛选条件")
                    : viewModel.searchText
            )
        } else {
            switch viewModel.layout {
            case .grid:
                grid
            case .list:
                list
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 40)
            Image(systemName: "books.vertical")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text(String(localized: "尚无图书"))
                .font(.title2.weight(.semibold))
            Text(String(localized: "导入 TXT 或 EPUB，开始阅读"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                viewModel.showImporter = true
            } label: {
                Text(String(localized: "导入书籍"))
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 160, minHeight: PRTheme.touch)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            Button {
                viewModel.showURLImporter = true
            } label: {
                Text(String(localized: "从链接添加"))
                    .frame(minHeight: 36)
            }
            .buttonStyle(.borderless)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: PRTheme.gridMin, maximum: PRTheme.gridMax),
                        spacing: PRTheme.gridSpacing
                    )
                ],
                spacing: PRTheme.gridSpacing
            ) {
                ForEach(displayed, id: \.persistentModelID) { book in
                    BookCard(book: book, style: .grid)
                        .contextMenu { bookMenu(book) }
                        .onTapGesture { bookToRead = book }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var list: some View {
        List {
            ForEach(displayed, id: \.persistentModelID) { book in
                BookCard(book: book, style: .list)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { bookToRead = book }
                    .contextMenu { bookMenu(book) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            bookPendingDelete = book
                        } label: {
                            Label(String(localized: "删除"), systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func bookMenu(_ book: Book) -> some View {
        Button {
            bookToRead = book
        } label: {
            Label(String(localized: "阅读"), systemImage: "book")
        }
        Button {
            bookToEdit = book
        } label: {
            Label(String(localized: "编辑"), systemImage: "pencil")
        }
        Button {
            do {
                let url = try BookImportService.exportTXT(book: book)
                exportURL = url
                showExportSheet = true
            } catch {
                viewModel.importErrorMessage = error.localizedDescription
            }
        } label: {
            Label(String(localized: "导出 TXT"), systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive) {
            bookPendingDelete = book
        } label: {
            Label(String(localized: "删除"), systemImage: "trash")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker(String(localized: "排序"), selection: $viewModel.sort) {
                    ForEach(BookshelfSort.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                Picker(String(localized: "布局"), selection: $viewModel.layout) {
                    ForEach(BookshelfLayout.allCases) { l in
                        Label(l.title, systemImage: l.systemImage).tag(l)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(minWidth: PRTheme.touch, minHeight: PRTheme.touch)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "排序与布局"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    viewModel.showImporter = true
                } label: {
                    Label(String(localized: "从文件导入"), systemImage: "doc.badge.plus")
                }
                Button {
                    viewModel.showURLImporter = true
                } label: {
                    Label(String(localized: "从链接导入"), systemImage: "link")
                }
                Button {
                    viewModel.showAddSheet = true
                } label: {
                    Label(String(localized: "更多选项…"), systemImage: "ellipsis.circle")
                }
            } label: {
                Image(systemName: "plus")
                    .frame(minWidth: PRTheme.touch, minHeight: PRTheme.touch)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "添加书籍"))
        }
    }
}

// MARK: - Import feedback

private struct ImportProgressBanner: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
    }
}

private struct ImportResultSheet: View {
    let report: ImportReport
    @Binding var isExpanded: Bool
    let onDismiss: () -> Void
    let onRetry: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: report.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(report.isSuccess ? .green : .orange)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(report.title)
                        .font(.title3.weight(.semibold))
                    Text(report.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if !report.details.isEmpty {
                    List {
                        ForEach(Array(report.details.enumerated()), id: \.offset) { _, detail in
                            Text(detail)
                                .font(.footnote)
                                .textSelection(.enabled)
                                .lineLimit(isExpanded ? nil : 3)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .frame(minHeight: 110, maxHeight: isExpanded ? 360 : 190)

                    if report.details.count > 1 || report.details.first?.count ?? 0 > 120 {
                        Button(isExpanded ? String(localized: "收起详情") : String(localized: "显示完整诊断")) {
                            isExpanded.toggle()
                        }
                        .font(.footnote)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 24)
            .navigationTitle(String(localized: "导入结果"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "完成")) { onDismiss() }
                }
                if !report.isSuccess {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "重新选择")) { onRetry() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Share helper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview("空书架") {
    BookshelfView()
        .modelContainer(
            for: [
                Book.self, Chapter.self, ReadingRecord.self,
                ReadingSettings.self, ShelfPreferences.self, RewriteRecord.self
            ],
            inMemory: true
        )
}
