import Foundation

/// Per-setting last-writer records. Device-only privacy choices never leave
/// their device; provider definitions contain endpoints/models, never API keys.
nonisolated struct CloudSettingsRecord: Codable, Equatable {
    static let allowedKeys: Set<String> = ["defaultSourceLanguage", "defaultTargetLanguage", "translationAppearance",
        "ocrEngine", "translationEngine", "aiAssistEnabled", "aiAssistAsks", "overlayTextScale", "showsTextDetailsOnTap", "showsUnchangedText", "defaultResultMode", "interfaceLanguage", "ai.services.v1"]
    /// API keys and cloud permissions, synced only after a separate opt-in.
    /// Never part of `allowedKeys`: the value is not kept in preferences.
    static let credentialsKey = "ai.credentials.v1"
    let version: Int
    let timestamp: Double
    let device: String
    let value: Data

    init(value: Any, timestamp: Double, device: String) throws {
        self.version = 1; self.timestamp = timestamp; self.device = device
        self.value = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }

    func decodedValue(for key: String) -> Any? {
        guard Self.allowedKeys.contains(key) || key == Self.credentialsKey, version == 1, timestamp.isFinite, timestamp > 0,
              value.count < 250_000, let dictionary = try? PropertyListSerialization.propertyList(from: value, format: nil) as? [String: Any],
              let value = dictionary["value"] else { return nil }
        if key == "defaultTargetLanguage" {
            guard let language = value as? String,
                  ["en", "ar", "zh-Hans", "ja", "ko", "es", "fr", "de", "it", "pt", "ru"].contains(language) else { return nil }
        }
        if key == Self.credentialsKey {
            guard let data = value as? Data, (try? JSONDecoder().decode(SyncedCredentials.self, from: data)) != nil else { return nil }
        }
        if key == "ai.services.v1" {
            guard let data = value as? Data, let catalog = try? JSONDecoder().decode(AIServiceCatalog.self, from: data),
                  catalog.services.count <= 100, Set(catalog.services.map(\.id)).count == catalog.services.count,
                  catalog.services.allSatisfy({ (try? $0.validate()) != nil }) else { return nil }
        }
        return value
    }

    func isNewer(than other: CloudSettingsRecord?) -> Bool {
        guard let other else { return true }
        return timestamp > other.timestamp || (timestamp == other.timestamp && device > other.device)
    }
}

/// What the optional "include API keys" sync carries between the user's own
/// devices: each saved service's key and the cloud permissions already given.
nonisolated struct SyncedCredentials: Codable, Equatable, Sendable {
    /// Service ID → API key.
    var keys: [String: String] = [:]
    /// "<profile>.<service ID>" → the consent identity that was approved.
    var consents: [String: String] = [:]
}
