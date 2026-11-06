import Combine
import Foundation
import SwiftUI
import UIKit

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case automatic
    case english = "en"
    case arabic = "ar"
    case chinese = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .automatic: "Auto Detect"
        case .english: "English"
        case .arabic: "Arabic"
        case .chinese: "Chinese"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .portuguese: "Portuguese"
        case .russian: "Russian"
        }
    }

    var nativeName: String {
        switch self {
        case .automatic: "Recommended"
        case .english: "English"
        case .arabic: "العربية"
        case .chinese: "简体中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .italian: "Italiano"
        case .portuguese: "Português"
        case .russian: "Русский"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "sparkles"
        case .english: "character.book.closed"
        case .arabic: "character.textbox"
        case .chinese, .japanese, .korean: "character"
        default: "textformat"
        }
    }

    var localeLanguage: Locale.Language? {
        guard self != .automatic else { return nil }
        return Locale.Language(identifier: rawValue)
    }

    var recognitionCode: String? {
        guard self != .automatic else { return nil }
        return rawValue
    }

    var isRightToLeft: Bool { self == .arabic }

    static var sourceLanguages: [AppLanguage] { allCases }
    static var targetLanguages: [AppLanguage] { allCases.filter { $0 != .automatic } }

    static func targetLanguage(saved: String?, preferred: String) -> AppLanguage {
        if let saved, let language = AppLanguage(rawValue: saved), language != .automatic { return language }
        if preferred.hasPrefix("zh") { return .chinese }
        return targetLanguages.first { preferred == $0.rawValue || preferred.hasPrefix($0.rawValue + "-") } ?? .english
    }
}

enum TranslationAppearance: String, CaseIterable, Identifiable {
    case natural = "Natural"
    case readable = "Readable"
    case minimal = "Minimal"

    var id: String { rawValue }

    var name: String {
        switch self { case .natural: "Background Match"; case .readable: "High Contrast"; case .minimal: "Text Only" }
    }

    var detail: String {
        switch self {
        case .natural: "Blends into the original screen"
        case .readable: "Strong backgrounds for clarity"
        case .minimal: "Subtle, lightweight overlays"
        }
    }
}

struct TranslationDocument: Identifiable {
    let id: UUID
    let image: UIImage
    var blocks: [RecognizedBlock]
    let source: AppLanguage
    let target: AppLanguage
    let createdAt: Date

    var originalText: String { blocks.map(\.original).joined(separator: "\n") }
    var translatedText: String { blocks.map(\.translation).joined(separator: "\n") }
}

struct HistoryItem: Identifiable, Codable {
    let id: UUID
    let imageData: Data
    let sourceName: String
    let targetName: String
    let date: Date
    let originalText: String
    let translatedText: String

    var image: UIImage? { UIImage(data: imageData) }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var iCloudSyncEnabled: Bool = false {
        didSet {
            defaults.set(iCloudSyncEnabled, forKey: "iCloudSyncEnabled")
            configureCloudSync()
        }
    }
    @Published private(set) var iCloudSyncMessage: String?
    private var cloudSync: CloudSettingsSync?
    private var applyingCloudSettings = false
    private var refreshingSharedSettings = false
    private let isPersistentSettings: Bool

    private func configureCloudSync() {
        cloudSync?.stop(); cloudSync = nil
        #if !SCREEN_TRANSLATE_SHARE_EXTENSION
        guard iCloudSyncEnabled, isPersistentSettings else { return }
        if let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let profile = try? Data(contentsOf: profileURL, options: .mappedIfSafe),
           SigningCapabilities.permitsCloudSettings(profile: profile) == false {
            iCloudSyncMessage = "This signing profile does not permit iCloud settings sync. Re-sign with an iCloud Key-Value Store enabled profile and keep the same app identity on every device."
            return
        }
        let sync = CloudSettingsSync(defaults: defaults, apply: { [weak self] changes in
            guard let self else { return false }
            // A synced endpoint change must never send the old device's key to
            // a different host. Credentials and permissions remain device-local.
            if let data = changes["ai.services.v1"] as? Data,
               let catalog = try? JSONDecoder().decode(AIServiceCatalog.self, from: data) {
                do {
                    for old in serviceCatalog.services {
                        let replacement = catalog.services.first { $0.id == old.id }
                        if replacement == nil || (try? old.configuration.endpoint()) != (try? replacement?.configuration.endpoint()) {
                            try deleteAPIKey(forService: old.id)
                        }
                    }
                } catch { iCloudSyncMessage = error.localizedDescription; return false }
            }
            applyingCloudSettings = true
            for (key, value) in changes { persist(value, forKey: key) }
            refreshSharedPreferences()
            applyingCloudSettings = false
            return true
        }, status: { [weak self] message in
            guard let self else { return }
            iCloudSyncMessage = message
            if iCloudSyncEnabled && !defaults.bool(forKey: "iCloudSyncEnabled") { iCloudSyncEnabled = false }
        })
        cloudSync = sync
        sync.start()
        #endif
    }

    func uploadSettingsToCloud() { cloudSync?.uploadLocalSettings() }
    func resumeSettingsSync() { refreshSharedPreferences(); cloudSync?.resume() }

    @Published var source: AppLanguage {
        didSet { persist(source.rawValue, forKey: Keys.source) }
    }
    @Published var target: AppLanguage {
        didSet { persist(target.rawValue, forKey: Keys.target) }
    }
    @Published var appearance: TranslationAppearance {
        didSet { persist(appearance.rawValue, forKey: Keys.appearance) }
    }
    @Published var savesHistory: Bool {
        didSet { persist(savesHistory, forKey: Keys.savesHistory) }
    }
    @Published var ocrEngine: OCREngine {
        didSet { persist(ocrEngine.rawValue, forKey: "ocrEngine") }
    }
    @Published var translationEngine: TranslationEngine {
        didSet { persist(translationEngine.rawValue, forKey: "translationEngine") }
    }
    @Published var preference: TranslationPreference {
        didSet { persist(preference.rawValue, forKey: "translationPreference") }
    }
    @Published var overlayTextScale: Double {
        didSet { persist(overlayTextScale, forKey: "overlayTextScale") }
    }
    @Published var showsTextDetailsOnTap: Bool {
        didSet { persist(showsTextDetailsOnTap, forKey: "showsTextDetailsOnTap") }
    }
    @Published var defaultResultMode: ResultDisplayMode {
        didSet { persist(defaultResultMode.rawValue, forKey: "defaultResultMode") }
    }
    @Published private(set) var serviceCatalog: AIServiceCatalog
    @Published private(set) var serviceMigrationError: String?
    @Published var interfaceLanguage: InterfaceLanguage {
        didSet { persist(interfaceLanguage.rawValue, forKey: "interfaceLanguage") }
    }
    var aiOCR: AIServiceConfiguration { configuration(for: .ocr) }
    var aiTranslation: AIServiceConfiguration { configuration(for: .translation) }
    var interfaceLocale: Locale { Locale(identifier: interfaceLanguage.resolvedIdentifier()) }
    let keyStore: any APIKeyStoring

    private let defaults: UserDefaults
    private let syncThroughKeychain: Bool
    @Published private(set) var synchronizationError: String?

    init(defaults suppliedDefaults: UserDefaults? = nil, keyStore suppliedStore: (any APIKeyStoring)? = nil, syncThroughKeychain: Bool? = nil) {
        let defaults = suppliedDefaults ?? SharedAppContainer.preferences
        let store = suppliedStore ?? KeychainStore()
        // A real App Group is authoritative. A stale Keychain mirror must not
        // overwrite its target language; the bridge is only a signing fallback.
        let synchronize = syncThroughKeychain ?? (suppliedDefaults == nil && SharedAppContainer.url == nil)
        self.defaults = defaults
        self.keyStore = store
        self.syncThroughKeychain = synchronize
        self.isPersistentSettings = suppliedDefaults == nil
        var syncMessage: String?
        if synchronize {
            do { try PreferencesBridge.synchronize(defaults, store: store) }
            catch { syncMessage = error.localizedDescription }
        }
        source = AppLanguage(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .automatic
        target = AppLanguage.targetLanguage(saved: defaults.string(forKey: Keys.target), preferred: InterfaceLanguage.system.resolvedIdentifier())
        appearance = TranslationAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .natural
        savesHistory = defaults.bool(forKey: Keys.savesHistory)
        ocrEngine = OCREngine(rawValue: defaults.string(forKey: "ocrEngine") ?? "") ?? .appleVision
        translationEngine = TranslationEngine(rawValue: defaults.string(forKey: "translationEngine") ?? "") ?? .apple
        preference = TranslationPreference(rawValue: defaults.string(forKey: "translationPreference") ?? "") ?? .speed
        let textScale = defaults.double(forKey: "overlayTextScale")
        overlayTextScale = textScale == 0 ? 1 : min(1.8, max(0.8, textScale))
        showsTextDetailsOnTap = defaults.bool(forKey: "showsTextDetailsOnTap")
        defaultResultMode = ResultDisplayMode(rawValue: defaults.string(forKey: "defaultResultMode") ?? "") ?? .overlay
        serviceCatalog = defaults.data(forKey: "ai.services.v1").flatMap { try? JSONDecoder().decode(AIServiceCatalog.self, from: $0) } ?? AIServiceCatalog()
        interfaceLanguage = InterfaceLanguage(rawValue: defaults.string(forKey: "interfaceLanguage") ?? "") ?? .system
        synchronizationError = syncMessage
        migrateLegacyServices()
        iCloudSyncEnabled = defaults.bool(forKey: "iCloudSyncEnabled")
        configureCloudSync()
    }

    func text(_ key: String) -> String { AppLocalization.text(key, language: interfaceLanguage) }
    var interfaceLayoutDirection: LayoutDirection { interfaceLanguage.resolvedIdentifier() == "ar" ? .rightToLeft : .leftToRight }

    func refreshSharedPreferences() {
        if syncThroughKeychain {
            do { try PreferencesBridge.synchronize(defaults, store: keyStore); synchronizationError = nil }
            catch { synchronizationError = error.localizedDescription }
        }
        // Refresh is a read. Publishing an unchanged or default property here
        // used to write the whole snapshot back into the shared mirror.
        refreshingSharedSettings = true
        defer { refreshingSharedSettings = false }
        let saved = AppSettings(defaults: defaults, keyStore: keyStore, syncThroughKeychain: false)
        source = saved.source; target = saved.target; appearance = saved.appearance
        savesHistory = saved.savesHistory; ocrEngine = saved.ocrEngine; translationEngine = saved.translationEngine
        showsTextDetailsOnTap = saved.showsTextDetailsOnTap
        preference = saved.preference; overlayTextScale = saved.overlayTextScale; defaultResultMode = saved.defaultResultMode
        interfaceLanguage = saved.interfaceLanguage; serviceCatalog = saved.serviceCatalog; serviceMigrationError = saved.serviceMigrationError
    }

    func configuration(for profile: AIProfile) -> AIServiceConfiguration {
        serviceCatalog.selected(for: profile)?.configuration ?? AIServiceConfiguration()
    }

    func selectedService(for profile: AIProfile) -> SavedAIService? { serviceCatalog.selected(for: profile) }

    func readAPIKey(for profile: AIProfile) throws -> String {
        guard let service = selectedService(for: profile) else { throw ServiceCatalogError.serviceMissing }
        try finishKeyMigration(for: service.id)
        return try keyStore.read(.service(service.id))
    }

    func readAPIKey(forService id: UUID) throws -> String {
        try finishKeyMigration(for: id)
        return try keyStore.read(.service(id))
    }

    func deleteAPIKey(forService id: UUID) throws {
        try keyStore.save("", for: .service(id))
        for profile in AIProfile.allCases where defaults.string(forKey: "ai.migration." + profile.rawValue) == id.uuidString {
            try keyStore.save("", for: profile == .ocr ? .ocr : .translation)
            removePreference(forKey: "ai.migration." + profile.rawValue)
        }
    }

    func saveService(_ service: SavedAIService, keyReplacement: String?) throws {
        try service.validate()
        var updated = serviceCatalog
        try updated.upsert(service)
        let data = try JSONEncoder().encode(updated)
        let previous = serviceCatalog.services.first { $0.id == service.id }
        if let keyReplacement {
            try keyStore.save(keyReplacement.trimmingCharacters(in: .whitespacesAndNewlines), for: .service(service.id))
        } else if let previous, (try? previous.configuration.endpoint()) != (try? service.configuration.endpoint()) {
            try deleteAPIKey(forService: service.id)
        }
        persist(data, forKey: "ai.services.v1")
        serviceCatalog = updated
        if updated.selected(for: .ocr) == nil { ocrEngine = .appleVision }
    }

    func selectService(_ id: UUID?, for profile: AIProfile, enableEngine: Bool = true) throws {
        var updated = serviceCatalog
        try updated.select(id, for: profile)
        persist(try JSONEncoder().encode(updated), forKey: "ai.services.v1")
        serviceCatalog = updated
        if enableEngine {
            if profile == .ocr { ocrEngine = id == nil ? .appleVision : .ai }
            else { translationEngine = id == nil ? .apple : .ai }
        }
    }

    func removeService(_ id: UUID) throws {
        var updated = serviceCatalog
        updated.remove(id)
        let data = try JSONEncoder().encode(updated)
        try deleteAPIKey(forService: id)
        persist(data, forKey: "ai.services.v1")
        serviceCatalog = updated
        if updated.selected(for: .ocr) == nil { ocrEngine = .appleVision }
        if updated.selected(for: .translation) == nil { translationEngine = .apple }
        for profile in AIProfile.allCases { removePreference(forKey: "cloudConsent." + profile.rawValue + "." + id.uuidString) }
    }

    /// Kept for existing callers and regression tests; does not turn on cloud engines.
    func saveConfiguration(_ configuration: AIServiceConfiguration, keyReplacement: String?, for profile: AIProfile) throws {
        var service = selectedService(for: profile) ?? SavedAIService(name: profile.title, supportsVision: true)
        service.configuration = configuration
        try saveService(service, keyReplacement: keyReplacement)
        try selectService(service.id, for: profile, enableEngine: false)
    }

    func consentIdentity(for profile: AIProfile) -> String { selectedService(for: profile)?.consentID ?? "" }

    func hasConsent(for profile: AIProfile) -> Bool {
        guard let service = selectedService(for: profile) else { return false }
        return defaults.string(forKey: "cloudConsent." + profile.rawValue + "." + service.id.uuidString) == service.consentID
    }

    func grantConsent(for profile: AIProfile) {
        guard let service = selectedService(for: profile) else { return }
        persist(service.consentID, forKey: "cloudConsent." + profile.rawValue + "." + service.id.uuidString)
    }

    func revokeCloudConsent() {
        for service in serviceCatalog.services {
            for profile in AIProfile.allCases { removePreference(forKey: "cloudConsent." + profile.rawValue + "." + service.id.uuidString) }
        }
    }

    private func migrateLegacyServices() {
        if !defaults.bool(forKey: "ai.catalog.initialized") {
            for profile in AIProfile.allCases {
                guard let data = defaults.data(forKey: "ai." + profile.rawValue),
                      let configuration = try? JSONDecoder().decode(AIServiceConfiguration.self, from: data),
                      (try? configuration.validate()) != nil else { continue }
                let marker = "ai.migration." + profile.rawValue
                let id = defaults.string(forKey: marker).flatMap(UUID.init(uuidString:)) ?? UUID()
                let service = SavedAIService(id: id, name: profile == .ocr ? "原有 OCR 服务" : "原有翻译服务", configuration: configuration, supportsVision: true)
                do {
                    try serviceCatalog.upsert(service)
                    try serviceCatalog.select(id, for: profile)
                    persist(id.uuidString, forKey: marker)
                } catch { serviceMigrationError = error.localizedDescription }
            }
            if let data = try? JSONEncoder().encode(serviceCatalog) {
                persist(data, forKey: "ai.services.v1")
                persist(true, forKey: "ai.catalog.initialized")
            }
        }
        for service in serviceCatalog.services {
            do { try finishKeyMigration(for: service.id) }
            catch { serviceMigrationError = "Unlock the device to finish migrating saved API keys." }
        }
    }

    private func finishKeyMigration(for id: UUID) throws {
        for profile in AIProfile.allCases {
            let marker = "ai.migration." + profile.rawValue
            guard defaults.string(forKey: marker) == id.uuidString else { continue }
            let legacy: APIKeySlot = profile == .ocr ? .ocr : .translation
            let current = try keyStore.read(.service(id))
            let old = try keyStore.read(legacy)
            if current.isEmpty && !old.isEmpty { try keyStore.save(old, for: .service(id)) }
            try keyStore.save("", for: legacy)
            removePreference(forKey: marker)
        }
        if AIProfile.allCases.allSatisfy({ defaults.string(forKey: "ai.migration." + $0.rawValue) == nil }) {
            serviceMigrationError = nil
        }
    }

    private func persist(_ value: Any, forKey key: String) {
        guard !refreshingSharedSettings else { return }
        defaults.set(value, forKey: key)
        if !applyingCloudSettings { cloudSync?.changed(value, key: key) }
        guard syncThroughKeychain else { return }
        do { try PreferencesBridge.update(value, key: key, defaults: defaults, store: keyStore); synchronizationError = nil }
        catch { synchronizationError = error.localizedDescription }
    }

    private func removePreference(forKey key: String) {
        defaults.removeObject(forKey: key)
        guard syncThroughKeychain else { return }
        do { try PreferencesBridge.update(nil, key: key, defaults: defaults, store: keyStore) }
        catch { synchronizationError = error.localizedDescription }
    }

    /// Explicit, local-only fallback for signatures that strip both shared groups.
    /// Keys stay in memory and Keychain; this token is never saved to a file/log.
    func configurationTransfer(now: Date = Date()) throws -> String {
        let values = defaults.dictionaryRepresentation().filter {
            SharedAppContainer.isPreferenceKey($0.key) && !$0.key.hasPrefix("cloudConsent.") && !$0.key.hasPrefix("ai.migration.")
        }
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        var keys: [String: String] = [:]
        for service in serviceCatalog.services { keys[service.id.uuidString] = try readAPIKey(forService: service.id) }
        let payload = ConfigurationTransfer(version: 1, expiresAt: now.addingTimeInterval(60), preferences: data, keys: keys)
        return "TS-CONFIG-1:" + (try JSONEncoder().encode(payload)).base64EncodedString()
    }

    func importConfiguration(_ token: String, now: Date = Date()) throws {
        guard token.hasPrefix("TS-CONFIG-1:"), token.utf8.count <= 1_500_000,
              let data = Data(base64Encoded: String(token.dropFirst(12))),
              let payload = try? JSONDecoder().decode(ConfigurationTransfer.self, from: data), payload.version == 1,
              let values = try PropertyListSerialization.propertyList(from: payload.preferences, format: nil) as? [String: Any],
              values.keys.allSatisfy({ SharedAppContainer.isPreferenceKey($0) && !$0.hasPrefix("cloudConsent.") && !$0.hasPrefix("ai.migration.") }),
              let catalogData = values["ai.services.v1"] as? Data,
              let catalog = try? JSONDecoder().decode(AIServiceCatalog.self, from: catalogData), catalog.services.count <= 100,
              Set(catalog.services.map(\.id)).count == catalog.services.count,
              payload.keys.keys.allSatisfy({ id in catalog.services.contains { $0.id.uuidString == id } }) else { throw ConfigurationTransferError.invalid }
        guard payload.expiresAt > now, payload.expiresAt <= now.addingTimeInterval(120) else { throw ConfigurationTransferError.expired }
        for service in catalog.services { try service.validate() }
        // Validate everything before committing. Replacing credentials never puts
        // them into preferences or grants permission to upload screenshots/text.
        for service in catalog.services { try keyStore.save(payload.keys[service.id.uuidString] ?? "", for: .service(service.id)) }
        revokeCloudConsent()
        for (key, value) in values { persist(value, forKey: key) }
        refreshSharedPreferences()
    }

    private enum Keys {
        static let source = "defaultSourceLanguage"
        static let target = "defaultTargetLanguage"
        static let appearance = "translationAppearance"
        static let savesHistory = "saveTranslationHistory"
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var items: [HistoryItem] = []
    private let fileURL: URL
    private var loaded = false

    init(fileURL: URL? = nil) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? (SharedAppContainer.url ?? folder).appendingPathComponent("translation-history.json")
        // A screenshot extension does not need to decode the full archive at
        // startup, especially when saving history is disabled.
        if !ProcessingMemory.isExtension { load() }
    }

    func add(_ document: TranslationDocument) {
        if !loaded { load() }
        guard let data = document.image.jpegData(compressionQuality: 0.55) else { return }
        let item = HistoryItem(
            id: document.id,
            imageData: data,
            sourceName: document.source.name,
            targetName: document.target.name,
            date: document.createdAt,
            originalText: document.originalText,
            translatedText: document.translatedText
        )
        items.insert(item, at: 0)
        items = Array(items.prefix(20))
        save()
    }

    func delete(at offsets: IndexSet) {
        if !loaded { load() }
        items.remove(atOffsets: offsets)
        save()
    }

    func clear() {
        loaded = true
        items.removeAll()
        save()
    }

    func load() {
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        items = decoded
    }

    func releaseCache() { items = []; loaded = false }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // History is optional; a failed local write must not interrupt translation.
        }
    }
}
