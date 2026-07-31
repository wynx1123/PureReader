import Foundation
import SwiftData

// MARK: - DownloadTask

/// 下载任务状态。
enum DownloadTaskStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case paused
    case cancelling
    case cancelled
    case completed
    case completedWithFailures
    case failed
}

/// 下载任务种类。
enum DownloadTaskKind: String, Codable, Sendable, CaseIterable {
    case currentChapter
    case nextTwenty
    case wholeBook
    case missingChapters
    case custom
}

/// 章节级缓存状态。
enum ChapterCacheStatus: String, Codable, Sendable, CaseIterable {
    case none
    case downloading
    case cached
    case failed
    case invalid
    case cancelled
}

// MARK: - DownloadTask (SwiftData)

/// 持久化下载任务，支持 App 重启后恢复。
@Model
final class DownloadTask {
    @Attribute(.unique) var id: UUID
    var bookID: UUID
    var bookTitle: String
    var kindRaw: String
    var statusRaw: String
    var requestedStartIndex: Int
    var requestedEndIndex: Int
    var completedCount: Int
    var failedCount: Int
    var totalCount: Int
    var createdAt: Date
    var updatedAt: Date
    var lastErrorMessage: String?

    var kind: DownloadTaskKind {
        get { DownloadTaskKind(rawValue: kindRaw) ?? .wholeBook }
        set { kindRaw = newValue.rawValue }
    }

    var status: DownloadTaskStatus {
        get { DownloadTaskStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    var fractionCompleted: Double {
        totalCount > 0 ? Double(completedCount + failedCount) / Double(totalCount) : 0
    }

    var isTerminal: Bool {
        switch status {
        case .completed, .completedWithFailures, .failed, .cancelled:
            return true
        case .queued, .running, .paused, .cancelling:
            return false
        }
    }

    init(
        id: UUID = UUID(),
        bookID: UUID,
        bookTitle: String = "",
        kind: DownloadTaskKind = .wholeBook,
        status: DownloadTaskStatus = .queued,
        startIndex: Int = 0,
        endIndex: Int = 0,
        totalCount: Int = 0
    ) {
        self.id = id
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.kindRaw = kind.rawValue
        self.statusRaw = status.rawValue
        self.requestedStartIndex = startIndex
        self.requestedEndIndex = endIndex
        self.completedCount = 0
        self.failedCount = 0
        self.totalCount = totalCount
        self.createdAt = Date()
        self.updatedAt = Date()
        self.lastErrorMessage = nil
    }
}

// MARK: - DownloadTaskItem (SwiftData)

/// 章节级下载记录，用于精确恢复。
@Model
final class DownloadTaskItem {
    @Attribute(.unique) var id: UUID
    var taskID: UUID
    var chapterID: UUID
    var chapterIndex: Int
    var statusRaw: String
    var retryCount: Int
    var errorMessage: String?
    var cachePath: String?
    var cachedAt: Date?

    var status: ChapterCacheStatus {
        get { ChapterCacheStatus(rawValue: statusRaw) ?? .none }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        taskID: UUID,
        chapterID: UUID,
        chapterIndex: Int = 0,
        status: ChapterCacheStatus = .none
    ) {
        self.id = id
        self.taskID = taskID
        self.chapterID = chapterID
        self.chapterIndex = chapterIndex
        self.statusRaw = status.rawValue
        self.retryCount = 0
        self.errorMessage = nil
        self.cachePath = nil
        self.cachedAt = nil
    }
}

// MARK: - DownloadTaskSnapshot (Sendable)

/// DownloadTask 的值语义快照，供 View 使用。
struct DownloadTaskSnapshot: Identifiable, Sendable {
    let id: UUID
    let bookID: UUID
    let bookTitle: String
    let kind: DownloadTaskKind
    let status: DownloadTaskStatus
    let completedCount: Int
    let failedCount: Int
    let totalCount: Int
    let createdAt: Date
    let updatedAt: Date
    let lastErrorMessage: String?

    var fractionCompleted: Double {
        totalCount > 0 ? Double(completedCount + failedCount) / Double(totalCount) : 0
    }

    var isTerminal: Bool {
        switch status {
        case .completed, .completedWithFailures, .failed, .cancelled:
            return true
        case .queued, .running, .paused, .cancelling:
            return false
        }
    }

    init(
        id: UUID,
        bookID: UUID,
        bookTitle: String,
        kind: DownloadTaskKind,
        status: DownloadTaskStatus,
        completedCount: Int,
        failedCount: Int,
        totalCount: Int,
        createdAt: Date,
        updatedAt: Date,
        lastErrorMessage: String?
    ) {
        self.id = id
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.kind = kind
        self.status = status
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.totalCount = totalCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastErrorMessage = lastErrorMessage
    }

    init(_ task: DownloadTask) {
        self.id = task.id
        self.bookID = task.bookID
        self.bookTitle = task.bookTitle
        self.kind = task.kind
        self.status = task.status
        self.completedCount = task.completedCount
        self.failedCount = task.failedCount
        self.totalCount = task.totalCount
        self.createdAt = task.createdAt
        self.updatedAt = task.updatedAt
        self.lastErrorMessage = task.lastErrorMessage
    }
}