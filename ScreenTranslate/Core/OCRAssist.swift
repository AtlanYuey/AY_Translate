import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Decides, from local evidence only, whether on-device recognition probably
/// missed or misread text, so a cloud recognizer is worth its cost. Nothing is
/// uploaded to make this decision.
nonisolated enum OCRAssist {
    /// - blocks: the on-device result (after noise suppression).
    /// - bubbles: detected text containers (skin-toned interiors removed).
    static func isNeeded(blocks: [RecognizedBlock], bubbles: [SpeechBubble], imageSize: CGSize) -> Bool {
        let positioned = blocks.filter { $0.placement == .overlay }
        // Nothing readable at all: handwriting or lettering the recognizer
        // could not start on.
        if positioned.isEmpty { return true }
        // Artwork or stylised lettering forced into another alphabet.
        if OCRNoise.misreadCount(blocks) > 0 { return true }
        // A fifth of the text was read without confidence (handwriting,
        // decorative type): Vision reports 0.3 or 0.5 for such lines.
        let total = positioned.reduce(0) { $0 + $1.original.count }
        let hesitant = positioned.filter { $0.confidence < 0.5 }
        let unsure = hesitant.reduce(0) { $0 + $1.original.count }
        if hesitant.count >= 2 && unsure * 5 >= total { return true }
        // A bubble that was partly read still holds two or more unread
        // characters. Enclosed artwork without any recognized text is ignored:
        // it looks like a bubble but holds no writing.
        var unread = 0
        for bubble in bubbles where bubble.isDialogue {
            guard positioned.contains(where: { bubble.bounds.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }) else { continue }
            let columns = BubbleText.missingColumns(in: bubble, blocks: blocks, imageSize: imageSize)
            unread += columns.reduce(0) { $0 + $1.filter { !$0.rotate }.count }
            if unread >= 2 { return true }
        }
        return false
    }
}
