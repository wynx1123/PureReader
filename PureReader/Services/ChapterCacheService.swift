import Foundation
import SwiftData

/// 整本书正文缓存：后台批量抓取在线章节正文并持久化到书库。
/// 适合小说站书籍「一次缓存、离线畅读」的场景。
///
/// 设计要点：
/// - 并发上限 3，避免触发书站限流（签名站/防盗链站对突发并发敏感）
/// - 已缓存（content 非空）章节自动跳过，可断点续传式反复调用
/// - 单章失败不中断整体，最终返回成功/失败统计
/// - 每批落盘一次 SwiftData，进度回调驱动 UI 刷新
enum ChapterCacheService {

    struct CacheOutcome: Sendable {
        var cached: Int      // 本次新缓存成功
        var skipped: Int     // 本来就有内容
        var failed: Int      // 抓取失败
        var total: Int
    }

    /// 书是否支持整本缓存（在线书：存在带 sourceURL 的章节）
    static func isCacheable(_ book: Book) -> Bool {
        (book.chapters ?? []).contains { chapter in
            guard let url = chapter.sourceURL else { return false }
            return !url.isEmpty
        }
    }

    /// 已缓存章节数（content 非空）
    static func cachedCount(_ book: Book) -> Int {
        (book.chapters ?? []).filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    /// 解析书籍对应的书源快照（与 ReaderViewModel 同源逻辑）
    @MainActor
    private static func resolveSource(for book: Book, context: ModelContext) -> BookSourceSnapshot? {
        let all = (try? context.fetch(FetchDescriptor<BookSource>())) ?? []
        if let id = book.bookSourceID, let exact = all.first(where: { $0.id == id }) {
            return BookSourceSnapshot(exact)
        }
        if let name = book.sourceName, let match = all.first(where: { $0.name == name }) {
            return BookSourceSnapshot(match)
        }
        return nil
    }

    /// 批量缓存整本书正文。
    /// - Parameters:
    ///   - progress: 主线程回调 (已完成数, 总数)
    ///   - shouldCancel: 返回 true 时中断（如视图被关闭）
    /// - Returns: 统计结果
    @MainActor
    static func cacheAllChapters(
        of book: Book,
        context: ModelContext,
        progress: (@MainActor (Int, Int) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil
    ) async -> CacheOutcome {
        let chapters = (book.chapters ?? []).sorted { $0.index < $1.index }
        let total = chapters.count
        var outcome = CacheOutcome(cached: 0, skipped: 0, failed: 0, total: total)

        guard let snapshot = resolveSource(for: book, context: context) else {
            return outcome
        }

        // 待抓章节（跳过已有内容的）
        let pending = chapters.filter {
            guard let url = $0.sourceURL, !url.isEmpty else { return false }
            return $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        outcome.skipped = total - pending.count
        progress?(outcome.skipped, total)
        guard !pending.isEmpty else { return outcome }

        let concurrency = 3
        var cursor = 0
        var finished = 0

        await withTaskGroup(of: (UUID, String?).self) { group in
            // 维持固定并发窗口
            func enqueueNext() {
                guard cursor < pending.count else { return }
                let chapter = pending[cursor]
                cursor += 1
                let chapterID = chapter.id
                let url = chapter.sourceURL ?? ""
                group.addTask {
                    let text = try? await BookSourceEngine.fetchContent(
                        chapterURL: url,
                        source: snapshot
                    )
                    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return (chapterID, trimmed.isEmpty ? nil : trimmed)
                }
            }

            for _ in 0..<min(concurrency, pending.count) { enqueueNext() }

            for await (chapterID, text) in group {
                if shouldCancel?() == true {
                    group.cancelAll()
                    break
                }
                finished += 1
                if let text,
                   let chapter = chapters.first(where: { $0.id == chapterID }) {
                    chapter.content = text
                    outcome.cached += 1
                } else {
                    outcome.failed += 1
                }
                // 每 5 章落盘 + 报进度，平衡 IO 与 UI 流畅度
                if finished % 5 == 0 || finished == pending.count {
                    try? context.save()
                    progress?(outcome.skipped + finished, total)
                }
                enqueueNext()
            }
        }

        try? context.save()
        progress?(outcome.skipped + outcome.cached + outcome.failed, total)
        return outcome
    }
}
