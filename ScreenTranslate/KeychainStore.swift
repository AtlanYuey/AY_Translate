import Foundation
import Security

struct KeychainStore: APIKeyStoring {
    private let service: String

    init(service: String? = nil) {
        self.service = service ?? SharedAppContainer.hostIdentifier + ".ai-keys"
    }

    func read(_ profile: APIKeySlot) throws -> String {
        var query = query(profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        return key
    }

    /// Empty input explicitly removes the credential; keys never enter UserDefaults.
    func save(_ key: String, for profile: APIKeySlot) throws {
        let query = query(profile)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func query(_ profile: APIKeySlot) -> [String: Any] {
        // Both targets declare the containing app's group as their default.
        // Let iOS resolve the actual signing-team prefix after re-signing an IPA.
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: profile.account, kSecAttrSynchronizable as String: false]
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { AppLocalization.formatted("Could not access the device Keychain (%d). Unlock the device and try again.", status) }
}
