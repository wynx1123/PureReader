import Foundation
import SwiftData

// MARK: - CacheIntegrityReport

/// 缓存完整性检查报告。
struct CacheIntegrityReport: Sendable {
    let bookID: UUID
    let bookTitle: String
    let totalChapters: Int
    let validCount: Int
    let missingCount: Int
    let invalidCount: Int
    let orphanFileCount: Int
    let totalBytes: Int64

    var isHealthy: Bool {
        missingCount == 0 && invalidCount == 0 && orphanFileCount == 0
    }

    var summary: String {
        var parts: [String] = []
        parts.append(String(localized: "总计 \(totalChapters) 章"))
        if validCount > 0 { parts.append(String(localized: "\(validCount) 有效")) }
        if missingCount > 0 { parts.append(String(localized: "\(missingCount) 缺失")) }
        if invalidCount > 0 { parts.append(String(localized: "\(invalidCount) 无效")) }
        if orphanFileCount > 0 { parts.append(String(localized: "\(orphanFileCount) 孤立文件")) }
        return parts.joined(separator: "，")
    }
}

// MARK: - CacheIntegrityService

/// 缓存完整性服务。
///
/// 检查 SwiftData 中记录的缓存引用与文件系统实际状态的一致性。
/// 不修改数据，只生成报告。
enum CacheIntegrityService {

    // MARK: - Single book

    /// 检查单本书的缓存完整性。
    static func checkBook(_ book: Book) -> CacheIntegrityReport {
        let chapters = (book.chapters ?? []).sorted { $0.index < $1.index }
        let total = chapters.count
        var valid = 0
        var missing = 0
        var invalid = 0
        var totalBytes: Int64 = 0

        for chapter in chapters {
            let result = validateChapterCache(chapter)
            switch result {
            case .valid(let bytes):
                valid += 1
                totalBytes += bytes
            case .missing:
                missing += 1
            case .invalid:
                invalid += 1
            }
        }

        let orphans = findOrphanFiles(for: book.id)

        return CacheIntegrityReport(
            bookID: book.id,
            bookTitle: book.title,
            totalChapters: total,
            validCount: valid,
            missingCount: missing,
            invalidCount: invalid,
            orphanFileCount: orphans,
            totalBytes: totalBytes
        )
    }

    /// 检查单本书的缓存完整性，并返回每章的详细状态。
    static func checkBookDetailed(
        _ book: Book
    ) -> (
        report: CacheIntegrityReport,
        details: [ChapterCacheDetail]
    ) {
        let chapters = (book.chapters ?? []).sorted { $0.index < $1.index }
        let total = chapters.count
        var valid = 0
        var missing = 0
        var invalid = 0
        var totalBytes: Int64 = 0
        var details: [ChapterCacheDetail] = []

        for chapter in chapters {
            let result = validateChapterCache(chapter)
            switch result {
            case .valid(let bytes):
                valid += 1
                totalBytes += bytes
            case .missing:
                missing += 1
            case .invalid:
                invalid += 1
            }
            details.append(ChapterCacheDetail(
                chapterID: chapter.id,
                chapterIndex: chapter.index,
                chapterTitle: chapter.title,
                validation: result
            ))
        }

        let orphans = findOrphanFiles(for: book.id)

        let report = CacheIntegrityReport(
            bookID: book.id,
            bookTitle: book.title,
            totalChapters: total,
            validCount: valid,
            missingCount: missing,
            invalidCount: invalid,
            orphanFileCount: orphans,
            totalBytes: totalBytes
        )
        return (report, details)
    }

    // MARK: - All books

    /// 检查所有在线书籍的缓存完整性。
    @MainActor
    static func checkAllBooks(context: ModelContext) -> [CacheIntegrityReport] {
        let descriptor = FetchDescriptor<Book>()
        guard let books = try? context.fetch(descriptor) else { return [] }
        return books
            .filter { $0.sourceType == .booksource }
            .map { checkBook($0) }
    }

    // MARK: - Cleanup

    /// 清理单本书的无效缓存（缺失引用和损坏文件）。
    /// - Returns: 清理的章节数
    @MainActor
    static func cleanupInvalid(for book: Book, context: ModelContext) -> Int {
        let chapters = (book.chapters ?? []).sorted { $0.index < $1.index }
        var cleaned = 0

        for chapter in chapters {
            let result = validateChapterCache(chapter)
            switch result {
            case .valid:
                continue
            case .missing, .invalid:
                // 清理无效的缓存引用
                if chapter.offlineCachePath != nil {
                    chapter.offlineCachePath = nil
                    chapter.offlineCachedAt = nil
                    cleaned += 1
                }
            }
        }

        if cleaned > 0 {
            try? context.save()
        }
        return cleaned
    }

    /// 清理孤立缓存文件（文件存在但无数据库引用）。
    /// - Returns: 清理的文件数
    static func cleanupOrphanFiles(for bookID: UUID) -> Int {
        let orphans = findOrphanFiles(for: bookID)
        var cleaned = 0
        for relativePath in orphans {
            do {
                let url = try OnlineLibraryService.cacheURL(relativePath: relativePath)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    cleaned += 1
                }
            } catch {
                continue
            }
        }
        return cleaned
    }
}

// MARK: - ChapterCacheValidation

/// 章节缓存验证结果。
enum ChapterCacheValidation: Sendable {
    case valid(Int64)
    case missing
    case invalid
}

/// 章节缓存详情（值类型，可跨 Actor 传递）。
struct ChapterCacheDetail: Sendable {
    let chapterID: UUID
    let chapterIndex: Int
    let chapterTitle: String
    let validation: ChapterCacheValidation
}

// MARK: - Private

private extension CacheIntegrityService {

    /// 验证单个章节的缓存状态。
    private static func validateChapterCache(_ chapter: Chapter) -> ChapterCacheValidation {
        guard let path = chapter.offlineCachePath, !path.isEmpty else {
            return .missing
        }

        do {
            let url = try OnlineLibraryService.cacheURL(relativePath: path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let size = values.fileSize, size > 0,
                  size <= OnlineLibraryService.maximumChapterBytes else {
                return .invalid
            }
            // 验证内容可读且非空
            let text = try OnlineLibraryService.cachedText(relativePath: path)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .invalid
            }
            return .valid(Int64(size))
        } catch {
            return .missing
        }
    }

    /// 扫描缓存目录，返回没有数据库引用的文件相对路径。
    private static func findOrphanFiles(for bookID: UUID) -> [String] {
        guard let bookDir = try? applicationSupportDirectory()
            .appendingPathComponent("OfflineChapters", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true),
              FileManager.default.fileExists(atPath: bookDir.path),
              let fileNames = try? FileManager.default.contentsOfDirectory(atPath: bookDir.path) else {
            return []
        }

        return fileNames.compactMap { fileName -> String? in
            let relativePath = "OfflineChapters/\(bookID.uuidString)/\(fileName)"
            let uuidString = (fileName as NSString).deletingPathExtension
            guard UUID(uuidString: uuidString) != nil else { return nil }
            return relativePath
        }
    }

    private static func applicationSupportDirectory() throws -> URL {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}