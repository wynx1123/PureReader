import SwiftUI
import SwiftData

/// 「历史」标签页：按浏览日期倒序列出最近打开/阅读过的书。
///
/// 与番茄小说等阅读器一致，一本书在历史里只出现一次（最近一次浏览时间），
/// 点击直接续读。数据源是 `Book.lastReadAt`，移出历史仅清空该时间戳，
/// 不影响书籍、章节与阅读进度。
struct HistoryView: View {
    @Query(sort: \Book.lastReadAt, order: .reverse) private var books: [Book]
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel = HistoryViewModel()
    @State private var readerSession: ReaderSession?
    @State private var bookForDetail: Book?
    @State private var bookToEdit: Book?
    @State private var bookPendingRemove: Book?
    @State private var confirmClearAll = false
    @State private var exportURL: URL?
    @State private var showExportSheet = false

    /// 只保留确实浏览过的书（lastReadAt 非空）。
    private var historyBooks: [Book] {
        books.filter { $0.lastReadAt != nil }
    }

    /// 按浏览日期倒序分组：今天 / 昨天 / 更早。
    private var sections: [(title: String, books: [Book])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var buckets: [Date: [Book]] = [:]
        for book in historyBooks {
            guard let date = book.lastReadAt else { continue }
            buckets[cal.startOfDay(for: date), default: []].append(book)
        }
        return buckets.keys.sorted(by: >).map { day in
            let title: String
            if cal.isDateInToday(day) {
                title = String(localized: "今天")
            } else if cal.isDateInYesterday(day) {
                title = String(localized: "昨天")
            } else if cal.isDate(day, equalTo: today, toGranularity: .year) {
                title = day.formatted(.dateTime.month().day())
            } else {
                title = day.formatted(.dateTime.year().month().day())
            }
            return (title, buckets[day] ?? [])
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PRTheme.shelfBackground.ignoresSafeArea()
                content
            }
            .navigationTitle(String(localized: "历史"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .sheet(isPresented: Binding(
                get: { bookForDetail != nil },
                set: { if !$0 { bookForDetail = nil } }
            )) {
                if let book = bookForDetail {
                    BookDetailSheet(
                        book: book,
                        onRead: { openReader(book) },
                        onEdit: { bookToEdit = book },
                        onExport: {
                            do {
                                let url = try BookImportService.exportTXT(book: book)
                                exportURL = url
                                showExportSheet = true
                            } catch {
                                viewModel.errorMessage = error.localizedDescription
                            }
                        },
                        onDelete: { removeFromHistory(book) }
                    )
                }
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
            .alert(
                String(localized: "移出历史"),
                isPresented: Binding(
                    get: { bookPendingRemove != nil },
                    set: { if !$0 { bookPendingRemove = nil } }
                )
            ) {
                Button(String(localized: "移出"), role: .destructive) {
                    if let book = bookPendingRemove { removeFromHistory(book) }
                    bookPendingRemove = nil
                }
                Button(String(localized: "取消"), role: .cancel) {
                    bookPendingRemove = nil
                }
            } message: {
                Text(String(localized: "将《\(bookPendingRemove?.title ?? "")》移出历史。阅读进度不会被删除。"))
            }
            .alert(String(localized: "清空历史"), isPresented: $confirmClearAll) {
                Button(String(localized: "清空"), role: .destructive) {
                    viewModel.clearAll(historyBooks, context: modelContext)
                }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                Text(String(localized: "将清空全部浏览历史，共 \(historyBooks.count) 本书。阅读进度不会被删除。"))
            }
            .fullScreenCover(item: $readerSession) { session in
                ReaderView(session: session)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if historyBooks.isEmpty {
            emptyState
        } else {
            List {
                ForEach(sections, id: \.title) { section in
                    Section {
                        ForEach(section.books, id: \.persistentModelID) { book in
                            row(for: book)
                                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                .listRowBackground(Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { openReader(book) }
                                .contextMenu { menu(for: book) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        bookPendingRemove = book
                                    } label: {
                                        Label(String(localized: "移出"), systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        Text(section.title)
                            .font(.footnote.weight(.semibold))
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 40)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text(String(localized: "暂无历史记录"))
                .font(.title3.weight(.semibold))
            Text(String(localized: "打开一本书开始阅读后，这里会显示你的浏览历史"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for book: Book) -> some View {
        HStack(spacing: 14) {
            BookCoverView(
                title: book.title,
                author: book.author,
                coverData: book.coverImageData,
                progress: book.progressFraction
            )
            .frame(width: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(PRTheme.primaryText)
                    .lineLimit(2)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundStyle(PRTheme.secondaryText)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if book.progressFraction > 0 {
                        Text("\(Int(book.progressFraction * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(PRTheme.secondaryText)
                    }
                    if let date = book.lastReadAt {
                        Text(Self.formatTime(date))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func menu(for book: Book) -> some View {
        Button {
            openReader(book)
        } label: {
            Label(String(localized: "阅读"), systemImage: "book")
        }
        Button {
            bookForDetail = book
        } label: {
            Label(String(localized: "详情"), systemImage: "info.circle")
        }
        Button {
            bookToEdit = book
        } label: {
            Label(String(localized: "编辑"), systemImage: "pencil")
        }
        Button(role: .destructive) {
            bookPendingRemove = book
        } label: {
            Label(String(localized: "移出历史"), systemImage: "trash")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !historyBooks.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmClearAll = true
                } label: {
                    Text(String(localized: "清空"))
                        .frame(minWidth: PRTheme.touch, minHeight: PRTheme.touch)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "清空历史"))
            }
        }
    }

    // MARK: - Actions

    private func openReader(_ book: Book) {
        readerSession = ReaderSession(book: book, context: modelContext)
    }

    private func removeFromHistory(_ book: Book) {
        viewModel.removeFromHistory(book, context: modelContext)
    }

    private static func formatTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

#Preview {
    HistoryView()
        .modelContainer(
            for: [
                Book.self,
                Chapter.self,
                ReadingRecord.self,
                ReadingSettings.self,
                ShelfPreferences.self,
                RewriteRecord.self,
                BookSource.self
            ],
            inMemory: true
        )
}
