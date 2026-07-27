import Foundation

/// 全书向量索引：云端 Embedding + 磁盘缓存
actor BookVectorIndex {
    struct VectorEntry: Codable, Sendable {
        let chunkID: String
        let chapterIndex: Int
        let chapterID: String
        let paragraphStart: Int
        let paragraphEnd: Int
        let text: String
        let embedding: [Float]
        let cachedAt: Date
    }

    private struct DiskPayload: Codable {
        var bookID: String
        var model: String
        var dimensions: Int
        var entries: [VectorEntry]
        var builtAt: Date
    }

    private var entries: [VectorEntry] = []
    private var bookID: UUID?
    private(set) var isReady = false

    // MARK: - Build / Load

    func loadFromDisk(bookID: UUID) -> Bool {
        let url = Self.diskURL(for: bookID)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(DiskPayload.self, from: data),
              payload.model == AIConfig.embeddingModel
        else {
            return false
        }
        self.bookID = bookID
        self.entries = payload.entries
        self.isReady = !payload.entries.isEmpty
        return isReady
    }

    func saveToDisk(bookID: UUID) throws {
        let payload = DiskPayload(
            bookID: bookID.uuidString,
            model: AIConfig.embeddingModel,
            dimensions: AIConfig.embeddingDimensions,
            entries: entries,
            builtAt: Date()
        )
        let data = try JSONEncoder().encode(payload)
        let url = Self.diskURL(for: bookID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        self.bookID = bookID
    }

    /// 构建索引。progress 0...1
    func build(
        chapters: [(id: UUID, index: Int, content: String)],
        bookID: UUID,
        mode: IndexingMode,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        self.bookID = bookID
        entries = []

        let chunker = SemanticChunker()
        var allChunks: [TextChunk] = []

        for ch in chapters {
            var text = ch.content
            if mode == .slimAsync {
                // 精简：首 400 + 尾 400 + 对话密集段抽样
                text = slimChapterText(text)
            }
            let chunks = chunker.split(text, chapterID: ch.id, chapterIndex: ch.index)
            allChunks.append(contentsOf: chunks)
        }

        guard !allChunks.isEmpty else {
            isReady = false
            return
        }

        let batchSize = AIRewriteConstants.embeddingBatchSize
        var built: [VectorEntry] = []
        built.reserveCapacity(allChunks.count)

        let total = allChunks.count
        var offset = 0
        while offset < total {
            try Task.checkCancellation()
            let end = min(offset + batchSize, total)
            let batch = Array(allChunks[offset..<end])
            let texts = batch.map(\.text)
            let vectors = try await LLMClient.embed(texts: texts)

            for (chunk, emb) in zip(batch, vectors) {
                built.append(VectorEntry(
                    chunkID: chunk.id,
                    chapterIndex: chunk.chapterIndex,
                    chapterID: chunk.chapterID.uuidString,
                    paragraphStart: chunk.paragraphStart,
                    paragraphEnd: chunk.paragraphEnd,
                    text: chunk.text,
                    embedding: emb,
                    cachedAt: Date()
                ))
            }

            offset = end
            progress?(Double(offset) / Double(total))
        }

        entries = built
        isReady = !entries.isEmpty
        try saveToDisk(bookID: bookID)
    }

    // MARK: - Search

    func search(
        query: String,
        topK: Int = AIRewriteConstants.vectorTopK,
        minSimilarity: Float = AIRewriteConstants.vectorMinSimilarity,
        excludeChapterIndex: Int? = nil,
        excludeText: String? = nil
    ) async throws -> [VectorEntry] {
        guard isReady, !entries.isEmpty else { return [] }

        let vectors = try await LLMClient.embed(texts: [query])
        guard let queryVector = vectors.first else { return [] }

        var scored: [(VectorEntry, Float)] = []
        scored.reserveCapacity(entries.count)

        for entry in entries {
            if let ex = excludeChapterIndex, entry.chapterIndex == ex {
                if let needle = excludeText, entry.text.contains(String(needle.prefix(40))) {
                    continue
                }
            }
            let sim = VectorMath.cosineSimilarity(queryVector, entry.embedding)
            if sim >= minSimilarity {
                scored.append((entry, sim))
            }
        }

        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(topK).map(\.0))
    }

    /// 改写后增量更新：重嵌某章相关 chunk
    func invalidateChapter(
        chapterID: UUID,
        chapterIndex: Int,
        content: String
    ) async throws {
        entries.removeAll { $0.chapterID == chapterID.uuidString }
        let chunks = SemanticChunker().split(content, chapterID: chapterID, chapterIndex: chapterIndex)
        guard !chunks.isEmpty else {
            if let id = bookID { try? saveToDisk(bookID: id) }
            return
        }
        let vectors = try await LLMClient.embed(texts: chunks.map(\.text))
        for (chunk, emb) in zip(chunks, vectors) {
            entries.append(VectorEntry(
                chunkID: chunk.id,
                chapterIndex: chunk.chapterIndex,
                chapterID: chunk.chapterID.uuidString,
                paragraphStart: chunk.paragraphStart,
                paragraphEnd: chunk.paragraphEnd,
                text: chunk.text,
                embedding: emb,
                cachedAt: Date()
            ))
        }
        if let id = bookID { try saveToDisk(bookID: id) }
    }

    var entryCount: Int { entries.count }

    // MARK: - Disk path

    static func diskURL(for bookID: UUID) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("PureReader", isDirectory: true)
            .appendingPathComponent("VectorIndex", isDirectory: true)
            .appendingPathComponent("\(bookID.uuidString).json")
    }

    private func slimChapterText(_ text: String) -> String {
        let head = String(text.prefix(400))
        let tail = String(text.suffix(400))
        // 抽样含引号的对话段
        let paras = text.components(separatedBy: "\n\n").filter {
            $0.contains("“") || $0.contains("\"") || $0.contains("「")
        }
        let dialogue = paras.prefix(3).joined(separator: "\n\n")
        return [head, dialogue, tail].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

enum IndexingMode: Sendable {
    case skip
    case fullAsync
    case slimAsync

    static func determine(wordCount: Int) -> IndexingMode {
        switch wordCount {
        case Int.min...0: return .skip
        case 1..<500_000: return .fullAsync
        default: return .slimAsync
        }
    }
}
