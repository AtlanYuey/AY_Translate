import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Readings that are not text to translate: numbers on their own, artwork or
/// sound-effect lettering misread as another alphabet, and on comic pages the
/// Latin stamps (copyright lines, signatures, handles) outside the dialogue.
/// They stay available in Full Text but receive no overlay, so nothing is
/// painted over artwork that never needed a translation.
nonisolated enum OCRNoise {
    enum Script { case cjk, latin, other }

    static func script(_ scalar: Unicode.Scalar) -> Script? {
        let value = scalar.value
        // Kana, bopomofo, CJK ideographs, halfwidth kana, Hangul.
        if (0x3040...0x312F).contains(value) || (0x31A0...0x31FF).contains(value) || (0x3400...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0xFF66...0xFF9F).contains(value)
            || (0xAC00...0xD7AF).contains(value) || (0x1100...0x11FF).contains(value) || (0x20000...0x2FA1F).contains(value) { return .cjk }
        guard CharacterSet.letters.contains(scalar) else { return nil }
        if value <= 0x024F || (0xFF21...0xFF5A).contains(value) || (0x1E00...0x1EFF).contains(value) { return .latin }
        return .other
    }

    private static func counts(_ text: String) -> (cjk: Int, latin: Int, other: Int) {
        var result = (cjk: 0, latin: 0, other: 0)
        for scalar in text.unicodeScalars {
            switch script(scalar) {
            case .cjk?: result.cjk += 1
            case .latin?: result.latin += 1
            case .other?: result.other += 1
            case nil: break
            }
        }
        return result
    }

    /// True when the text has no letters at all: digits, clock times, prices,
    /// punctuation or stray marks. A translation could only repeat it.
    static func isLetterless(_ text: String) -> Bool {
        !text.unicodeScalars.contains { script($0) != nil }
    }

    static func suppress(_ blocks: [RecognizedBlock]) -> [RecognizedBlock] {
        var page = (cjk: 0, latin: 0, other: 0)
        var containers: [CGRect] = []
        for block in blocks where block.placement == .overlay && block.confidence >= 0.3 {
            let count = counts(block.original)
            page.cjk += count.cjk; page.latin += count.latin; page.other += count.other
            if block.flow == .vertical, count.cjk > 0, let container = block.container, !containers.contains(container) {
                containers.append(container)
            }
        }
        let letters = page.cjk + page.latin + page.other
        // Japanese/Chinese/Korean is what this page is written in.
        let cjkPage = page.cjk >= 12 && page.cjk * 10 >= letters * 6
        // Vertical dialogue in at least two bubbles: a comic page.
        let comicPage = cjkPage && containers.count >= 2
        return blocks.map { block in
            guard block.placement == .overlay else { return block }
            let count = counts(block.original)
            var noise = count.cjk + count.latin + count.other == 0
            if cjkPage && count.cjk == 0 {
                // Another alphabet on a CJK page is lettering or artwork the
                // recognizer forced into characters (كم, Д, ω …).
                if count.other > 0 && page.other * 10 < letters { noise = true }
                // A few hesitant Latin letters are the same kind of misread.
                if count.other == 0 && count.latin <= 4 && block.confidence < 0.4 && block.container == nil { noise = true }
                // On a comic page Latin outside the bubbles is a stamp,
                // signature or decoration; dialogue lives in the bubbles.
                if comicPage && block.container == nil { noise = true }
            }
            guard noise else { return block }
            var result = block
            result.placement = .textOnly
            return result
        }
    }
}
