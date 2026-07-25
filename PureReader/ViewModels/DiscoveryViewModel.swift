import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class DiscoveryViewModel {
    var keyword = ""
    var results: [SourceSearchResult] = []
    var isSearching = false
    var errorMessage: String?
    var selectedItem: SourceSearchResult?
    var tocChapters: [SourceChapterItem] = []
    var isLoadingTOC = false
    var isAdding = false
    var statusMessage: String?

    private var searchTask: Task<Void, Never>?
    private var sourceCache: [UUID: BookSource] = [:]

    func search(sources: [BookSource]) {
        searchTask?.cancel()
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            results = []
            return
        }
        sourceCache = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let enabled = sources.filter { $0.enabled && !$0.searchURL.isEmpty }
        guard !enabled.isEmpty else {
            let incompatible = sources.filter { !$0.isValid }.count
            if !sources.isEmpty, incompatible == sources.count {
                errorMessage = String(localized: "已安装 \(sources.count) 个书源，但都因脚本或规则兼容性被停用。请在书源管理中重新导入以重新评估，或导入无 JavaScript 的书源。")
            } else {
                errorMessage = String(localized: "已安装 \(sources.count) 个书源，但没有启用的书源。请前往书源管理启用。")
            }
            return
        }
        isSearching = true
        errorMessage = nil
        statusMessage = nil
        searchTask = Task {
            defer { isSearching = false }
            let report = await BookSourceEngine.search(keyword: kw, sources: enabled)
            guard !Task.isCancelled else { return }
            results = report.results
            if report.attemptedCount > 0,
               report.failures.count == report.attemptedCount {
                let details = report.failures.prefix(3).map {
                    "\($0.sourceName)：\($0.reason)"
                }.joined(separator: "\n")
                errorMessage = String(localized: "所有已启用书源均拉取失败")
                    + (details.isEmpty ? "" : "\n\n" + details)
                statusMessage = nil
            } else if report.results.isEmpty {
                let succeeded = report.attemptedCount - report.failures.count
                statusMessage = String(localized: "\(succeeded) 个书源请求成功，但没有解析到匹配结果")
            } else {
                let failedNote = report.failures.isEmpty
                    ? ""
                    : String(localized: "，\(report.failures.count) 个书源失败")
                statusMessage = String(localized: "找到 \(report.results.count) 条结果") + failedNote
            }
        }
    }

    func loadTOC(for item: SourceSearchResult, sources: [BookSource]) async {
        selectedItem = item
        isLoadingTOC = true
        defer { isLoadingTOC = false }
        guard let source = resolveSource(item: item, sources: sources) else {
            errorMessage = String(localized: "找不到对应书源")
            tocChapters = []
            return
        }
        do {
            tocChapters = try await BookSourceEngine.fetchTOC(bookURL: item.bookURL, source: source)
        } catch {
            errorMessage = error.localizedDescription
            tocChapters = []
        }
    }

    /// 添加全书到书架（抓取全部章节正文）
    func addToBookshelf(
        item: SourceSearchResult,
        sources: [BookSource],
        context: ModelContext
    ) async {
        isAdding = true
        statusMessage = String(localized: "正在抓取章节…")
        defer { isAdding = false }
        guard let source = resolveSource(item: item, sources: sources) else {
            errorMessage = String(localized: "找不到对应书源")
            return
        }
        do {
            var list = tocChapters
            if list.isEmpty {
                list = try await BookSourceEngine.fetchTOC(bookURL: item.bookURL, source: source)
            }
            guard !list.isEmpty else {
                errorMessage = String(localized: "目录为空")
                return
            }

            // 限制章节数防止极端书源拖垮内存（可后续分页下载）
            let cap = min(list.count, 500)
            let limited = Array(list.prefix(cap))

            var contents: [(SourceChapterItem, String)] = []
            contents.reserveCapacity(limited.count)

            try await withThrowingTaskGroup(of: (Int, SourceChapterItem, String).self) { group in
                let concurrency = 3
                var next = 0
                func enqueue(_ i: Int) {
                    let ch = limited[i]
                    group.addTask {
                        let text = try await BookSourceEngine.fetchContent(
                            chapterURL: ch.url,
                            source: source
                        )
                        return (i, ch, text)
                    }
                }
                while next < min(concurrency, limited.count) {
                    enqueue(next)
                    next += 1
                }
                var done = 0
                while done < limited.count {
                    guard let (i, ch, text) = try await group.next() else { break }
                    contents.append((ch, text))
                    done += 1
                    statusMessage = String(localized: "抓取中 \(done)/\(limited.count)")
                    if next < limited.count {
                        enqueue(next)
                        next += 1
                    }
                    _ = i
                }
            }

            let order = Dictionary(uniqueKeysWithValues: limited.enumerated().map { ($0.element.url, $0.offset) })
            contents.sort { (order[$0.0.url] ?? 0) < (order[$1.0.url] ?? 0) }

            var coverData: Data?
            if let cover = item.coverURL, let url = URL(string: cover) {
                if let (data, _) = try? await URLSession.shared.data(from: url) {
                    coverData = data
                }
            }
            let book = Book(
                title: item.name.isEmpty ? String(localized: "未命名") : item.name,
                author: item.author,
                coverImageData: coverData,
                sourceType: .booksource,
                sourceName: item.sourceName,
                sourceURL: item.bookURL,
                format: .online,
                totalChapters: contents.count
            )
            context.insert(book)

            for (idx, pair) in contents.enumerated() {
                let ch = Chapter(index: idx, title: pair.0.title, content: pair.1)
                ch.book = book
                context.insert(ch)
            }
            try context.save()

            BookUnderstandingCoordinator.shared.scheduleIfNeeded(book: book, context: context)
            statusMessage = String(localized: "已加入书架：\(book.title)")
            if limited.count < list.count {
                statusMessage = String(localized: "已加入书架（仅抓取前 \(limited.count) 章）")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveSource(item: SourceSearchResult, sources: [BookSource]) -> BookSource? {
        if let s = sourceCache[item.sourceID] { return s }
        return sources.first { $0.id == item.sourceID }
    }
}
