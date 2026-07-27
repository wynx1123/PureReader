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
