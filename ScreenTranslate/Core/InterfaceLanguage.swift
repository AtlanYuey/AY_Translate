import Foundation

nonisolated enum ResultDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case overlay, original, text
    var id: Self { self }
    var name: String {
        switch self { case .overlay: "Translated"; case .original: "Original"; case .text: "Full Text" }
    }
}

nonisolated enum InterfaceLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case system = "system"
    var id: Self { self }
    var name: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .system: "Follow System"
        }
    }

    func resolvedIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        for identifier in preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if normalized.hasPrefix("zh") {
                return normalized.contains("hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk") || normalized.hasPrefix("zh-mo") ? "zh-Hant" : "zh-Hans"
            }
            if normalized.hasPrefix("en") { return "en" }
        }
        return "en"
    }
}
