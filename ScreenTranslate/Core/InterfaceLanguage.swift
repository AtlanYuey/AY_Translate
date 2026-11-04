import Foundation

nonisolated enum ResultDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case overlay, original, text
    var id: Self { self }
    var name: String {
        switch self { case .overlay: "Translated"; case .original: "Original"; case .text: "Full Text" }
    }
}

nonisolated enum InterfaceLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system = "system"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case spanish = "es"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case arabic = "ar"
    var id: Self { self }
    var name: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .system: "Follow System"
        case .spanish: "Español"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .french: "Français"
        case .german: "Deutsch"
        case .italian: "Italiano"
        case .portuguese: "Português"
        case .russian: "Русский"
        case .arabic: "العربية"
        }
    }

    func resolvedIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        for identifier in preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if normalized.hasPrefix("zh") {
                return normalized.contains("hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") ? "zh-Hant" : "zh-Hans"
            }
            if let match = Self.allCases.first(where: { $0 != .system && normalized.split(separator: "-").first == Substring($0.rawValue) }) { return match.rawValue }
        }
        return "en"
    }
}
