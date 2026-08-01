import Foundation
import SwiftData
import Observation
import UIKit

struct DiscoveryCategoryOption: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var query: String
    var entries: [SourceExploreCategory]
    var isRanking: Bool
}

@MainActor
@Observable
final class DiscoveryViewModel {
    var keyword = ""
    var results: [SourceSearchResult] = []
    var discoveryResults: [SourceSearchResult] = []
    var categories: [DiscoveryCategoryOption] = []
    var selectedCategoryID = ""
    var isSearching = false
    var isLoadingDiscovery = false
    var errorMessage: String?
    var selectedItem: SourceSearchResult?
    var tocChapters: [SourceChapterItem] = []
    var isLoadingTOC = false
    var isAdding = false
    var statusMessage: String?
    var verificationRequest: BookSourceVerificationRequest?

    private var searchTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var sourceCache: [UUID: BookSourceSnapshot] = [:]

    var selectedCategory: DiscoveryCategoryOption? {
        categories.first { $0.id == selectedCategoryID }
    }

    func prepareSources(_ sources: [BookSource]) -> [BookSourceSnapshot] {
        sourceCache = Dictionary(
            sources.map { ($0.id, BookSourceSnapshot($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return sources
            .filter { $0.enabled && $0.isValid && !$0.searchURL.isEmpty }
            .map { BookSourceSnapshot($0) }
    }

    func loadDiscovery(sources: [BookSource], force: Bool = false) {
        if !force, (isLoadingDiscovery || !discoveryResults.isEmpty) { return }
        discoveryTask?.cancel()
        let snapshots = prepareSources(sources)
        guard !snapshots.isEmpty else {
            discoveryResults = []
            categories = fallbackCategories()
            selectedCategoryID = categories.first?.id ?? ""
            return
        }

        let sourceCategories = BookSourceEngine.exploreCategories(snapshots: snapshots)
        categories = makeCategories(sourceCategories)
        if !categories.contains(where: { $0.id == selectedCategoryID }) {
            selectedCategoryID = categories.first?.id ?? ""
        }
        loadSelectedCategory(snapshots: snapshots)
    }

    func selectCategory(_ category: DiscoveryCategoryOption, sources: [BookSource]) {
        guard selectedCategoryID != category.id || discoveryResults.isEmpty else { return }
        selectedCategoryID = category.id
        discoveryResults = []
        loadSelectedCategory(snapshots: prepareSources(sources))
    }

    private func loadSelectedCategory(snapshots: [BookSourceSnapshot]) {
        guard let category = selectedCategory else { return }
        discoveryTask?.cancel()
        isLoadingDiscovery = true
        errorMessage = nil
        statusMessage = nil
        discoveryTask = Task {
            defer { isLoadingDiscovery = false }
            let report: BookSourceSearchReport
            if !category.entries.isEmpty {
                report = await BookSourceEngine.discover(
                    categories: category.entries,
                    snapshots: snapshots
                )
            } else {
                report = await BookSourceEngine.search(
                    keyword: category.query,
                    snapshots: snapshots
                )
            }
            guard !Task.isCancelled else { return }
            discoveryResults = report.results
            handle(report: report, emptyMessage: String(localized: "当前分类暂未拉取到书籍，可以切换分类或检查书源。"))
        }
    }

    func search(sources: [BookSource]) {
        searchTask?.cancel()
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = []
            return
        }
        let snapshots = prepareSources(sources)
        guard !snapshots.isEmpty else {
            let incompatible = sources.filter { !$0.isValid }.count
            if sources.isEmpty {
                errorMessage = String(localized: "尚未安装书源，请先在书源管理中导入。")
            } else if incompatible == sources.count {
                errorMessage = String(localized: "已安装 \(sources.count) 个书源，但都因脚本或规则兼容性被停用。请在书源管理中重新导入以重新评估，或导入无 JavaScript 的书源。")
            } else {
                errorMessage = String(localized: "已安装 \(sources.count) 个书源，但没有启用且可搜索的书源。请前往书源管理启用。")
            }
            return
        }
        isSearching = true
        errorMessage = nil
        statusMessage = nil
        searchTask = Task {
            defer { isSearching = false }
            let report = await BookSourceEngine.search(keyword: query, snapshots: snapshots)
            guard !Task.isCancelled else { return }
            results = report.results
            handle(report: report, emptyMessage: String(localized: "书源请求成功，但没有找到匹配书籍。"))
        }
    }

    private func handle(report: BookSourceSearchReport, emptyMessage: String) {
        if let blocked = report.failures.first(where: { $0.verificationURL != nil }),
           let url = blocked.verificationURL {
            verificationRequest = BookSourceVerificationRequest(
                sourceID: blocked.sourceID,
                sourceName: blocked.sourceName,
                url: url
            )
        }
        if report.attemptedCount > 0, report.failures.count == report.attemptedCount {
            let details = report.failures.prefix(3).map { "\($0.sourceName)：\($0.reason)" }
                .joined(separator: "\n")
            errorMessage = String(localized: "所有书源均拉取失败") + (details.isEmpty ? "" : "\n\n" + details)
            statusMessage = nil
        } else if report.results.isEmpty {
            statusMessage = emptyMessage
        } else {
            let failedNote = report.failures.isEmpty ? "" : String(localized: "，\(report.failures.count) 个书源失败")
            statusMessage = String(localized: "找到 \(report.results.count) 本书") + failedNote
        }
    }

    func loadTOC(for item: SourceSearchResult, sources: [BookSource]) async {
        selectedItem = item
        isLoadingTOC = true
        errorMessage = nil
        defer { isLoadingTOC = false }
        guard let source = resolveSource(item: item, sources: sources) else {
            errorMessage = String(localized: "找不到对应书源")
            tocChapters = []
            return
        }
        do {
            tocChapters = try await BookSourceEngine.fetchTOC(bookURL: item.bookURL, source: source)
        } catch {
            registerVerificationIfNeeded(error, source: source)
            errorMessage = error.localizedDescription
            tocChapters = []
        }
    }

    /// 只保存目录和章节地址，正文进入阅读器后按需抓取。
    func addToBookshelf(
        item: SourceSearchResult,
        sources: [BookSource],
        context: ModelContext
    ) async {
        isAdding = true
        errorMessage = nil
        statusMessage = String(localized: "正在获取目录…")
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

            let existing = (try? context.fetch(FetchDescriptor<Book>())) ?? []
            if existing.contains(where: { $0.sourceURL == item.bookURL }) {
                statusMessage = String(localized: "这本书已经在书架中")
                return
            }

            let limited = Array(list.prefix(5000))
            let coverData = await downloadCover(item.coverURL, source: source)
            let book = Book(
                title: item.name.isEmpty ? String(localized: "未命名") : item.name,
                author: item.author,
                coverImageData: coverData,
                sourceType: .booksource,
                sourceName: item.sourceName,
                sourceURL: item.bookURL,
                bookSourceID: item.sourceID,
                format: .online,
                totalChapters: limited.count
            )
            context.insert(book)

            var chapters: [Chapter] = []
            chapters.reserveCapacity(limited.count)
            for (index, chapterItem) in limited.enumerated() {
                let chapter = Chapter(
                    index: index,
                    title: chapterItem.title,
                    content: "",
                    sourceURL: chapterItem.url
                )
                chapter.book = book
                context.insert(chapter)
                chapters.append(chapter)
            }
            book.chapters = chapters
            try context.save()

            statusMessage = limited.count < list.count
                ? String(localized: "已加入书架（保存前 \(limited.count) 章，正文阅读时下载）")
                : String(localized: "已加入书架，正文将在阅读时按需下载")
        } catch {
            registerVerificationIfNeeded(error, source: source)
            errorMessage = error.localizedDescription
        }
    }

    func saveVerificationCookies(
        _ cookieHeader: String,
        for source: BookSource,
        context: ModelContext
    ) {
        let trimmed = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = String(localized: "未读取到验证 Cookie，请完成验证后再点完成。")
            return
        }
        var headers: [String: String] = [:]
        if let data = source.headerJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                if let text = value as? String { headers[key] = text }
            }
        }
        headers["Cookie"] = trimmed
        if let data = try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            source.headerJSON = text
        }
        source.enabled = true
        source.isValid = true
        source.lastCheckedAt = Date()
        try? context.save()
        sourceCache[source.id] = BookSourceSnapshot(source)
        verificationRequest = nil
        statusMessage = String(localized: "验证信息已保存，请重试刚才的操作。")
    }

    private func registerVerificationIfNeeded(_ error: Error, source: BookSourceSnapshot) {
        guard case BookSourceError.verificationRequired(let url) = error else { return }
        verificationRequest = BookSourceVerificationRequest(
            sourceID: source.id,
            sourceName: source.name,
            url: url
        )
    }

    private func makeCategories(_ sourceCategories: [SourceExploreCategory]) -> [DiscoveryCategoryOption] {
        let grouped = Dictionary(grouping: sourceCategories, by: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) })
        var options = grouped.keys.sorted { lhs, rhs in
            categoryPriority(lhs) < categoryPriority(rhs)
        }.map { title in
            DiscoveryCategoryOption(
                id: "source:" + title,
                title: title,
                query: title,
                entries: grouped[title] ?? [],
                isRanking: isRankingTitle(title)
            )
        }
        let existingTitles = Set(options.map { $0.title })
        options.append(contentsOf: fallbackCategories().filter { !existingTitles.contains($0.title) })
        return options
    }

    private func fallbackCategories() -> [DiscoveryCategoryOption] {
        [
            ("热门榜", "热门小说", true),
            ("玄幻", "玄幻", false),
            ("都市", "都市", false),
            ("言情", "言情", false),
            ("悬疑", "悬疑", false),
            ("科幻", "科幻", false),
            ("历史", "历史", false),
            ("完本", "完本", false)
        ].map {
            DiscoveryCategoryOption(id: "fallback:" + $0.0, title: $0.0, query: $0.1, entries: [], isRanking: $0.2)
        }
    }

    private func categoryPriority(_ title: String) -> Int {
        if isRankingTitle(title) { return 0 }
        if title.contains("推荐") { return 1 }
        return 2
    }

    private func isRankingTitle(_ title: String) -> Bool {
        ["榜", "排行", "热门", "推荐"].contains { title.contains($0) }
    }

    private func downloadCover(_ raw: String?, source: BookSourceSnapshot) async -> Data? {
        let maxCoverBytes = 4 * 1024 * 1024
        guard let raw,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        // 封面 CDN 常带防盗链（如 i.pximg.net 需要 Referer、部分站校验 UA），
        // 复用书源声明的请求头，避免封面 403 导致「有封面规则但无图」。
        let headers = BookSourceEngine.parseHeaders(source.headerJSON)
        for (name, value) in headers where request.value(forHTTPHeaderField: name) == nil {
            request.setValue(value, forHTTPHeaderField: name)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) { return nil }
        guard !data.isEmpty, data.count <= maxCoverBytes, UIImage(data: data) != nil else { return nil }
        return data
    }

    private func resolveSource(
        item: SourceSearchResult,
        sources: [BookSource]
    ) -> BookSourceSnapshot? {
        if let source = sourceCache[item.sourceID] { return source }
        return sources.first { $0.id == item.sourceID }.map { BookSourceSnapshot($0) }
    }
}
