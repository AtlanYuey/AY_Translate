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
    /// The enclosing dialogue bubble's usable area (Vision-normalized). Lines
    /// sharing a bubble are translated together and laid out in this area.
    var container: CGRect? = nil
    /// Distinct lettering colour (RGB 0–1) when the text is not black/grey.
    var inkColor: [Double]? = nil

    func shouldOverlay(showUnchanged: Bool) -> Bool {
        placement == .overlay && !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (showUnchanged || translation != original)
    }

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

    init(id: String?, text: String, box: [Double]?) {
        self.id = id; self.text = text; self.box = box
    }

    private enum CodingKeys: String, CodingKey { case id, text, box, box_2d }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Both 0 and "0" identify the same compact anchor. Gemini commonly
        // emits integer IDs even when the prompt's example uses strings.
        if let integer = try? values.decode(Int.self, forKey: .id) { id = String(integer) }
        else { id = try? values.decodeIfPresent(String.self, forKey: .id) }
        text = try values.decode(String.self, forKey: .text)
        if let box = try? values.decodeIfPresent([Double].self, forKey: .box) { self.box = box }
        else { box = (try? values.decodeIfPresent([Double].self, forKey: .box_2d)).flatMap(Self.normalizedBox2D) }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(id, forKey: .id)
        try values.encode(text, forKey: .text)
        try values.encodeIfPresent(box, forKey: .box)
    }

    /// Gemini's native detection format: [ymin, xmin, ymax, xmax] on a 0–1000
    /// grid, origin top left. Converted to the app's [x, y, width, height].
    static func normalizedBox2D(_ values: [Double]) -> [Double]? {
        guard values.count == 4, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let scale = values.allSatisfy { $0 <= 1 } ? 1.0 : 1000.0
        let v = values.map { min(1, $0 / scale) }
        let (top, left, bottom, right) = (min(v[0], v[2]), min(v[1], v[3]), max(v[0], v[2]), max(v[1], v[3]))
        guard right > left, bottom > top else { return nil }
        return [left, top, right - left, bottom - top]
    }
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
    static func resolve(_ regions: [AIRecognizedRegion], anchors: [RecognizedBlock], locator: InkLocator? = nil) throws -> OCRResult {
        // An empty reading answers "nothing is written here" for an unread
        // anchor; it is not an error.
        let regions = regions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !regions.isEmpty, regions.count <= 500, regions.allSatisfy({ $0.text.count <= 8_000 }) else {
            throw AIServiceError.invalidRegions
        }
        let identifiers = regions.compactMap(\.id)
        guard Set(identifiers).count == identifiers.count else { throw AIServiceError.invalidRegions }
        var blocks = anchors
        var used = Set<UUID>()
        var unmatched: [RecognizedBlock] = []
        var located: [RecognizedBlock] = []
        for region in regions {
            let text = region.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let byID = region.id.flatMap(UUID.init(uuidString:)).flatMap { id in anchors.firstIndex { $0.id == id } }
            let candidates = anchors.indices.filter { index in
                guard let rect = visionRect(from: region.box) else { return false }
                let anchor = anchors[index].boundingBox
                let intersection = anchor.intersection(rect)
                let overlap = intersection.isNull ? 0 : intersection.width * intersection.height / max(anchor.width * anchor.height, rect.width * rect.height)
                return overlap >= 0.65 && !anchors[index].original.isEmpty && similarity(text, anchors[index].original) >= 0.55
            }
            let index = byID ?? (candidates.count == 1 ? candidates.first : nil)
            if let index = byID, !used.contains(anchors[index].id), anchors[index].original.isEmpty {
                // Ink the on-device recognizer located but could not read:
                // the model's reading takes the verified local position.
                used.insert(anchors[index].id)
                let anchor = anchors[index]
                let vertical = anchor.flow == .vertical && VerticalTextLayout.supports(text)
                blocks[index] = RecognizedBlock(id: anchor.id, original: text, translation: text, boundingBox: anchor.boundingBox, confidence: 0.5,
                    sourceLineHeight: anchor.sourceLineHeight, flow: vertical ? .vertical : .horizontal,
                    sourceColumnWidth: vertical ? anchor.sourceColumnWidth : nil, sourceGlyphBoxes: anchor.sourceGlyphBoxes, container: anchor.container)
            } else if let index, !used.contains(anchors[index].id), similarity(text, anchors[index].original) >= 0.65 {
                used.insert(anchors[index].id)
                let anchor = anchors[index]
                blocks[index] = RecognizedBlock(id: anchor.id, original: text, translation: text, boundingBox: anchor.boundingBox, confidence: anchor.confidence, sourceLineHeight: anchor.originalLineHeight, flow: anchor.flow, sourceColumnWidth: anchor.sourceColumnWidth, sourceGlyphBoxes: anchor.sourceGlyphBoxes, container: anchor.container, inkColor: anchor.inkColor)
            } else if let locator, let modelBox = visionRect(from: region.box), let box = locator.verifiedBox(modelBox),
                      !covered(box, by: (blocks + located).filter { $0.placement == .overlay && !$0.original.isEmpty }.map(\.boundingBox)) {
                // Text the local recognizer missed (often handwriting). Overlay
                // it only where local pixels confirm contrasting ink.
                located.append(locatedBlock(text, box: box, aspect: CGFloat(locator.width) / CGFloat(locator.height)))
            } else {
                unmatched.append(RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: .zero, confidence: 0, placement: .textOnly))
            }
        }
        blocks.removeAll { $0.original.isEmpty }
        blocks.append(contentsOf: located)
        blocks.append(contentsOf: unmatched)
        return OCRResult(blocks: blocks, notice: unmatched.isEmpty ? nil : "Some AI text has no verified local position. It is available in Full Text; only Vision-verified regions are overlaid.")
    }

    /// Half of the new box already belongs to positioned regions: the model
    /// re-read known text without its anchor ID. Never paint it twice.
    private static func covered(_ box: CGRect, by existing: [CGRect]) -> Bool {
        let area = box.width * box.height
        guard area > 0 else { return true }
        let overlap = existing.reduce(CGFloat(0)) { total, other in
            let intersection = box.intersection(other)
            return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        return overlap >= area * 0.5
    }

    private static func locatedBlock(_ text: String, box: CGRect, aspect: CGFloat) -> RecognizedBlock {
        let lines = CGFloat(max(1, text.split(separator: "\n", omittingEmptySubsequences: true).count))
        let glyphs = text.filter { !$0.isWhitespace }.count
        // aspect = image width / height; compare the box in pixel proportions.
        let vertical = VerticalTextLayout.supports(text) && glyphs >= 2 && box.height > box.width * aspect * 1.6
        if vertical {
            let column = box.width / lines
            return RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: box, confidence: 0.5,
                sourceLineHeight: column * aspect, flow: .vertical, sourceColumnWidth: column)
        }
        return RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: box, confidence: 0.5, sourceLineHeight: box.height / lines)
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
