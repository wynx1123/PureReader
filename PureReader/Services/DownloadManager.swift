import Foundation
import SwiftData
import Observation
import OSLog

// MARK: - DownloadManager

/// 统一下载任务管理器。
///
/// 负责：
/// - 下载队列管理（入队、暂停、恢复、取消、重试）
/// - 任务进度持久化（App 重启后可恢复）
/// - 同书去重（同一本书最多 1 个运行任务）
/// - 每本书最多 3 个章节并发请求（由 OnlineLibraryService 控制）
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var tasks: [DownloadTaskSnapshot] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Public API

    /// 当前是否有运行中的任务。
    var hasRunningTasks: Bool {
        tasks.contains { $0.status == .running }
    }

    /// 当前是否有非终止状态的任务（运行中或暂停）。
    var hasActiveTasks: Bool {
        tasks.contains { !$0.isTerminal }
    }

    /// 当前是否有暂停的任务。
    var hasPausedTasks: Bool {
        tasks.contains { $0.status == .paused }
    }

    /// 指定书籍是否有运行中或排队中的任务。
    func hasActiveTask(for bookID: UUID) -> Bool {
        tasks.contains { $0.bookID == bookID && !$0.isTerminal }
    }

    /// 创建并开始一个下载任务。
    /// 如果同一本书已有运行中任务，则返回已有任务 ID 而不创建新任务。
    @discardableResult
    func enqueue(
        book: Book,
        chapters: [Chapter],
        source: BookSourceSnapshot,
        kind: DownloadTaskKind = .wholeBook,
        startIndex: Int = 0,
        endIndex: Int = 0,
        context: ModelContext
    ) -> UUID {
        // 检查是否已有运行中任务
        if let existing = tasks.first(where: { $0.bookID == book.id && !$0.isTerminal }) {
            return existing.id
        }

        // 过滤有效章节（必须包含 sourceURL）
        let validChapters = chapters.filter {
            guard let url = $0.sourceURL else { return false }
            return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !validChapters.isEmpty else { return UUID() }

        let total = validChapters.count
        let task = DownloadTask(
            bookID: book.id,
            bookTitle: book.title,
            kind: kind,
            status: .queued,
            startIndex: startIndex,
            endIndex: endIndex > 0 ? endIndex : chapters.count - 1,
            totalCount: total
        )
        context.insert(task)

        // 创建章节级任务记录
        for chapter in validChapters {
            let item = DownloadTaskItem(
                taskID: task.id,
                chapterID: chapter.id,
                chapterIndex: chapter.index,
                status: .none
            )
            context.insert(item)
        }

        do {
            try context.save()
        } catch {
            Logger.download.error("Failed to persist enqueued task: \(error.localizedDescription)")
        }

        let snapshot = DownloadTaskSnapshot(task)
        tasks.append(snapshot)

        startTask(task, book: book, chapters: validChapters, source: source, context: context)
        return task.id
    }

    /// 暂停指定任务。
    func pause(taskID: UUID, context: ModelContext) {
        guard let t = tasks.first(where: { $0.id == taskID }),
              t.status == .running || t.status == .queued else { return }
        updateStatus(taskID: taskID, to: .paused, context: context)
        activeTasks[taskID]?.cancel()
        activeTasks[taskID] = nil
    }

    /// 恢复暂停的任务。
    func resume(taskID: UUID, book: Book, chapters: [Chapter], source: BookSourceSnapshot, context: ModelContext) {
        guard let t = tasks.first(where: { $0.id == taskID }),
              t.status == .paused else { return }
        updateStatus(taskID: taskID, to: .queued, context: context)
        startTask(
            fetchTask(taskID: taskID, context: context) ?? DownloadTask(bookID: book.id),
            book: book,
            chapters: chapters,
            source: source,
            context: context
        )
    }

    /// 取消指定任务（保留已成功的章节记录）。
    func cancel(taskID: UUID, context: ModelContext) {
        guard let t = tasks.first(where: { $0.id == taskID }),
              !t.isTerminal else { return }
        activeTasks[taskID]?.cancel()
        activeTasks[taskID] = nil
        updateStatus(taskID: taskID, to: .cancelled, context: context)
        // 将未完成的章节项标记为取消
        markIncompleteItemsCancelled(taskID: taskID, context: context)
    }

    /// 取消某本书的所有任务。
    func cancelAllForBook(_ bookID: UUID, context: ModelContext) {
        for task in tasks where task.bookID == bookID && !task.isTerminal {
            cancel(taskID: task.id, context: context)
        }
    }

    /// 重试失败章节。
    func retryFailed(taskID: UUID, book: Book, chapters: [Chapter], source: BookSourceSnapshot, context: ModelContext) {
        guard let t = tasks.first(where: { $0.id == taskID }),
              t.status == .completedWithFailures || t.status == .failed else { return }
        updateStatus(taskID: taskID, to: .queued, context: context)
        updateCounts(taskID: taskID, completed: 0, failed: 0, context: context)
        startTask(
            fetchTask(taskID: taskID, context: context) ?? DownloadTask(bookID: book.id),
            book: book,
            chapters: chapters,
            source: source,
            context: context
        )
    }

    /// 从 SwiftData 恢复所有未完成的任务（App 启动时调用）。
    func restoreTasks(context: ModelContext) {
        let descriptor = FetchDescriptor<DownloadTask>(
            predicate: #Predicate { task in
                task.statusRaw != "completed"
                    && task.statusRaw != "cancelled"
                    && task.statusRaw != "failed"
            }
        )
        guard let pending = try? context.fetch(descriptor) else { return }
        for task in pending {
            // 将运行中/排队中的任务重置为 paused，等待用户手动恢复
            task.status = .paused
            task.lastErrorMessage = String(localized: "上次 App 退出时任务未完成，已暂停。请手动恢复。")
            task.updatedAt = Date()
            let snapshot = DownloadTaskSnapshot(task)
            if !tasks.contains(where: { $0.id == task.id }) {
                tasks.append(snapshot)
            }
        }
        do {
            try context.save()
        } catch {
            Logger.download.error("Failed to persist restored tasks: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func startTask(
        _ task: DownloadTask,
        book: Book,
        chapters: [Chapter],
        source: BookSourceSnapshot,
        context: ModelContext
    ) {
        updateStatus(taskID: task.id, to: .running, context: context)

        let taskID = task.id
        let total = task.totalCount

        let downloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.activeTasks[taskID] = nil
            }

            let completed = await OnlineLibraryService.downloadAllChapters(
                book: book,
                source: source,
                chapters: chapters
            ) { [weak self] progress in
                guard let self else { return }
                self.updateCounts(
                    taskID: taskID,
                    completed: progress.completed,
                    failed: progress.failed,
                    context: context
                )
            }

            if Task.isCancelled { return }

            let failed = total - completed
            if failed > 0 {
                self.updateStatus(taskID: taskID, to: .completedWithFailures, context: context)
                self.updateErrorMessage(
                    taskID: taskID,
                    message: String(localized: "\(completed) 成功，\(failed) 失败"),
                    context: context
                )
            } else {
                self.updateStatus(taskID: taskID, to: .completed, context: context)
            }
            do {
                try context.save()
            } catch {
                Logger.download.error("Failed to save task completion: \(error.localizedDescription)")
            }
        }
        activeTasks[taskID] = downloadTask
    }

    // MARK: - State sync helpers

    private func updateStatus(taskID: UUID, to status: DownloadTaskStatus, context: ModelContext) {
        if let index = tasks.firstIndex(where: { $0.id == taskID }) {
            let old = tasks[index]
            tasks[index] = DownloadTaskSnapshot(
                id: old.id, bookID: old.bookID, bookTitle: old.bookTitle,
                kind: old.kind, status: status,
                completedCount: old.completedCount, failedCount: old.failedCount,
                totalCount: old.totalCount,
                createdAt: old.createdAt, updatedAt: Date(),
                lastErrorMessage: old.lastErrorMessage
            )
        }
        // 同步到 SwiftData
        if let modelTask = fetchTask(taskID: taskID, context: context) {
            modelTask.statusRaw = status.rawValue
            modelTask.updatedAt = Date()
        }
    }

    private func updateCounts(taskID: UUID, completed: Int, failed: Int, context: ModelContext) {
        if let index = tasks.firstIndex(where: { $0.id == taskID }) {
            let old = tasks[index]
            tasks[index] = DownloadTaskSnapshot(
                id: old.id, bookID: old.bookID, bookTitle: old.bookTitle,
                kind: old.kind, status: old.status,
                completedCount: completed, failedCount: failed,
                totalCount: old.totalCount,
                createdAt: old.createdAt, updatedAt: Date(),
                lastErrorMessage: old.lastErrorMessage
            )
        }
        if let modelTask = fetchTask(taskID: taskID, context: context) {
            modelTask.completedCount = completed
            modelTask.failedCount = failed
            modelTask.updatedAt = Date()
        }
    }

    private func updateErrorMessage(taskID: UUID, message: String?, context: ModelContext) {
        if let index = tasks.firstIndex(where: { $0.id == taskID }) {
            let old = tasks[index]
            tasks[index] = DownloadTaskSnapshot(
                id: old.id, bookID: old.bookID, bookTitle: old.bookTitle,
                kind: old.kind, status: old.status,
                completedCount: old.completedCount, failedCount: old.failedCount,
                totalCount: old.totalCount,
                createdAt: old.createdAt, updatedAt: Date(),
                lastErrorMessage: message
            )
        }
        if let modelTask = fetchTask(taskID: taskID, context: context) {
            modelTask.lastErrorMessage = message
            modelTask.updatedAt = Date()
        }
    }

    private func fetchTask(taskID: UUID, context: ModelContext) -> DownloadTask? {
        var descriptor = FetchDescriptor<DownloadTask>(
            predicate: #Predicate { $0.id == taskID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// 将未完成的章节项标记为取消（保留已完成项）。
    private func markIncompleteItemsCancelled(taskID: UUID, context: ModelContext) {
        let descriptor = FetchDescriptor<DownloadTaskItem>(
            predicate: #Predicate { $0.taskID == taskID }
        )
        guard let items = try? context.fetch(descriptor) else { return }
        for item in items where item.status == .none || item.status == .downloading {
            item.status = .cancelled
        }
        try? context.save()
    }
}

// MARK: - Logger

extension Logger {
    static let download = Logger(subsystem: "com.wynx.PureReader", category: "download")
}