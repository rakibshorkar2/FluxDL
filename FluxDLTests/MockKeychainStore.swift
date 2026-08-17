import Foundation
@testable import FluxDL

/// In-memory `ProxyKeychainStoring` used by tests to avoid touching the
/// real iOS Keychain.
final class MockKeychainStore: ProxyKeychainStoring {
    private var storage: [UUID: String] = [:]

    func password(forProfileID id: UUID) -> String? {
        storage[id]
    }

    func savePassword(_ password: String, forProfileID id: UUID) {
        storage[id] = password
    }

    func deletePassword(forProfileID id: UUID) {
        storage[id] = nil
    }
}
