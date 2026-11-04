import Foundation

nonisolated enum TranslationCoverage {
    static func needsRetry(original: String, translation: String, target: String) -> Bool {
        // Do not treat numbers, Chinese source labels or Katakana names as
        // missing translations. Only a verbatim Japanese sentence in Chinese.
        guard target.localizedCaseInsensitiveContains("Chinese") || target.contains("中文") || target.hasPrefix("zh") else { return false }
        func compact(_ value: String) -> String { value.filter { !$0.isWhitespace } }
        let source = compact(original)
        return source == compact(translation) && source.count >= 4
            && source.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) }
    }
}
