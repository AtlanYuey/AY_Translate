import Foundation

nonisolated enum TranslationCoverage {
    static func needsRetry(original: String, translation: String, target: String) -> Bool {
        // Do not treat numbers, Chinese source labels or Katakana names as
        // missing translations. Only a verbatim Japanese sentence in Chinese.
        guard isChinese(target) else { return false }
        // Wrong-language output is a rejected response, never an automatic
        // second translation. This repair path is only for missing source text.
        if hasWrongTargetScript(original: original, translation: translation, target: target) { return false }
        func compact(_ value: String) -> String { value.filter { !$0.isWhitespace } }
        let source = compact(original)
        return source == compact(translation) && source.count >= 4
            && source.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) }
    }

    static func isChinese(_ target: String) -> Bool {
        target.localizedCaseInsensitiveContains("Chinese") || target.contains("中文") || target.hasPrefix("zh")
    }

    /// A whole English sentence is not a Chinese translation. Do not reject
    /// preserved Latin product names, numbers, URLs or short romanized names.
    static func hasWrongTargetScript(original: String, translation: String, target: String) -> Bool {
        guard isChinese(target) else { return false }
        let scalars = translation.unicodeScalars
        if scalars.contains(where: { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }) { return false }
        let latin = scalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }.count
        let words = translation.split { !$0.isLetter }.filter { !$0.isEmpty }.count
        return latin >= 12 && words >= 3 && translation.trimmingCharacters(in: .whitespacesAndNewlines) != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
