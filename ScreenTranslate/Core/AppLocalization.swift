import Foundation

nonisolated enum AppLocalization {
    static var language: InterfaceLanguage {
        InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "") ?? .simplifiedChinese
    }

    static func text(_ key: String, language: InterfaceLanguage? = nil, bundle: Bundle = .main) -> String {
        let identifier = (language ?? self.language).resolvedIdentifier()
        guard let path = bundle.path(forResource: identifier, ofType: "lproj"), let localized = Bundle(path: path) else { return key }
        return localized.localizedString(forKey: key, value: key, table: nil)
    }

    static func formatted(_ key: String, _ arguments: CVarArg..., language: InterfaceLanguage? = nil) -> String {
        String(format: text(key, language: language), locale: Locale(identifier: (language ?? self.language).resolvedIdentifier()), arguments: arguments)
    }
}
