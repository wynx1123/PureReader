import Foundation

// MARK: - Anchor models

struct BookMemoryAnchors: Codable, Sendable {
    var bookID: String
    var generatedAt: Date
    var totalChapters: Int
    var coreConflict: String
    var mainTheme: String
    var characterNetwork: [CharacterAnchor]
    var worldBuilding: [WorldAnchor]
    var plotThreads: [PlotThreadAnchor]
    var narrativeMilestones: [MilestoneAnchor]

    static let empty = BookMemoryAnchors(
        bookID: "",
        generatedAt: .distantPast,
        totalChapters: 0,
        coreConflict: "",
        mainTheme: "",
        characterNetwork: [],
        worldBuilding: [],
        plotThreads: [],
        narrativeMilestones: []
    )

    var isEmpty: Bool {
        coreConflict.isEmpty && characterNetwork.isEmpty && worldBuilding.isEmpty
    }

    /// 注入 LLM 的紧凑文本
    func promptBlock(currentChapter: Int, queryNames: [String]) -> String {
        guard !isEmpty else { return "" }

        var lines: [String] = []
        lines.append("""
        ═══════════════════════════════════
        【本书知识纲要 — AI 已理解的整书背景】
        ═══════════════════════════════════
        核心冲突：\(coreConflict)
        核心主题：\(mainTheme)
        """)

        let nameSet = Set(queryNames)
        let chars = characterNetwork.filter { nameSet.isEmpty || nameSet.contains($0.name) }.prefix(8)
        if !chars.isEmpty {
            lines.append("── 涉及人物 ──")
            for c in chars {
                lines.append("• \(c.name)（\(c.role)）：\(c.arc)")
                if !c.relationships.isEmpty {
                    lines.append("  关系网：\(c.relationships.joined(separator: "；"))")
                }
            }
        }

        if !worldBuilding.isEmpty {
            lines.append("── 相关世界观约束 ──")
            for w in worldBuilding.prefix(6) {
                lines.append("• \(w.name)（当前状态：\(w.currentState)）")
                if !w.rules.isEmpty {
                    lines.append("  规则：\(w.rules.joined(separator: "；"))")
                }
            }
        }

        let openThreads = plotThreads.filter { $0.status != "已揭示" }.prefix(5)
        if !openThreads.isEmpty {
            lines.append("── 未回收伏笔 ──")
            for t in openThreads {
                lines.append("⚠ \(t.thread)（埋于第\(t.plantedAt)章，状态：\(t.status)）")
            }
        }

        if !narrativeMilestones.isEmpty {
            let near = narrativeMilestones.min(by: {
                abs($0.chapter - currentChapter) < abs($1.chapter - currentChapter)
            })
            if let m = near {
                lines.append("── 叙事节奏 ──")
                lines.append("当前位于第\(currentChapter + 1)章附近关键节点：第\(m.chapter)章 \(m.event)（\(m.significance)）")
            }
        }

        lines.append("═══════════════════════════════════")
        return lines.joined(separator: "\n")
    }
}

struct CharacterAnchor: Codable, Sendable {
    var name: String
    var role: String
    var arc: String
    var relationships: [String]
    var keyChapters: [Int]
}

struct WorldAnchor: Codable, Sendable {
    var name: String
    var currentState: String
    var rules: [String]
    var introducedIn: [Int]
}

struct PlotThreadAnchor: Codable, Sendable {
    var thread: String
    var plantedAt: Int
    var status: String
    var clues: [String]
    var revealedAt: Int?
}

struct MilestoneAnchor: Codable, Sendable {
    var chapter: Int
    var event: String
    var significance: String
}

// MARK: - Store

enum BookMemoryAnchorStore {
    static func directory(for bookID: UUID) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("PureReader", isDirectory: true)
            .appendingPathComponent("BookMemory", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
    }

    static func anchorsURL(for bookID: UUID) -> URL {
        directory(for: bookID).appendingPathComponent("anchors.json")
    }

    static func batchURL(for bookID: UUID, batchIdx: Int) -> URL {
        directory(for: bookID).appendingPathComponent(String(format: "batch_%02d.json", batchIdx))
    }

    static func loadAnchors(bookID: UUID) -> BookMemoryAnchors? {
        let url = anchorsURL(for: bookID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BookMemoryAnchors.self, from: data)
    }

    static func saveAnchors(_ anchors: BookMemoryAnchors, bookID: UUID) throws {
        let dir = directory(for: bookID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(anchors)
        try data.write(to: anchorsURL(for: bookID), options: .atomic)
    }

    static func loadBatch(bookID: UUID, batchIdx: Int) -> String? {
        let url = batchURL(for: bookID, batchIdx: batchIdx)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONDecoder().decode(BatchCache.self, from: data),
              !obj.dirty
        else { return nil }
        return obj.summary
    }

    static func saveBatch(bookID: UUID, batchIdx: Int, summary: String, dirty: Bool = false) throws {
        let dir = directory(for: bookID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = BatchCache(batchIdx: batchIdx, summary: summary, dirty: dirty, updatedAt: Date())
        let data = try JSONEncoder().encode(cache)
        try data.write(to: batchURL(for: bookID, batchIdx: batchIdx), options: .atomic)
    }

    static func markBatchDirty(bookID: UUID, chapterIndex: Int, batchSize: Int = 30) {
        let batchIdx = chapterIndex / batchSize
        let url = batchURL(for: bookID, batchIdx: batchIdx)
        guard let data = try? Data(contentsOf: url),
              var cache = try? JSONDecoder().decode(BatchCache.self, from: data)
        else { return }
        cache.dirty = true
        if let encoded = try? JSONEncoder().encode(cache) {
            try? encoded.write(to: url, options: .atomic)
        }
    }
}

struct BatchCache: Codable, Sendable {
    var batchIdx: Int
    var summary: String
    var dirty: Bool
    var updatedAt: Date
}
