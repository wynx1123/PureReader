import Foundation
import SwiftData

/// 全书理解协调器：后台静默跑向量索引 + 记忆锚点，不阻塞阅读
@MainActor
final class BookUnderstandingCoordinator {
    static let shared = BookUnderstandingCoordinator()

    enum JobState: Equatable {
        case idle
        case running(bookID: UUID, progress: Double, stage: String)
        case failed(bookID: UUID, message: String)
        case done(bookID: UUID)
    }

    private(set) var state: JobState = .idle
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var indices: [UUID: BookVectorIndex] = [:]
    private var anchorsCache: [UUID: BookMemoryAnchors] = [:]

    private init() {}

    // MARK: - Public API

    func vectorIndex(for bookID: UUID) -> BookVectorIndex? {
        indices[bookID]
    }

    func memoryAnchors(for bookID: UUID) -> BookMemoryAnchors? {
        if let cached = anchorsCache[bookID] { return cached }
        if let loaded = BookMemoryAnchorStore.loadAnchors(bookID: bookID) {
            anchorsCache[bookID] = loaded
            return loaded
        }
        return nil
    }

    /// 打开书籍 / 导入后调用：若已配置 API 且开启「AI理解本书」则后台消化
    func scheduleIfNeeded(book: Book, context: ModelContext) {
        guard AIConfig.isConfigured, AIConfig.enableBookUnderstanding else { return }
        let bookID = book.id
        if tasks[bookID] != nil { return }

        let chapters = (book.chapters ?? []).sorted { $0.index < $1.index }
        let wordCount = chapters.reduce(0) { $0 + $1.content.count }
        let mode = IndexingMode.determine(wordCount: wordCount)

        let hasAnchors = BookMemoryAnchorStore.loadAnchors(bookID: bookID) != nil
        let snaps = chapters.map {
            BookDigestPipeline.ChapterSnapshot(
                id: $0.id,
                index: $0.index,
                title: $0.title,
                content: $0.content
            )
        }
        let title = book.title

        // 异步预热磁盘索引；不在同步路径 await actor
        let task = Task { [weak self] in
            guard let self else { return }
            let index = BookVectorIndex()
            var hasIndex = mode == .skip
            if !hasIndex {
                hasIndex = await index.loadFromDisk(bookID: bookID)
            }

            if hasAnchors && hasIndex {
                await MainActor.run {
                    self.indices[bookID] = index
                    self.anchorsCache[bookID] = BookMemoryAnchorStore.loadAnchors(bookID: bookID)
                    self.state = .done(bookID: bookID)
                    self.tasks[bookID] = nil
                }
                return
            }

            await self.runPipeline(
                bookID: bookID,
                title: title,
                snaps: snaps,
                wordCount: wordCount,
                needIndex: !hasIndex && mode != .skip,
                needAnchors: !hasAnchors,
                mode: mode,
                warmIndex: hasIndex ? index : nil
            )
        }
        tasks[bookID] = task
    }

    func cancel(bookID: UUID) {
        tasks[bookID]?.cancel()
        tasks[bookID] = nil
        if case .running(let id, _, _) = state, id == bookID {
            state = .idle
        }
    }

    /// 改写后增量更新索引与 batch dirty
    func onChapterRewritten(bookID: UUID, chapterID: UUID, chapterIndex: Int, content: String) {
        BookMemoryAnchorStore.markBatchDirty(bookID: bookID, chapterIndex: chapterIndex)
        Task { [weak self] in
            guard let self else { return }
            let existing = await MainActor.run { self.indices[bookID] }
            let index = existing ?? BookVectorIndex()
            do {
                if await index.entryCount == 0 {
                    _ = await index.loadFromDisk(bookID: bookID)
                }
                try await index.invalidateChapter(
                    chapterID: chapterID,
                    chapterIndex: chapterIndex,
                    content: content
                )
                await MainActor.run { self.indices[bookID] = index }
            } catch {
                // 静默失败
            }
        }
    }

    // MARK: - Pipeline

    private func runPipeline(
        bookID: UUID,
        title: String,
        snaps: [BookDigestPipeline.ChapterSnapshot],
        wordCount: Int,
        needIndex: Bool,
        needAnchors: Bool,
        mode: IndexingMode,
        warmIndex: BookVectorIndex?
    ) async {
        await MainActor.run {
            state = .running(bookID: bookID, progress: 0, stage: String(localized: "准备中…"))
        }

        let index = warmIndex ?? BookVectorIndex()
        if warmIndex == nil {
            _ = await index.loadFromDisk(bookID: bookID)
        }

        do {
            if needIndex {
                await MainActor.run {
                    state = .running(
                        bookID: bookID,
                        progress: 0.05,
                        stage: String(localized: "构建语义索引…")
                    )
                }
                let chapterTuples = snaps.map { (id: $0.id, index: $0.index, content: $0.content) }
                try await index.build(
                    chapters: chapterTuples,
                    bookID: bookID,
                    mode: mode
                ) { p in
                    Task { @MainActor in
                        BookUnderstandingCoordinator.shared.state = .running(
                            bookID: bookID,
                            progress: 0.05 + p * 0.45,
                            stage: String(localized: "构建语义索引…")
                        )
                    }
                }
            }

            await MainActor.run { self.indices[bookID] = index }

            if needAnchors {
                await MainActor.run {
                    state = .running(
                        bookID: bookID,
                        progress: 0.55,
                        stage: String(localized: "提取记忆锚点…")
                    )
                }
                let pipeline = BookDigestPipeline()
                let anchors = try await pipeline.digest(
                    bookID: bookID,
                    bookTitle: title,
                    chapters: snaps
                ) { p in
                    Task { @MainActor in
                        BookUnderstandingCoordinator.shared.state = .running(
                            bookID: bookID,
                            progress: 0.55 + p * 0.45,
                            stage: String(localized: "提取记忆锚点…")
                        )
                    }
                }
                await MainActor.run {
                    self.anchorsCache[bookID] = anchors
                }
            }

            await MainActor.run {
                state = .done(bookID: bookID)
                tasks[bookID] = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                state = .idle
                tasks[bookID] = nil
            }
        } catch {
            await MainActor.run {
                state = .failed(bookID: bookID, message: error.localizedDescription)
                tasks[bookID] = nil
            }
        }
    }
}
