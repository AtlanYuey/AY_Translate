import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated enum TextPlacement: Hashable, Sendable { case overlay, textOnly }
nonisolated enum TextFlow: Hashable, Sendable { case horizontal, vertical }

nonisolated struct RecognizedBlock: Identifiable, Hashable, Sendable {
    let id: UUID
    let original: String
    var translation: String
    /// Vision's normalized coordinates: origin at the bottom left.
    let boundingBox: CGRect
    let confidence: Float
    var placement: TextPlacement = .overlay
    /// Height of one original OCR line, normalized to the upright image height.
    /// Preserve this when joining lines: a paragraph's union is not a font size.
    var sourceLineHeight: CGFloat? = nil
    var flow: TextFlow = .horizontal
    /// One vertical column's glyph width, normalized to image width.
    var sourceColumnWidth: CGFloat? = nil
    /// Local glyph guidance only; actual ink is segmented before restoration.
    var sourceGlyphBoxes: [CGRect]? = nil

    var originalColumnWidth: CGFloat {
        sourceColumnWidth ?? boundingBox.width / CGFloat(max(1, original.split(separator: "\n").count))
    }

    var originalLineHeight: CGFloat {
        if let sourceLineHeight, sourceLineHeight.isFinite, sourceLineHeight > 0 {
            return min(sourceLineHeight, boundingBox.height)
        }
        let lines = max(1, original.split(separator: "\n", omittingEmptySubsequences: false).count)
        return max(0, boundingBox.height) / CGFloat(lines)
    }
}

nonisolated struct OCRResult: Sendable {
    var blocks: [RecognizedBlock]
    var notice: String?
}

nonisolated struct AIRecognizedRegion: Codable, Sendable {
    var id: String?
    var text: String
    /// [x, y, width, height], normalized, origin at the top left.
    var box: [Double]?
}

nonisolated enum OCRAlignment {
    static func visionRect(from box: [Double]?) -> CGRect? {
        guard let box, box.count == 4, box.allSatisfy(\.isFinite),
              box[0] >= 0, box[1] >= 0, box[2] > 0, box[3] > 0,
              box[0] + box[2] <= 1.00001, box[1] + box[3] <= 1.00001 else { return nil }
        return CGRect(x: box[0], y: max(0, 1 - box[1] - box[3]), width: box[2], height: box[3])
    }

    static func topLeftBox(_ rect: CGRect) -> [Double] {
        [rect.minX, 1 - rect.maxY, rect.width, rect.height]
    }

    /// AI coordinates alone are never trusted for overlays. An ID or a unique
    /// text/geometry match must resolve to a real, local Vision observation.
    static func resolve(_ regions: [AIRecognizedRegion], anchors: [RecognizedBlock]) throws -> OCRResult {
        guard !regions.isEmpty, regions.count <= 500,
              regions.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 8_000 }) else {
            throw AIServiceError.invalidRegions
        }
        let identifiers = regions.compactMap(\.id)
        guard Set(identifiers).count == identifiers.count else { throw AIServiceError.invalidRegions }
        var blocks = anchors
        var used = Set<UUID>()
        var unmatched: [RecognizedBlock] = []
        for region in regions {
            let text = region.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let byID = region.id.flatMap(UUID.init(uuidString:)).flatMap { id in anchors.firstIndex { $0.id == id } }
            let candidates = anchors.indices.filter { index in
                guard let rect = visionRect(from: region.box) else { return false }
                let anchor = anchors[index].boundingBox
                let intersection = anchor.intersection(rect)
                let overlap = intersection.isNull ? 0 : intersection.width * intersection.height / max(anchor.width * anchor.height, rect.width * rect.height)
                return overlap >= 0.65 && similarity(text, anchors[index].original) >= 0.55
            }
            let index = byID ?? (candidates.count == 1 ? candidates.first : nil)
            if let index, !used.contains(anchors[index].id), similarity(text, anchors[index].original) >= 0.65 {
                used.insert(anchors[index].id)
                let anchor = anchors[index]
                blocks[index] = RecognizedBlock(id: anchor.id, original: text, translation: text, boundingBox: anchor.boundingBox, confidence: anchor.confidence, sourceLineHeight: anchor.originalLineHeight, flow: anchor.flow, sourceColumnWidth: anchor.sourceColumnWidth, sourceGlyphBoxes: anchor.sourceGlyphBoxes)
            } else {
                unmatched.append(RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: .zero, confidence: 0, placement: .textOnly))
            }
        }
        blocks.append(contentsOf: unmatched)
        return OCRResult(blocks: blocks, notice: unmatched.isEmpty ? nil : "Some AI text has no verified local position. It is available in Full Text; only Vision-verified regions are overlaid.")
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        let b = Array(rhs.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        if a == b { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        // Bound work on untrusted model output; adjacent-pair overlap handles OCR corrections.
        let aa = Array(a.prefix(2_000)), bb = Array(b.prefix(2_000))
        if min(aa.count, bb.count) == 1 { return aa.first == bb.first ? 0.5 : 0 }
        let pairsA = Set(zip(aa, aa.dropFirst()).map { String($0.0) + String($0.1) })
        let pairsB = Set(zip(bb, bb.dropFirst()).map { String($0.0) + String($0.1) })
        return Double(2 * pairsA.intersection(pairsB).count) / Double(pairsA.count + pairsB.count)
    }
}
