import Foundation
import SwiftData
import SwiftUI

/// 导入完成后保留在书架上的结果卡片，避免系统 Alert 被 Sheet / 文件选择器吞掉。
struct ImportReport: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let details: [String]
    let isSuccess: Bool
}

@MainActor
@Observable
final class BookshelfViewModel {
    var sort: BookshelfSort = .lastRead
    var layout: BookshelfLayout = .grid
    var selectedGroup: String? = nil // nil = 全部
    var selectedTag: String? = nil
    var searchText: String = ""

    var isImporting = false
    /// 兼容 URL 导入页的行内错误展示
    var importErrorMessage: String?
    var importSuccessMessage: String?
    /// 文件选择完成后的可见状态（不依赖 Alert）
    var importProgressText: String?
    var importProgressDetail: String?
    var importReport: ImportReport?

    /// 文件选择器必须挂在根视图（不要放在 sheet 内）
    var showImporter = false
    var showURLImporter = false
    var showAddSheet = false
    var urlString = ""
    var pendingTags: String = ""
    var pendingGroup: String = BuiltInGroup.default

    func filteredSorted(_ books: [Book]) -> [Book] {
        var list = books

        if let g = selectedGroup {
            if g == BuiltInGroup.default {
                list = list.filter { $0.group == nil || $0.group?.isEmpty == true || $0.group == BuiltInGroup.default }
            } else {
                list = list.filter { $0.group == g }
            }
        }

        if let tag = selectedTag, !tag.isEmpty {
            list = list.filter { $0.tags.contains(tag) }
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(q)
                    || $0.author.localizedCaseInsensitiveContains(q)
                    || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(q) })
            }
        }

        switch sort {
        case .lastRead:
            list.sort { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
        case .recentlyAdded:
            list.sort { $0.addedAt > $1.addedAt }
        case .title:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            list.sort { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        }
        return list
    }

    func allGroups(from books: [Book], prefs: ShelfPreferences?) -> [String] {
        var set = Set(BuiltInGroup.all)
        for b in books {
            if let g = b.group, !g.isEmpty { set.insert(g) }
        }
        for g in prefs?.customGroups ?? [] where !g.isEmpty { set.insert(g) }
        return set.sorted { a, b in
            if a == BuiltInGroup.default { return true }
            if b == BuiltInGroup.default { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    func allTags(from books: [Book], prefs: ShelfPreferences?) -> [String] {
        var set = Set(prefs?.knownTags ?? [])
        for b in books {
            for t in b.tags where !t.isEmpty { set.insert(t) }
        }
        return set.sorted()
    }

    func parseTagsField(_ raw: String) -> [String] {
        raw
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Local file import

    /// 从 fileImporter completion 同步调用。
    /// 关键点：必须在 completion 尚未返回时就取得 Security Scope；否则“文件”App
    /// 提供的 URL 可能在异步 Task 开始前失效，表现为选文件后没有结果。
    func beginLocalImport(_ urls: [URL], context: ModelContext) {
        guard !urls.isEmpty else {
            showImportReport(
                title: String(localized: "没有选择文件"),
                message: String(localized: "请在“文件”中选择 TXT 或 EPUB 后重试。"),
                details: [],
                isSuccess: false
            )
            return
        }
        guard !isImporting else { return }

        isImporting = true
        importErrorMessage = nil
        importSuccessMessage = nil
        importReport = nil
        importProgressText = String(localized: "正在准备文件")
        importProgressDetail = urls.map(\.lastPathComponent).joined(separator: "、")

        // P0: fileImporter completion 返回后，安全作用域可能立即失效。
        // 所以此处同步复制到 Caches，异步阶段只读取 App 自己的副本。
        var staged: [(filename: String, url: URL)] = []
        var stagingFailures: [String] = []
        for sourceURL in urls {
            let name = sourceURL.lastPathComponent.isEmpty
                ? String(localized: "未命名文件")
                : sourceURL.lastPathComponent
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { sourceURL.stopAccessingSecurityScopedResource() }
            }
            // 返回 false 不等于一定无法读：有些来自“文件”的 URL 不需要额外 scope。
            // 统一尝试暂存；失败时才向用户给出可复制的诊断信息。
            do {
                let stagedURL = try BookImportService.stageSecurityScopedFile(sourceURL)
                staged.append((name, stagedURL))
            } catch {
                stagingFailures.append("\(name)：\(diagnosticMessage(for: error))")
            }
        }

        guard !staged.isEmpty else {
            isImporting = false
            importProgressText = nil
            importProgressDetail = nil
            importErrorMessage = stagingFailures.joined(separator: "\n")
            showImportReport(
                title: String(localized: "无法读取所选文件"),
                message: String(localized: "文件未能从“文件”App 复制到纯享阅读。"),
                details: stagingFailures,
                isSuccess: false
            )
            return
        }

        Task { [weak self] in
            guard let self else {
                for item in staged { try? FileManager.default.removeItem(at: item.url) }
                return
            }
            await self.performStagedImport(
                staged,
                stagingFailures: stagingFailures,
                context: context
            )
        }
    }

    /// 供非文件选择器来源复用；此路径无法保证外部 URL 的 scope 提前打开。
    func importLocalURLs(_ urls: [URL], context: ModelContext) async {
        guard !isImporting else { return }
        isImporting = true
        importErrorMessage = nil
        importSuccessMessage = nil
        importReport = nil
        importProgressText = String(localized: "正在准备导入")
        importProgressDetail = ""
        await performLocalImport(urls, context: context)
    }

    private func performLocalImport(_ urls: [URL], context: ModelContext) async {
        let staged = urls.map { (filename: $0.lastPathComponent, url: $0) }
        await performStagedImport(staged, stagingFailures: [], context: context)
    }

    private func performStagedImport(
        _ stagedURLs: [(filename: String, url: URL)],
        stagingFailures: [String],
        context: ModelContext
    ) async {
        defer {
            for item in stagedURLs { try? FileManager.default.removeItem(at: item.url) }
            isImporting = false
            importProgressText = nil
            importProgressDetail = nil
        }

        let tags = parseTagsField(pendingTags)
        let group = pendingGroup == BuiltInGroup.default ? nil : pendingGroup
        var importedTitles: [String] = []
        var failures = stagingFailures

        for (index, item) in stagedURLs.enumerated() {
            let filename = item.filename.isEmpty
                ? String(localized: "未命名文件")
                : item.filename
            importProgressText = String(localized: "正在导入 \(index + 1)/\(stagedURLs.count)")
            importProgressDetail = filename

            do {
                let parsed = try await BookImportService.parseStagedFile(url: item.url)
                importProgressText = String(localized: "正在保存《\(parsed.title)》")
                let book = try BookImportService.save(
                    parsed: parsed,
                    sourceType: .local,
                    sourceURL: nil,
                    group: group,
                    tags: tags,
                    into: context
                )
                importedTitles.append(book.title)
                BookUnderstandingCoordinator.shared.scheduleIfNeeded(book: book, context: context)
            } catch {
                failures.append("\(filename)：\(diagnosticMessage(for: error))")
            }
        }

        if !importedTitles.isEmpty {
            let message = failures.isEmpty
                ? String(localized: "已成功加入书架。")
                : String(localized: "部分文件已成功加入书架；其余失败原因如下。")
            importSuccessMessage = String(localized: "成功导入 \(importedTitles.count) 本书")
            showAddSheet = false
            showImportReport(
                title: importSuccessMessage ?? String(localized: "导入完成"),
                message: message,
                details: importedTitles.map { "✓ 《\($0)》" } + failures,
                isSuccess: failures.isEmpty
            )
        } else {
            let message = String(localized: "没有任何书籍被导入。请查看下方诊断信息。")
            importErrorMessage = failures.joined(separator: "\n")
            showImportReport(
                title: String(localized: "导入失败"),
                message: message,
                details: failures.isEmpty
                    ? [String(localized: "文件选择器未返回可读取的文件 URL。")]
                    : failures,
                isSuccess: false
            )
        }
    }

    func handleFilePickerFailure(_ error: Error) {
        let nsError = error as NSError
        // 用户取消选择不作为失败提示。
        guard nsError.code != NSUserCancelledError else { return }
        showImportReport(
            title: String(localized: "无法打开文件"),
            message: String(localized: "“文件”App 未能把所选文件交给纯享阅读。"),
            details: [diagnosticMessage(for: error)],
            isSuccess: false
        )
    }

    func dismissImportReport() {
        importReport = nil
        importErrorMessage = nil
        importSuccessMessage = nil
    }

    private func showImportReport(
        title: String,
        message: String,
        details: [String],
        isSuccess: Bool
    ) {
        importReport = ImportReport(
            title: title,
            message: message,
            details: details,
            isSuccess: isSuccess
        )
    }

    private func diagnosticMessage(for error: Error) -> String {
        let userMessage = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let nsError = error as NSError
        return "\(userMessage)\n\(String(localized: "诊断代码"))：\(nsError.domain) (\(nsError.code))"
    }

    // MARK: - URL import

    func importFromURL(context: ModelContext) async {
        isImporting = true
        importErrorMessage = nil
        importSuccessMessage = nil
        defer { isImporting = false }

        let tags = parseTagsField(pendingTags)
        let group = pendingGroup == BuiltInGroup.default ? nil : pendingGroup
        let urlText = urlString

        do {
            let parsed = try await BookImportService.parseRemoteURL(urlText)
            let book = try BookImportService.save(
                parsed: parsed,
                sourceType: .url,
                sourceURL: urlText,
                group: group,
                tags: tags,
                into: context
            )
            BookUnderstandingCoordinator.shared.scheduleIfNeeded(book: book, context: context)
            urlString = ""
            showURLImporter = false
            showAddSheet = false
            importSuccessMessage = String(localized: "成功导入《\(book.title)》")
        } catch {
            importErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func delete(_ book: Book, context: ModelContext) {
        do {
            try BookImportService.deleteBook(book, context: context)
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    func updateMeta(
        _ book: Book,
        title: String,
        author: String,
        group: String?,
        tags: [String],
        context: ModelContext
    ) {
        book.title = title
        book.author = author
        book.group = group
        book.tags = tags
        try? context.save()
    }
}
