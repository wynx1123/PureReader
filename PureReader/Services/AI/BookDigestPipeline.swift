import Foundation

/// 整书消化：分批摘要 → 记忆锚点（全后台）
actor BookDigestPipeline {
    static let batchSize = 30

    static let memoryAnchorPrompt = """
    你是「纯享阅读」的记忆锚点提取引擎。
    输入：一本小说经过分批摘要后的全集概要。
    输出：结构化 JSON 记忆锚点（无 Markdown 包裹）。

    提取：
    1. coreConflict / mainTheme：1-2 句话
    2. characterNetwork：最多 15 人，字段 name, role, arc, relationships[], keyChapters[]
    3. worldBuilding：最多 8 条，字段 name, currentState, rules[], introducedIn[]
    4. plotThreads：最多 10 条，字段 thread, plantedAt, status, clues[], revealedAt(可选)
    5. narrativeMilestones：每约 20 章 1 个，字段 chapter, event, significance

    严格输出 JSON：
    {"coreConflict":"...","mainTheme":"...","characterNetwork":[],"worldBuilding":[],"plotThreads":[],"narrativeMilestones":[]}
    """

    struct ChapterSnapshot: Sendable {
        let id: UUID
        let index: Int
        let title: String
        let content: String
    }

    /// 进度 0...1
    func digest(
        bookID: UUID,
        bookTitle: String,
        chapters: [ChapterSnapshot],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> BookMemoryAnchors {
        let sorted = chapters.sorted { $0.index < $1.index }
        guard !sorted.isEmpty else {
            return BookMemoryAnchors.empty
        }

        let batches = stride(from: 0, to: sorted.count, by: Self.batchSize).map { start in
            Array(sorted[start..<min(start + Self.batchSize, sorted.count)])
        }

        var batchSummaries: [String] = []
        batchSummaries.reserveCapacity(batches.count)

        for (batchIdx, batch) in batches.enumerated() {
            try Task.checkCancellation()
            if let cached = BookMemoryAnchorStore.loadBatch(bookID: bookID, batchIdx: batchIdx) {
                batchSummaries.append(cached)
            } else {
                let batchText = buildBatchText(batch, batchIdx: batchIdx)
                let summary = try await summarizeBatch(
                    batchText: batchText,
                    batchIdx: batchIdx,
                    totalBatches: batches.count,
                    bookTitle: bookTitle
                )
                batchSummaries.append(summary)
                try? BookMemoryAnchorStore.saveBatch(bookID: bookID, batchIdx: batchIdx, summary: summary)
            }
            progress?(0.7 * Double(batchIdx + 1) / Double(batches.count))
        }

        let allSummaries = batchSummaries.joined(separator: "\n\n---\n\n")
        let anchors = try await extractAnchors(
            allSummaries: allSummaries,
            bookID: bookID,
            bookTitle: bookTitle,
            totalChapters: sorted.count
        )
        try BookMemoryAnchorStore.saveAnchors(anchors, bookID: bookID)
        progress?(1.0)
        return anchors
    }

    private func buildBatchText(_ batch: [ChapterSnapshot], batchIdx: Int) -> String {
        var text = "批次 \(batchIdx + 1)\n"
        for chapter in batch {
            let head = String(chapter.content.prefix(200))
            let tail = String(chapter.content.suffix(200))
            let names = ContextAssembler.extractCharacterNames(from: chapter.content).prefix(8)
            text += """
            --- 第 \(chapter.index + 1) 章：\(chapter.title) ---
            开头：\(head)
            结尾：\(tail)
            出现人物：\(names.joined(separator: "、"))

            """
        }
        return text
    }

    private func summarizeBatch(
        batchText: String,
        batchIdx: Int,
        totalBatches: Int,
        bookTitle: String
    ) async throws -> String {
        let system = """
        你是小说摘要助手。用简洁中文总结本批章节的关键情节、人物变化、新设定，不超过 600 字。
        不要写客套话。
        """
        let user = """
        书名：《\(bookTitle)》
        批次 \(batchIdx + 1)/\(totalBatches)

        \(batchText)
        """
        return try await LLMClient.chat(
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            temperature: 0.3,
            timeout: 90
        )
    }

    private func extractAnchors(
        allSummaries: String,
        bookID: UUID,
        bookTitle: String,
        totalChapters: Int
    ) async throws -> BookMemoryAnchors {
        let user = """
        书名：《\(bookTitle)》 共 \(totalChapters) 章

        全集分批摘要：
        \(allSummaries)
        """
        let raw = try await LLMClient.chat(
            messages: [
                .init(role: "system", content: Self.memoryAnchorPrompt),
                .init(role: "user", content: user)
            ],
            temperature: 0.2,
            timeout: 120
        )
        return parseAnchorsJSON(raw, bookID: bookID, totalChapters: totalChapters)
    }

    private func parseAnchorsJSON(_ raw: String, bookID: UUID, totalChapters: Int) -> BookMemoryAnchors {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥离 ```json
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
            text = text.replacingOccurrences(of: "```", with: "")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 截取第一个 { 到最后一个 }
        if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}") {
            text = String(text[s...e])
        }

        struct Payload: Codable {
            var coreConflict: String?
            var mainTheme: String?
            var characterNetwork: [CharacterAnchor]?
            var worldBuilding: [WorldAnchor]?
            var plotThreads: [PlotThreadAnchor]?
            var narrativeMilestones: [MilestoneAnchor]?
        }

        guard let data = text.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return BookMemoryAnchors(
                bookID: bookID.uuidString,
                generatedAt: Date(),
                totalChapters: totalChapters,
                coreConflict: String(text.prefix(200)),
                mainTheme: "",
                characterNetwork: [],
                worldBuilding: [],
                plotThreads: [],
                narrativeMilestones: []
            )
        }

        return BookMemoryAnchors(
            bookID: bookID.uuidString,
            generatedAt: Date(),
            totalChapters: totalChapters,
            coreConflict: p.coreConflict ?? "",
            mainTheme: p.mainTheme ?? "",
            characterNetwork: p.characterNetwork ?? [],
            worldBuilding: p.worldBuilding ?? [],
            plotThreads: p.plotThreads ?? [],
            narrativeMilestones: p.narrativeMilestones ?? []
        )
    }
}

// MARK: - Rerank (LLM pairwise / batch score)

enum Reranker {
    /// 用 chat 对候选打分，返回 topK
    static func rerank(
        query: String,
        candidates: [BookVectorIndex.VectorEntry],
        topK: Int = AIRewriteConstants.rerankTopK
    ) async throws -> [BookVectorIndex.VectorEntry] {
        guard candidates.count >= 5 else { return Array(candidates.prefix(topK)) }

        let listed = candidates.enumerated().map { i, c in
            "[\(i)] 第\(c.chapterIndex + 1)章: \(String(c.text.prefix(200)))"
        }.joined(separator: "\n")

        let system = """
        你是检索精排器。根据查询与候选段落的相关性，输出最相关的编号列表。
        只输出 JSON 数组，如 [2,0,5]，最多 \(topK) 个，从高相关到低。
        """
        let user = """
        查询：
        \(String(query.prefix(500)))

        候选：
        \(listed)
        """
        let raw = try await LLMClient.chat(
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user)
            ],
            temperature: 0.0,
            timeout: 30
        )
        let indices = parseIndexArray(raw)
        var result: [BookVectorIndex.VectorEntry] = []
        for i in indices {
            if candidates.indices.contains(i) {
                result.append(candidates[i])
            }
            if result.count >= topK { break }
        }
        return result.isEmpty ? Array(candidates.prefix(topK)) : result
    }

    private static func parseIndexArray(_ raw: String) -> [Int] {
        var text = raw
        if let s = text.firstIndex(of: "["), let e = text.lastIndex(of: "]") {
            text = String(text[s...e])
        }
        guard let data = text.data(using: .utf8),
              let arr = try? JSONDecoder().decode([Int].self, from: data)
        else {
            // fallback: 找数字
            let nums = text.split { !$0.isNumber }.compactMap { Int($0) }
            return nums
        }
        return arr
    }
}

// MARK: - Enhanced searcher

enum EnhancedBookSearcher {
    /// Embedding 粗筛 + Rerank 精排
    static func search(
        query: String,
        index: BookVectorIndex,
        topK: Int = AIRewriteConstants.rerankTopK
    ) async throws -> [BookVectorIndex.VectorEntry] {
        let coarse = try await index.search(query: query, topK: 50, minSimilarity: 0.5)
        return try await Reranker.rerank(query: query, candidates: coarse, topK: topK)
    }
}
