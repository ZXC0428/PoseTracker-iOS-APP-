import Foundation
import Security

/// 使用 iOS Keychain 保存 API token，避免敏感資料落入 UserDefaults/SQLite。
enum TokenStore {
    private static let service = "com.posetracker.api"
    private static let account = "access-token"

    /// 以覆蓋方式保存 token，確保 Keychain 中只有目前登入者的一份資料。
    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 先刪除舊項目，因為 SecItemAdd 不會自動覆蓋相同 service/account。
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw APIError.invalidResponse }
    }

    /// 讀取 token；不存在、無法解碼或 Keychain 失敗時回傳 nil。
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 登出時移除 token；刪除不存在的項目也可安全忽略。
    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
