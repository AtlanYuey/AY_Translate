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
        case .chinese: "中文"
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
}

enum TranslationAppearance: String, CaseIterable, Identifiable {
    case natural = "Natural"
    case readable = "Readable"
    case minimal = "Minimal"

    var id: String { rawValue }

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
    @Published var source: AppLanguage {
        didSet { defaults.set(source.rawValue, forKey: Keys.source) }
    }
    @Published var target: AppLanguage {
        didSet { defaults.set(target.rawValue, forKey: Keys.target) }
    }
    @Published var appearance: TranslationAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    @Published var savesHistory: Bool {
        didSet { defaults.set(savesHistory, forKey: Keys.savesHistory) }
    }
    @Published var ocrEngine: OCREngine {
        didSet { defaults.set(ocrEngine.rawValue, forKey: "ocrEngine") }
    }
    @Published var translationEngine: TranslationEngine {
        didSet { defaults.set(translationEngine.rawValue, forKey: "translationEngine") }
    }
    @Published var preference: TranslationPreference {
        didSet { defaults.set(preference.rawValue, forKey: "translationPreference") }
    }
    @Published var overlayTextScale: Double {
        didSet { defaults.set(overlayTextScale, forKey: "overlayTextScale") }
    }
    @Published private(set) var aiOCR: AIServiceConfiguration
    @Published private(set) var aiTranslation: AIServiceConfiguration
    let keyStore: any APIKeyStoring

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, keyStore: (any APIKeyStoring)? = nil) {
        self.defaults = defaults
        self.keyStore = keyStore ?? KeychainStore()
        source = AppLanguage(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .automatic
        target = AppLanguage(rawValue: defaults.string(forKey: Keys.target) ?? "") ?? .english
        appearance = TranslationAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .natural
        savesHistory = defaults.bool(forKey: Keys.savesHistory)
        ocrEngine = OCREngine(rawValue: defaults.string(forKey: "ocrEngine") ?? "") ?? .appleVision
        translationEngine = TranslationEngine(rawValue: defaults.string(forKey: "translationEngine") ?? "") ?? .apple
        preference = TranslationPreference(rawValue: defaults.string(forKey: "translationPreference") ?? "") ?? .speed
        let textScale = defaults.double(forKey: "overlayTextScale")
        overlayTextScale = textScale == 0 ? 1 : min(1.8, max(0.8, textScale))
        aiOCR = defaults.data(forKey: "ai.ocr").flatMap { try? JSONDecoder().decode(AIServiceConfiguration.self, from: $0) } ?? AIServiceConfiguration()
        aiTranslation = defaults.data(forKey: "ai.translation").flatMap { try? JSONDecoder().decode(AIServiceConfiguration.self, from: $0) } ?? AIServiceConfiguration()
    }

    func configuration(for profile: AIProfile) -> AIServiceConfiguration {
        profile == .ocr ? aiOCR : aiTranslation
    }

    func saveConfiguration(_ configuration: AIServiceConfiguration, keyReplacement: String?, for profile: AIProfile) throws {
        try configuration.validate()
        let previous = self.configuration(for: profile)
        // A credential belonging to one endpoint must not silently follow a new destination.
        if let keyReplacement {
            try keyStore.save(keyReplacement.trimmingCharacters(in: .whitespacesAndNewlines), for: profile)
        } else if (try? previous.endpoint()) != (try? configuration.endpoint()) {
            try keyStore.save("", for: profile)
        }
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: "ai." + profile.rawValue)
        if profile == .ocr { aiOCR = configuration } else { aiTranslation = configuration }
    }

    func hasConsent(for profile: AIProfile) -> Bool {
        let id = configuration(for: profile).consentID
        return !id.isEmpty && defaults.string(forKey: "cloudConsent." + profile.rawValue) == id
    }

    func grantConsent(for profile: AIProfile) {
        defaults.set(configuration(for: profile).consentID, forKey: "cloudConsent." + profile.rawValue)
    }

    func revokeCloudConsent() {
        AIProfile.allCases.forEach { defaults.removeObject(forKey: "cloudConsent." + $0.rawValue) }
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
    @Published private(set) var items: [HistoryItem] = []
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? folder.appendingPathComponent("translation-history.json")
        load()
    }

    func add(_ document: TranslationDocument) {
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
        items.remove(atOffsets: offsets)
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        items = decoded
    }

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
