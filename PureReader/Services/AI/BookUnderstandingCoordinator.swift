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
    func scheduleIfNeeded(book: Book, context _: ModelContext) {
        guard AIConfig.isRewriteConfigured, AIConfig.enableBookUnderstanding else { return }
        let bookID = book.id
        if tasks[bookID] != nil { return }

        // 快照构建也延迟到任务开始后，避免导入完成或打开阅读器的同步路径卡顿。
        let task = Task { @MainActor [weak self, weak book] in
            guard let self else { return }
            guard let book else {
                self.tasks[bookID] = nil
                return
            }

            await Task.yield()
            let chapters = (book.chapters ?? []).sorted { $0.index < $1.index }
            let wordCount = chapters.reduce(0) { $0 + $1.content.count }
            let mode = AIConfig.isEmbeddingConfigured
                ? IndexingMode.determine(wordCount: wordCount)
                : .skip
            // 有脏批次说明改写后锚点已过时，需要重建（未脏的批次仍走磁盘缓存）。
            let hasAnchors = BookMemoryAnchorStore.loadAnchors(bookID: bookID) != nil
                && !BookMemoryAnchorStore.hasDirtyBatches(bookID: bookID)
            let snaps = chapters.map {
                BookDigestPipeline.ChapterSnapshot(
                    id: $0.id,
                    index: $0.index,
                    title: $0.title,
                    content: $0.content
                )
            }
            let title = book.title

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

    /// 释放某本书常驻内存的向量索引与锚点。
    ///
    /// 每个索引持有全部 chunk 原文和 float 向量，长篇可达数十 MB；连续打开多本书
    /// 而不驱逐会持续增长。磁盘缓存仍在，下次需要时会重新加载。
    func releaseCaches(for bookID: UUID) {
        guard tasks[bookID] == nil else { return }
        indices[bookID] = nil
        anchorsCache[bookID] = nil
    }

    /// 删书时清理内存与磁盘上的全部 AI 派生数据。
    func purge(bookID: UUID) {
        tasks[bookID]?.cancel()
        tasks[bookID] = nil
        indices[bookID] = nil
        anchorsCache[bookID] = nil
        if case .running(let id, _, _) = state, id == bookID {
            state = .idle
        }
        try? FileManager.default.removeItem(at: BookVectorIndex.diskURL(for: bookID))
        BookMemoryAnchorStore.removeAll(bookID: bookID)
    }

    /// 改写后增量更新索引与 batch dirty。
    ///
    /// 只把受影响的批次标脏。锚点本身保留 —— 它是全书级摘要，单段改写不会让它失效，
    /// 而重建一次要跑「批次摘要 + 全量锚点提取」两轮 LLM 调用。锚点会在下次
    /// `scheduleIfNeeded` 发现脏批次时统一重建。
    func onChapterRewritten(bookID: UUID, chapterID: UUID, chapterIndex: Int, content: String) {
        BookMemoryAnchorStore.markBatchDirty(bookID: bookID, chapterIndex: chapterIndex)
        guard AIConfig.isEmbeddingConfigured else { return }
        Task { [weak self] in
            guard let self else { return }
            let existing = await MainActor.run { self.indices[bookID] }
            let index = existing ?? BookVectorIndex()
            do {
                if existing == nil {
                    let loaded = await index.loadFromDisk(bookID: bookID)
                    if !loaded { return }
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
            var failures: [String] = []
            if needIndex {
                await MainActor.run {
                    state = .running(
                        bookID: bookID,
                        progress: 0.05,
                        stage: String(localized: "构建语义索引…")
                    )
                }
                let chapterTuples = snaps.map { (id: $0.id, index: $0.index, content: $0.content) }
                do {
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
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Embedding 不兼容或暂时失败时，继续生成不依赖向量的全书记忆。
                    failures.append(String(localized: "语义索引：\(error.localizedDescription)"))
                }
            }

            let indexedEntryCount = await index.entryCount
            let indexReady = mode == .skip || indexedEntryCount > 0
            if indexReady {
                await MainActor.run { self.indices[bookID] = index }
            }

            if needAnchors {
                await MainActor.run {
                    state = .running(
                        bookID: bookID,
                        progress: 0.55,
                        stage: String(localized: "提取记忆锚点…")
                    )
                }
                let pipeline = BookDigestPipeline()
                do {
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
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append(String(localized: "记忆锚点：\(error.localizedDescription)"))
                }
            }

            let anchorsReady = !needAnchors
                || BookMemoryAnchorStore.loadAnchors(bookID: bookID) != nil
            await MainActor.run {
                if indexReady || anchorsReady {
                    state = .done(bookID: bookID)
                } else {
                    state = .failed(
                        bookID: bookID,
                        message: failures.joined(separator: "\n")
                    )
                }
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
