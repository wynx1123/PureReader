import Foundation
import SwiftData

// MARK: - SearchCoordinator

/// 多源搜索协调器。
///
/// 负责：
/// - 并发搜索控制（最多 5 源并发，单源 15 秒超时）
/// - 结果收集、去重、合并
/// - 失败汇总
/// - 高分源优先
@MainActor
enum SearchCoordinator {

    // MARK: - Config

    /// 单次搜索最大并发数。
    static let maxConcurrentSources = 5

    /// 单源搜索超时（秒）。
    static let singleSourceTimeoutSeconds: Double = 15

    // MARK: - Search

    /// 多源并发搜索。
    /// - Parameters:
    ///   - keyword: 搜索关键词
    ///   - sources: 可用书源（已过滤启用+有效）
    ///   - page: 页码
    /// - Returns: 合并后的搜索结果和失败报告
    static func search(
        keyword: String,
        sources: [BookSource],
        page: Int = 1
    ) async -> SearchSessionReport {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = sources.filter { $0.enabled && $0.isValid && !$0.searchURL.isEmpty }

        guard !key.isEmpty, !enabled.isEmpty else {
            return SearchSessionReport(
                query: key,
                results: [],
                attemptedSourceCount: enabled.count,
                succeededSourceCount: 0,
                failedSourceCount: 0,
                failures: []
            )
        }

        let snapshots = enabled.map { BookSourceSnapshot($0) }

        // 按评分排序，高分源优先
        let sorted = snapshots.sorted { sourceScore($0) > sourceScore($1) }

        return await searchWithSnapshots(keyword: key, snapshots: sorted, page: page)
    }

    /// 使用已创建的快照搜索（避免重复创建）。
    static func searchWithSnapshots(
        keyword: String,
        snapshots: [BookSourceSnapshot],
        page: Int = 1
    ) async -> SearchSessionReport {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !snapshots.isEmpty else {
            return SearchSessionReport(
                query: key,
                results: [],
                attemptedSourceCount: snapshots.count,
                succeededSourceCount: 0,
                failedSourceCount: 0,
                failures: []
            )
        }

        // 使用 TaskGroup 并发搜索，限制并发数
        var allResults: [SourceSearchResult] = []
        var failures: [BookSourceSearchFailure] = []
        var succeeded = 0
        var failed = 0

        await withTaskGroup(of: (Int, [SourceSearchResult], BookSourceSearchFailure?).self) { group in
            var running = 0
            var nextIndex = 0

            func fillGroup() {
                while running < maxConcurrentSources, nextIndex < snapshots.count {
                    let idx = nextIndex
                    let source = snapshots[idx]
                    nextIndex += 1
                    running += 1
                    group.addTask {
                        do {
                            // 单源超时
                            let results = try await withTimeout(seconds: singleSourceTimeoutSeconds) {
                                try await BookSourceEngine.search(
                                    keyword: key,
                                    snapshots: [source],
                                    page: page
                                )
                            }
                            return (idx, results.results, nil)
                        } catch is CancellationError {
                            return (idx, [], nil)
                        } catch {
                            let failure = BookSourceSearchFailure(
                                sourceID: source.id,
                                sourceName: source.name,
                                reason: error.localizedDescription,
                                verificationURL: Self.verificationURL(from: error)
                            )
                            return (idx, [], failure)
                        }
                    }
                }
            }

            fillGroup()
            for await (_, results, failure) in group {
                running -= 1
                if let failure {
                    failed += 1
                    failures.append(failure)
                } else {
                    succeeded += 1
                    allResults.append(contentsOf: results)
                }
                fillGroup()
            }
        }

        // 去重合并
        let merged = mergeResults(allResults)

        return SearchSessionReport(
            query: key,
            results: merged,
            attemptedSourceCount: snapshots.count,
            succeededSourceCount: succeeded,
            failedSourceCount: failed,
            failures: failures.sorted { $0.sourceName < $1.sourceName }
        )
    }

    // MARK: - Result merging

    /// 合并去重来自多源的搜索结果。
    /// 同名同作者的书合并为一个条目，保留多个来源。
    private static func mergeResults(_ results: [SourceSearchResult]) -> [MergedSearchResult] {
        var groups: [String: MergedSearchResult] = [:]

        for result in results {
            let key = normalizedMergeKey(name: result.name, author: result.author)

            if var existing = groups[key] {
                // 合并：补充 intro 和 cover（取第一个非空的）
                if existing.intro.isEmpty && !result.intro.isEmpty {
                    existing.intro = result.intro
                }
                if existing.coverURL == nil, let cover = result.coverURL {
                    existing.coverURL = cover
                }
                existing.candidates.append(SourceCandidate(
                    sourceID: result.sourceID,
                    sourceName: result.sourceName,
                    bookURL: result.bookURL
                ))
                groups[key] = existing
            } else {
                groups[key] = MergedSearchResult(
                    id: key,
                    title: result.name,
                    author: result.author,
                    intro: result.intro,
                    coverURL: result.coverURL,
                    candidates: [
                        SourceCandidate(
                            sourceID: result.sourceID,
                            sourceName: result.sourceName,
                            bookURL: result.bookURL
                        )
                    ]
                )
            }
        }

        return groups.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 标准化合并 key：书名+作者，去除标点和空格。
    private static func normalizedMergeKey(name: String, author: String) -> String {
        let normalizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[：:、，,\s\-_]"#, with: "", options: .regularExpression)
        let normalizedAuthor = author
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[：:、，,\s\-_]"#, with: "", options: .regularExpression)
        return normalizedName + "|" + normalizedAuthor
    }

    // MARK: - Source scoring

    /// 书源评分（用于排序，高分源优先搜索）。
    private static func sourceScore(_ source: BookSourceSnapshot) -> Int {
        var score = source.weight
        // 原生适配器加分
        if NativeBookSourceAdapter.detect(name: source.name, bookSourceURL: source.bookURL) != nil {
            score += 50
        }
        // 有探索 URL 的加分
        if !source.exploreURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 10
        }
        return score
    }

    // MARK: - Helpers

    /// 带超时的异步操作。
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SearchTimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw SearchTimeoutError()
            }
            return result
        }
    }

    private struct SearchTimeoutError: LocalizedError {
        var errorDescription: String? {
            String(localized: "搜索超时")
        }
    }

    private static func verificationURL(from error: Error) -> URL? {
        if case BookSourceError.verificationRequired(let url) = error {
            return url
        }
        return nil
    }
}

// MARK: - Search Session Report

/// 多源搜索会话报告。
struct SearchSessionReport: Sendable {
    let query: String
    let results: [MergedSearchResult]
    let attemptedSourceCount: Int
    let succeededSourceCount: Int
    let failedSourceCount: Int
    let failures: [BookSourceSearchFailure]

    var hasFailures: Bool { !failures.isEmpty }
    var hasVerificationRequired: Bool {
        failures.contains { $0.verificationURL != nil }
    }
}

// MARK: - Merged Search Result

/// 合并去重后的搜索结果条目。
struct MergedSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var author: String
    var intro: String
    var coverURL: String?
    var candidates: [SourceCandidate]

    /// 首选来源（第一个候选）。
    var primaryCandidate: SourceCandidate? {
        candidates.first
    }
}

// MARK: - Source Candidate

/// 合并结果中的单个来源候选。
struct SourceCandidate: Identifiable, Hashable, Sendable {
    let id = UUID()
    let sourceID: UUID
    let sourceName: String
    let bookURL: String
}