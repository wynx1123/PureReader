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
    /// 归属书源（发现页按书源分组展示分类；nil 表示跨源聚合/回退分类）
    var sourceID: UUID? = nil
    var sourceName: String? = nil
}

@MainActor
@Observable
final class DiscoveryViewModel {
    var keyword = ""
    var results: [SourceSearchResult] = []
    var discoveryResults: [SourceSearchResult] = []
    var categories: [DiscoveryCategoryOption] = []
    var selectedCategoryID = ""
    /// 当前选中的书源（发现页分类按书源分组；nil 表示尚无可用书源）
    var selectedSourceID: UUID?
    /// 搜索/发现结果缺封面时，从详情页懒加载的封面缓存（bookURL → coverURL，空串=已确认无封面）
    var coverOverrides: [String: String] = [:]
    private var coverPrefetching = Set<String>()
    var isSearching = false
    var isLoadingDiscovery = false
    var errorMessage: String?
    var selectedItem: SourceSearchResult?
    var tocChapters: [SourceChapterItem] = []
    var isLoadingTOC = false
    /// 详情页补全的封面/简介（搜索列表缺封面时从书籍详情页补齐，如爱丽丝）。
    var detailCoverURL: String?
    var detailIntro: String?
    var isAdding = false
    var statusMessage: String?
    var verificationRequest: BookSourceVerificationRequest?

    private var searchTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var sourceCache: [UUID: BookSourceSnapshot] = [:]

    var selectedCategory: DiscoveryCategoryOption? {
        categories.first { $0.id == selectedCategoryID }
    }

    /// 有 explore 分类的书源列表（按权重序，与 categories 同源）
    var explorableSources: [(id: UUID, name: String)] {
        var seen = Set<UUID>()
        var out: [(UUID, String)] = []
        for category in categories {
            guard let sid = category.sourceID, let name = category.sourceName,
                  seen.insert(sid).inserted else { continue }
            out.append((sid, name))
        }
        return out
    }

    /// 当前书源下的分类（按书源分组后的第二行 chips）
    var visibleCategories: [DiscoveryCategoryOption] {
        guard let sid = selectedSourceID else { return categories }
        return categories.filter { $0.sourceID == sid }
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
        // 书源分组后：保持已选书源（仍存在时），否则默认第一个有分类的书源
        let sourceIDs = Set(categories.compactMap(\.sourceID))
        if let sid = selectedSourceID, !sourceIDs.contains(sid) {
            selectedSourceID = nil
        }
        if selectedSourceID == nil {
            selectedSourceID = categories.first(where: { $0.sourceID != nil })?.sourceID
        }
        if !visibleCategories.contains(where: { $0.id == selectedCategoryID }) {
            selectedCategoryID = visibleCategories.first?.id ?? ""
        }
        loadSelectedCategory(snapshots: snapshots)
    }

    /// 切换发现页书源（分类按书源分组；自动选中该源第一个分类并加载）
    func selectSource(_ sourceID: UUID, sources: [BookSource]) {
        guard selectedSourceID != sourceID else { return }
        selectedSourceID = sourceID
        selectedCategoryID = visibleCategories.first?.id ?? ""
        discoveryResults = []
        loadSelectedCategory(snapshots: prepareSources(sources))
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
        detailCoverURL = nil
        detailIntro = nil
        do {
            async let tocTask = BookSourceEngine.fetchTOC(bookURL: item.bookURL, source: source)
            // 搜索/发现列表缺封面或简介时，并行从详情页补齐；详情失败不阻塞目录展示
            async let infoTask = BookSourceEngine.fetchBookInfo(bookURL: item.bookURL, source: source)
            let info = try? await infoTask
            tocChapters = try await tocTask
            if item.coverURL == nil { detailCoverURL = info?.coverURL }
            if item.intro.isEmpty { detailIntro = info?.intro }
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

            let existingURL: String? = item.bookURL
            let existing = try? context.fetch(
                FetchDescriptor<Book>(
                    predicate: #Predicate<Book> { $0.sourceURL == existingURL }
                )
            )
            if let existing, !existing.isEmpty {
                statusMessage = String(localized: "这本书已经在书架中")
                return
            }

            let limited = Array(list.prefix(5000))
            // 搜索结果无封面时，用详情页补全的封面（detailCoverURL 由 loadTOC 填充；
            // 若用户跳过预览直接添加则现场补取一次）
            var coverURL = item.coverURL ?? detailCoverURL
            if coverURL == nil,
               let info = try? await BookSourceEngine.fetchBookInfo(bookURL: item.bookURL, source: source) {
                coverURL = info.coverURL
            }
            let coverData = await downloadCover(coverURL, source: source)
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

    /// 按书源分组生成分类（不再跨源合并同名分类）：
    /// 每个 option 归属单一书源，发现页先选书源再选该源分类。
    private func makeCategories(_ sourceCategories: [SourceExploreCategory]) -> [DiscoveryCategoryOption] {
        // 保持书源出现顺序（exploreCategories 已按快照顺序），同源内按分类优先级排序
        var bySource: [UUID: (name: String, entries: [SourceExploreCategory])] = [:]
        var sourceOrder: [UUID] = []
        for entry in sourceCategories {
            if bySource[entry.sourceID] == nil {
                bySource[entry.sourceID] = (entry.sourceName, [])
                sourceOrder.append(entry.sourceID)
            }
            bySource[entry.sourceID]?.entries.append(entry)
        }
        var options: [DiscoveryCategoryOption] = []
        for sid in sourceOrder {
            guard let group = bySource[sid] else { continue }
            let sorted = group.entries.sorted {
                categoryPriority($0.title.trimmingCharacters(in: .whitespacesAndNewlines))
                    < categoryPriority($1.title.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            var seenTitles = Set<String>()
            for entry in sorted {
                let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard seenTitles.insert(title).inserted else { continue }
                options.append(DiscoveryCategoryOption(
                    id: sid.uuidString + ":" + title,
                    title: title,
                    query: title,
                    entries: [entry],
                    isRanking: isRankingTitle(title),
                    sourceID: sid,
                    sourceName: group.name
                ))
            }
        }
        if options.isEmpty {
            options.append(contentsOf: fallbackCategories())
        }
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

    /// 搜索结果无封面时，后台从书籍详情页懒加载封面（滚动到可见才触发，结果缓存）。
    /// 确认无封面的也缓存空串，避免同一本书反复请求。
    func prefetchCoverIfNeeded(for item: SourceSearchResult, sources: [BookSource]) {
        guard item.coverURL == nil else { return }
        let key = item.bookURL
        guard coverOverrides[key] == nil, !coverPrefetching.contains(key) else { return }
        coverPrefetching.insert(key)
        Task {
            defer { coverPrefetching.remove(key) }
            guard let source = resolveSource(item: item, sources: sources) else { return }
            let info = try? await BookSourceEngine.fetchBookInfo(bookURL: item.bookURL, source: source)
            coverOverrides[key] = info?.coverURL ?? ""
        }
    }

    private func resolveSource(
        item: SourceSearchResult,
        sources: [BookSource]
    ) -> BookSourceSnapshot? {
        if let source = sourceCache[item.sourceID] { return source }
        return sources.first { $0.id == item.sourceID }.map { BookSourceSnapshot($0) }
    }
}
