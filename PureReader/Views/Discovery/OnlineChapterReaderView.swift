import SwiftUI

/// 在线章节试读：不加入书架，直接按书源规则抓取正文阅读。
/// 用于发现页「目录预览」点章节即看正文的场景；
/// 支持上一章/下一章连续翻页，关闭后不产生任何书架数据。
struct OnlineChapterReaderView: View {
    let bookName: String
    let chapters: [SourceChapterItem]
    let startIndex: Int
    let source: BookSourceSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var content = ""
    @State private var isLoading = false
    @State private var errorText: String?

    init(bookName: String, chapters: [SourceChapterItem], startIndex: Int, source: BookSourceSnapshot) {
        self.bookName = bookName
        self.chapters = chapters
        self.startIndex = startIndex
        self.source = source
        _currentIndex = State(initialValue: startIndex)
    }

    private var currentChapter: SourceChapterItem? {
        guard chapters.indices.contains(currentIndex) else { return nil }
        return chapters[currentIndex]
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "正在加载正文…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText {
                    ContentUnavailableView {
                        Label(String(localized: "正文加载失败"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorText)
                    } actions: {
                        Button(String(localized: "重试")) {
                            Task { await load() }
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(currentChapter?.title ?? "")
                                .font(.title3.bold())
                            Text(content)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                }
            }
            .navigationTitle(bookName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "关闭")) { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        if currentIndex > 0 { currentIndex -= 1 }
                    } label: {
                        Label(String(localized: "上一章"), systemImage: "chevron.left")
                    }
                    .disabled(currentIndex <= 0 || isLoading)

                    Text("\(min(currentIndex + 1, max(chapters.count, 1)))/\(chapters.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        if currentIndex < chapters.count - 1 { currentIndex += 1 }
                    } label: {
                        Label(String(localized: "下一章"), systemImage: "chevron.right")
                    }
                    .disabled(currentIndex >= chapters.count - 1 || isLoading)
                }
            }
        }
        .task(id: currentIndex) {
            await load()
        }
    }

    private func load() async {
        guard let chapter = currentChapter else { return }
        isLoading = true
        errorText = nil
        content = ""
        defer { isLoading = false }
        do {
            let text = try await BookSourceEngine.fetchContent(chapterURL: chapter.url, source: source)
            if text.isEmpty {
                errorText = String(localized: "正文为空，可能是书源规则失效或章节需要登录")
            } else {
                content = text
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
