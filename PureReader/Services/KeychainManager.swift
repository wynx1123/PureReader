import Foundation
import Security

/// Keychain 读写（API Key 等敏感信息）
///
/// 读取带进程内缓存：密钥会在 SwiftUI 的 body 求值路径上被反复读取
/// （`AIConfig.isConfigured` 等），而每次未命中都是一次 `SecItemCopyMatching` 系统调用。
/// 本进程是唯一写入方，因此缓存只需在 set/delete 时失效。
enum KeychainManager {
    private static let service = "com.wynx.PureReader"

    private static let lock = NSLock()
    /// value 为 nil 表示"确认不存在"，与"尚未查询"区分开。
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    private static func cached(_ key: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    private static func store(_ value: String?, for key: String) {
        lock.lock()
        cache[key] = value
        lock.unlock()
    }

    private static func invalidate(_ key: String) {
        lock.lock()
        cache.removeValue(forKey: key)
        lock.unlock()
    }

    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        invalidate(key)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        if ok { store(value, for: key) }
        return ok
    }

    static func get(_ key: String) -> String? {
        if let hit = cached(key) { return hit }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            // 只缓存"确认不存在"。其他失败（如设备锁定导致的 interactionNotAllowed）
            // 是暂时的，缓存下来会让后续读取一直拿到空值。
            if status == errSecItemNotFound { store(nil, for: key) }
            return nil
        }
        store(str, for: key)
        return str
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        store(nil, for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
