import Foundation

nonisolated enum AppLocalization {
    static var language: InterfaceLanguage {
        let shared = (Bundle.main.object(forInfoDictionaryKey: "SharedAppGroup") as? String).flatMap(UserDefaults.init(suiteName:))
        return InterfaceLanguage(rawValue: shared?.string(forKey: "interfaceLanguage") ?? UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "") ?? .system
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
