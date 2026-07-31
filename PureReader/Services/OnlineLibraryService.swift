import Foundation
import SwiftData

struct ChapterCatalogMerge: Sendable {
    let chapters: [SourceChapterItem]
    let newChapters: [SourceChapterItem]

    var addedCount: Int { newChapters.count }
}

struct ChapterCatalogAlignment: Sendable {
    struct Item: Sendable, Equatable {
        let key: String
        let title: String
        let url: String
        let isNew: Bool
        let isRetainedRemoteDeletion: Bool
    }

    let items: [Item]
    var addedCount: Int { items.lazy.filter(\.isNew).count }
}

enum OnlineLibraryError: LocalizedError {
    case notOnlineBook
    case sourceMissing
    case invalidScheme
    case responseTooLarge
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .notOnlineBook: return String(localized: "这不是网络书籍")
        case .sourceMissing: return String(localized: "找不到对应书源，请重新导入书源后重试")
        case .invalidScheme: return String(localized: "只允许下载 HTTP 或 HTTPS 地址")
        case .responseTooLarge: return String(localized: "章节响应超过 8 MB 安全上限")
        case .emptyContent: return String(localized: "章节正文为空")
        }
    }
}

enum OnlineLibraryService {
    static let maximumChapterBytes = 8 * 1024 * 1024

    /// Canonical identity used for update de-duplication. Fragments never identify
    /// server resources; scheme/host casing and default ports are normalized.
    static func stableChapterURL(_ raw: String) -> String? {
        guard var c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        c.scheme = scheme
        c.host = host
        c.fragment = nil
        if (scheme == "http" && c.port == 80) || (scheme == "https" && c.port == 443) { c.port = nil }
        if c.path.isEmpty { c.path = "/" }
        return c.url?.absoluteString
    }

    static func mergeCatalog(existingURLs: [String], fetched: [SourceChapterItem]) -> ChapterCatalogMerge {
        let existing = Set(existingURLs.compactMap(stableChapterURL))
        var seen = Set<String>()
        var all: [SourceChapterItem] = []
        var added: [SourceChapterItem] = []
        all.reserveCapacity(fetched.count)
        for item in fetched {
            guard let key = stableChapterURL(item.url), seen.insert(key).inserted else { continue }
            let normalized = SourceChapterItem(title: item.title, url: item.url, index: all.count)
            all.append(normalized)
            if !existing.contains(key) { added.append(normalized) }
        }
        return ChapterCatalogMerge(chapters: all, newChapters: added)
    }

    /// Aligns a local catalog to the remote order without throwing away local-only
    /// chapters. Remote matches update title/URL in-place at the call site; remote
    /// insertions appear at their true position. Entries absent remotely are kept,
    /// in their previous relative order, after the authoritative remote catalog.
    static func alignCatalog(existingURLs: [String], fetched: [SourceChapterItem]) -> ChapterCatalogAlignment {
        let existingEntries = existingURLs.compactMap { raw in
            stableChapterURL(raw).map { (key: $0, url: raw) }
        }
        let existingKeys = existingEntries.map(\.key)
        let existing = Set(existingKeys)
        var remoteKeys = Set<String>()
        var items: [ChapterCatalogAlignment.Item] = []
        for item in fetched {
            guard let key = stableChapterURL(item.url), remoteKeys.insert(key).inserted else { continue }
            items.append(.init(
                key: key,
                title: item.title,
                url: item.url,
                isNew: !existing.contains(key),
                isRetainedRemoteDeletion: false
            ))
        }
        for entry in existingEntries where !remoteKeys.contains(entry.key) {
            items.append(.init(
                key: entry.key,
                title: "",
                url: entry.url,
                isNew: false,
                isRetainedRemoteDeletion: true
            ))
        }
        return ChapterCatalogAlignment(items: items)
    }

    /// A generation captured before async work may mutate cache only while it is
    /// still current. This tiny pure helper is shared by production guards/tests.
    static func generationIsCurrent(captured: UInt64, current: UInt64) -> Bool {
        captured == current
    }

    static func firstUnreadIndex(totalChapters: Int, highestReadIndex: Int, currentIndex: Int) -> Int? {
        guard totalChapters > 0 else { return nil }
        let next = highestReadIndex >= 0 ? highestReadIndex + 1 : max(0, currentIndex)
        return next < totalChapters ? next : nil
    }

    static func cacheRelativePath(bookID: UUID, chapterID: UUID) -> String {
        "OfflineChapters/\(bookID.uuidString)/\(chapterID.uuidString).txt"
    }

    static func cachedText(relativePath: String) throws -> String {
        let url = try cacheURL(relativePath: relativePath)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumChapterBytes else { throw OnlineLibraryError.responseTooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    static func writeCachedText(_ text: String, bookID: UUID, chapterID: UUID) throws -> String {
        let data = Data(text.utf8)
        guard !data.isEmpty else { throw OnlineLibraryError.emptyContent }
        guard data.count <= maximumChapterBytes else { throw OnlineLibraryError.responseTooLarge }
        let relative = cacheRelativePath(bookID: bookID, chapterID: chapterID)
        let url = try cacheURL(relativePath: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return relative
    }

    static func purgeCache(bookID: UUID) throws {
        let base = try applicationSupportDirectory()
            .appendingPathComponent("OfflineChapters", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: base.path) { try FileManager.default.removeItem(at: base) }
    }

    static func removeCachedText(relativePath: String) throws {
        let url = try cacheURL(relativePath: relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Full-book download

    /// 全本缓存下载进度。
    struct DownloadProgress: Sendable {
        var completed: Int
        var total: Int
        var failed: Int
        var currentChapter: String

        var fractionCompleted: Double {
            total > 0 ? Double(completed + failed) / Double(total) : 0
        }

        var isFinished: Bool {
            (completed + failed) >= total
        }
    }

    /// 整本下载：遍历所有章节，抓取正文并写入离线缓存。
    ///
    /// - Parameters:
    ///   - book: 要下载的书籍
    ///   - source: 该书对应的书源快照
    ///   - chapters: 章节列表（已排序）
    ///   - onProgress: 每完成一章回调一次进度
    /// - Returns: 成功缓存的章节数
    @MainActor
    static func downloadAllChapters(
        book: Book,
        source: BookSourceSnapshot,
        chapters: [Chapter],
        onProgress: @escaping @MainActor (DownloadProgress) -> Void
    ) async -> Int {
        let candidates = chapters.filter { $0.sourceURL != nil && !$0.sourceURL!.isEmpty }
        guard !candidates.isEmpty else { return 0 }

        var completed = 0
        var failed = 0
        let total = candidates.count
        let bookURL = book.sourceURL
        let bookID = book.id

        // 缓存有效性检查结果：每个索引对应的缓存是否有效
        // (index, isValidCache: Bool, stalePath: String?)
        typealias CacheCheck = (Int, Bool, String?)

        await withTaskGroup(of: CacheCheck.self) { group in
            let maxConcurrent = 3
            var running = 0
            var nextIndex = 0

            func fillGroup() {
                while running < maxConcurrent, nextIndex < candidates.count {
                    let idx = nextIndex
                    let chapter = candidates[idx]
                    nextIndex += 1
                    running += 1
                    group.addTask {
                        // 检查已有缓存是否有效——只有实际读取成功才算有效
                        if let path = chapter.offlineCachePath, !path.isEmpty {
                            do {
                                _ = try OnlineLibraryService.cachedText(relativePath: path)
                                return (idx, true, nil) // 缓存有效，无需重新下载
                            } catch {
                                // 缓存损坏/文件丢失，记下失效路径，继续重新下载
                                return (idx, false, path)
                            }
                        }
                        // 无缓存，正常下载
                        do {
                            let text = try await BookSourceEngine.fetchContent(
                                chapterURL: chapter.sourceURL!,
                                source: source,
                                currentBookURL: bookURL
                            )
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { throw BookSourceError.empty }
                            let newPath = try OnlineLibraryService.writeCachedText(
                                trimmed,
                                bookID: bookID,
                                chapterID: chapter.id
                            )
                            return (idx, true, newPath)
                        } catch {
                            return (idx, false, nil)
                        }
                    }
                }
            }

            fillGroup()
            for await (idx, isSuccess, path) in group {
                running -= 1

                if isSuccess {
                    completed += 1
                    // 回写缓存路径到 SwiftData 模型，确保阅读器能找到离线文件
                    let chapter = candidates[idx]
                    if let path {
                        chapter.offlineCachePath = path
                        chapter.offlineCachedAt = Date()
                    }
                    // 已有缓存但未重新下载的情况：path 为 nil，
                    // 此时 offlineCachePath 和 offlineCachedAt 保持不变
                } else {
                    failed += 1
                    // 清理失效的缓存引用
                    let chapter = candidates[idx]
                    if path != nil {
                        // path 非 nil 表示旧缓存损坏，清理引用
                        chapter.offlineCachePath = nil
                        chapter.offlineCachedAt = nil
                    }
                }

                let chapterTitle = idx < candidates.count
                    ? candidates[idx].title
                    : ""
                await onProgress(DownloadProgress(
                    completed: completed,
                    total: total,
                    failed: failed,
                    currentChapter: chapterTitle
                ))
                fillGroup()
            }
        }

        return completed
    }

    /// 整本导出为 TXT 文件（用于系统分享菜单）。
    /// 在线书籍优先使用 chapter.content，若为空则尝试读取离线缓存。
    @MainActor
    static func exportFullBookAsTXT(book: Book, chapters: [Chapter]) throws -> URL {
        let sorted = chapters.sorted { $0.index < $1.index }
        var parts: [String] = []
        parts.append("《\(book.title)》")
        if !book.author.isEmpty {
            parts.append(String(localized: "作者：\(book.author)"))
        }
        parts.append(String(repeating: "-", count: 40))
        parts.append("")

        for ch in sorted {
            let text: String
            let memoryContent = ch.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !memoryContent.isEmpty {
                text = memoryContent
            } else if let path = ch.offlineCachePath, !path.isEmpty {
                // 在线书籍章节正文可能未加载到内存，回退到离线缓存
                if let cached = try? OnlineLibraryService.cachedText(relativePath: path),
                   !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = cached
                } else {
                    continue // 缓存也无效，跳过该章节
                }
            } else {
                continue // 无内容，跳过
            }
            parts.append(ch.title)
            parts.append("")
            parts.append(text)
            parts.append("")
            parts.append("")
        }

        let text = parts.joined(separator: "\n")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let safeTitle = book.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let filename = safeTitle.isEmpty
            ? "export-\(book.id.uuidString.prefix(8)).txt"
            : "\(safeTitle)-\(book.id.uuidString.prefix(8)).txt"
        let url = dir.appendingPathComponent(filename)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func cacheURL(relativePath: String) throws -> URL {
        let base = try applicationSupportDirectory().standardizedFileURL
        let target = base.appendingPathComponent(relativePath).standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
        return target
    }

    private static func applicationSupportDirectory() throws -> URL {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}
