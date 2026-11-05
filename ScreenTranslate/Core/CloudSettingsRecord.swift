import Foundation

/// Per-setting last-writer records. Device-only privacy choices never leave
/// their device; provider definitions contain endpoints/models, never API keys.
nonisolated struct CloudSettingsRecord: Codable, Equatable {
    static let allowedKeys: Set<String> = ["defaultSourceLanguage", "defaultTargetLanguage", "translationAppearance",
        "ocrEngine", "translationEngine", "translationPreference", "overlayTextScale", "showsTextDetailsOnTap", "defaultResultMode", "interfaceLanguage", "ai.services.v1"]
    let version: Int
    let timestamp: Double
    let device: String
    let value: Data

    init(value: Any, timestamp: Double, device: String) throws {
        self.version = 1; self.timestamp = timestamp; self.device = device
        self.value = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }

    func decodedValue(for key: String) -> Any? {
        guard Self.allowedKeys.contains(key), version == 1, timestamp.isFinite, timestamp > 0,
              value.count < 250_000, let dictionary = try? PropertyListSerialization.propertyList(from: value, format: nil) as? [String: Any],
              let value = dictionary["value"] else { return nil }
        if key == "defaultTargetLanguage" {
            guard let language = value as? String,
                  ["en", "ar", "zh-Hans", "ja", "ko", "es", "fr", "de", "it", "pt", "ru"].contains(language) else { return nil }
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
