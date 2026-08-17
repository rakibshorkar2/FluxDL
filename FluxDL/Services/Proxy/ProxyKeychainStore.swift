import Foundation
import Security

// MARK: - ProxyKeychainStoring

public protocol ProxyKeychainStoring: AnyObject {
    func password(forProfileID id: UUID) -> String?
    func savePassword(_ password: String, forProfileID id: UUID)
    func deletePassword(forProfileID id: UUID)
}

// MARK: - ProxyKeychainStore
//
// Stores proxy credentials in the iOS Keychain. Passwords must never be
// persisted in UserDefaults — this is the only credential persistence layer.

public final class ProxyKeychainStore: ProxyKeychainStoring {
    private let service = "com.rakib.FluxDL.proxy"

    public init() {}

    public func password(forProfileID id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func savePassword(_ password: String, forProfileID id: UUID) {
        let account = id.uuidString
        let data = Data(password.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    public func deletePassword(forProfileID id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
