import Foundation

/// Non-secret preferences can travel through the same shared Keychain group as
/// credentials when a re-signer removes App Groups but preserves keychain groups.
/// If both entitlements are removed, iOS isolation still applies; use explicit transfer.
@MainActor
enum PreferencesBridge {
    static func read(from store: any APIKeyStoring) throws -> [String: Any] {
        let encoded = try store.read(.sharedPreferences)
        guard !encoded.isEmpty else { return [:] }
        guard let data = Data(base64Encoded: encoded), data.count <= 1_000_000,
              let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              values.keys.allSatisfy(SharedAppContainer.isPreferenceKey) else { throw ConfigurationTransferError.invalid }
        return values
    }

    static func write(_ values: [String: Any], to store: any APIKeyStoring) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        guard data.count <= 1_000_000 else { throw ConfigurationTransferError.invalid }
        try store.save(data.base64EncodedString(), for: .sharedPreferences)
    }

    static func synchronize(_ defaults: UserDefaults, store: any APIKeyStoring) throws {
        var shared = try read(from: store)
        if !defaults.bool(forKey: "preferences.bridge.bootstrapped") {
            let localCatalog = defaults.data(forKey: "ai.services.v1").flatMap { try? JSONDecoder().decode(AIServiceCatalog.self, from: $0) }
            let remoteCatalog = (shared["ai.services.v1"] as? Data).flatMap { try? JSONDecoder().decode(AIServiceCatalog.self, from: $0) }
            let upgradingConfiguredApp = localCatalog?.services.isEmpty == false && remoteCatalog?.services.isEmpty != false
            for (key, value) in defaults.dictionaryRepresentation() where SharedAppContainer.isPreferenceKey(key) {
                // Upgrade an already configured main app even if the extension
                // launched first and seeded an empty catalog in its own sandbox.
                if shared[key] == nil || upgradingConfiguredApp {
                    shared[key] = value
                }
            }
            try write(shared, to: store)
            defaults.set(true, forKey: "preferences.bridge.bootstrapped")
        }
        // Remove revoked/deleted preferences as well as copying new values.
        for key in defaults.dictionaryRepresentation().keys where SharedAppContainer.isPreferenceKey(key) && shared[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in shared { defaults.set(value, forKey: key) }
    }

    static func update(_ value: Any?, key: String, store: any APIKeyStoring) throws {
        var shared = try read(from: store)
        shared[key] = value
        try write(shared, to: store)
    }
}

enum ConfigurationTransferError: LocalizedError {
    case invalid, expired
    var errorDescription: String? {
        switch self {
        case .invalid: "This is not a valid screen translation configuration."
        case .expired: "This configuration has expired. Copy it again from the main app."
        }
    }
}

struct ConfigurationTransfer: Codable {
    let version: Int
    let expiresAt: Date
    let preferences: Data
    let keys: [String: String]
}
