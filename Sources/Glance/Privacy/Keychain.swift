import Foundation
import Security

/// Provider API keys, stored in the login Keychain. Never logged or shown.
/// Read once per launch and kept in memory, so macOS asks for Keychain access at most once.
@MainActor
enum Keychain {
    private static var cache: [String: String] = [:]

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Config.bundleID,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        if let cached = cache[account] { return cached }
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)
        cache[account] = value
        return value
    }

    static func has(_ account: String) -> Bool { !(get(account) ?? "").isEmpty }

    /// Saves the value, or deletes it when empty.
    static func set(_ account: String, _ value: String) {
        SecItemDelete(query(account) as CFDictionary)
        cache[account] = nil
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(trimmed.utf8)
        if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { cache[account] = trimmed }
    }
}
