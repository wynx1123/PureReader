import Foundation

struct TextChunk: Identifiable, Sendable {
    let id: String
    let text: String
    let chapterIndex: Int
    let chapterID: UUID
    /// 段落索引范围（章节内按 \n\n 分割后的下标）
    let paragraphStart: Int
    let paragraphEnd: Int
}

/// 按段落边界切分，不在句子中间截断
struct SemanticChunker {
    let chunkSize: Int
    let overlap: Int

    init(
        chunkSize: Int = AIRewriteConstants.chunkSize,
        overlap: Int = AIRewriteConstants.chunkOverlap
    ) {
        self.chunkSize = chunkSize
        self.overlap = overlap
    }

    func split(_ text: String, chapterID: UUID, chapterIndex: Int) -> [TextChunk] {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var chunks: [TextChunk] = []
        var batch: [String] = []
        var batchStart = 0
        var currentLength = 0

        for (pIdx, paragraph) in paragraphs.enumerated() {
            guard !paragraph.isEmpty else { continue }

            if currentLength + paragraph.count > chunkSize && !batch.isEmpty {
                let chunkText = batch.joined(separator: "\n\n")
                chunks.append(TextChunk(
                    id: "ch_\(chapterIndex)_p\(batchStart)",
                    text: chunkText,
                    chapterIndex: chapterIndex,
                    chapterID: chapterID,
                    paragraphStart: batchStart,
                    paragraphEnd: pIdx
                ))

                // 重叠：尽量保留末尾 overlap 字符
                if let last = batch.last {
                    let keep = String(last.suffix(overlap))
                    batch = keep.isEmpty ? [] : [keep]
                    currentLength = keep.count
                    batchStart = max(0, pIdx - 1)
                } else {
                    batch = []
                    currentLength = 0
                    batchStart = pIdx
                }
            }

            if batch.isEmpty {
                batchStart = pIdx
            }
            batch.append(paragraph)
            currentLength += paragraph.count
        }

        if !batch.isEmpty {
            chunks.append(TextChunk(
                id: "ch_\(chapterIndex)_p\(batchStart)_end",
                text: batch.joined(separator: "\n\n"),
                chapterIndex: chapterIndex,
                chapterID: chapterID,
                paragraphStart: batchStart,
                paragraphEnd: paragraphs.count
            ))
        }

        return chunks
    }
}

enum VectorMath {
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = sqrt(na) * sqrt(nb)
        guard denom > 1e-8 else { return 0 }
        return dot / denom
    }
}
