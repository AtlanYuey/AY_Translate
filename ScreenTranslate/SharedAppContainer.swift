import Foundation

/// The action extension and app use the same preferences, history and keychain
/// identity. No image is used as a disk handoff for the shared-screen workflow.
@MainActor
enum SharedAppContainer {
    static var hostIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "ContainingAppBundleIdentifier") as? String
            ?? (Bundle.main.bundleIdentifier ?? "com.bahaanajjar.ScreenTranslate").replacingOccurrences(of: ".ShareExtension", with: "")
    }
    static var groupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "SharedAppGroup") as? String ?? "group." + hostIdentifier
    }
    static var url: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) }
    static var preferences: UserDefaults {
        guard url != nil, let shared = UserDefaults(suiteName: groupIdentifier) else { return .standard }
        if Bundle.main.bundleURL.pathExtension != "appex", !shared.bool(forKey: "shared.preferences.migrated") {
            for (key, value) in UserDefaults.standard.dictionaryRepresentation() where isPreferenceKey(key) {
                if shared.object(forKey: key) == nil { shared.set(value, forKey: key) }
            }
            shared.set(true, forKey: "shared.preferences.migrated")
            migrateHistory()
        }
        return shared
    }

    static func isPreferenceKey(_ key: String) -> Bool {
        ["defaultSourceLanguage", "defaultTargetLanguage", "translationAppearance", "saveTranslationHistory", "ocrEngine", "translationEngine", "translationPreference", "overlayTextScale", "defaultResultMode", "interfaceLanguage"].contains(key)
            || key.hasPrefix("ai.") || key.hasPrefix("cloudConsent.")
    }

    private static func migrateHistory() {
        guard let url else { return }
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("translation-history.json")
        let destination = url.appendingPathComponent("translation-history.json")
        guard !FileManager.default.fileExists(atPath: destination.path), FileManager.default.fileExists(atPath: old.path) else { return }
        do {
            try FileManager.default.copyItem(at: old, to: destination)
            try FileManager.default.removeItem(at: old)
        } catch { /* Keep the old file if migration cannot finish. */ }
    }
}
