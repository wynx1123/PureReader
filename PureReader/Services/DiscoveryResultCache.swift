import Foundation

/// 发现页结果磁盘缓存（stale-while-revalidate）。
/// 每个分类一份 JSON 文件，冷启动秒开；过期数据先展示、后台静默刷新。
enum DiscoveryResultCache {
    private struct Payload: Codable {
        var savedAt: Date
        var results: [SourceSearchResult]
    }

    /// 缓存有效期：30 分钟内视为新鲜，不触发后台刷新
    static let freshInterval: TimeInterval = 30 * 60

    private static var cacheDir: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("DiscoveryCache", isDirectory: true)
    }

    private static func fileURL(for categoryID: String) -> URL? {
        guard let base = cacheDir else { return nil }
        // categoryID 含 UUID/中文，统一哈希成安全文件名
        var hash: UInt64 = 5381
        for byte in categoryID.utf8 {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        return base.appendingPathComponent("\(hash).json")
    }

    /// 读取缓存（不存在或损坏返回 nil）
    static func load(categoryID: String) -> (results: [SourceSearchResult], savedAt: Date)? {
        guard let url = fileURL(for: categoryID),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.results.isEmpty else { return nil }
        return (payload.results, payload.savedAt)
    }

    /// 写入缓存（后台线程执行，失败静默）
    static func save(categoryID: String, results: [SourceSearchResult]) {
        guard !results.isEmpty, let url = fileURL(for: categoryID) else { return }
        let payload = Payload(savedAt: Date(), results: results)
        Task.detached(priority: .utility) {
            do {
                let dir = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(payload)
                try data.write(to: url, options: .atomic)
            } catch {
                // 磁盘缓存失败不影响主流程
            }
        }
    }

    /// 清空全部缓存（书源规则变更时可调用）
    static func invalidateAll() {
        guard let dir = cacheDir else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
