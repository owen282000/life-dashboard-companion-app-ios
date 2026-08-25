import Foundation
import Security

/// Minimal Keychain wrapper for the app's secrets (webhook headers, HMAC signing secret).
/// Items use kSecAttrAccessibleAfterFirstUnlock so background syncs can read them.
enum KeychainStore {
    private static let service = "com.owen282000.lifedashboard"

    static func data(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func setData(_ value: Data, forKey key: String) {
        removeValue(forKey: key)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: value
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func string(forKey key: String) -> String? {
        guard let data = data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setString(_ value: String, forKey key: String) {
        setData(Data(value.utf8), forKey: key)
    }

    static func removeValue(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
