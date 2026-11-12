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
        // null or absent text is a model's way of saying "nothing is written
        // here" for an unread anchor; it must not invalidate the whole reply.
        text = (try? values.decodeIfPresent(String.self, forKey: .text)) ?? ""
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
        let readings = regions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !readings.isEmpty, readings.count <= 500, readings.allSatisfy({ $0.text.count <= 8_000 }) else {
            throw AIServiceError.invalidRegions
        }
        // An ID belongs to the first region that claims it. A model that
        // repeats one (two columns under the same anchor) has still read the
        // page: the later region is placed by its own box instead.
        var claimed = Set<String>()
        let regions = readings.map { region -> AIRecognizedRegion in
            guard let id = region.id, !claimed.insert(id).inserted else { return region }
            return AIRecognizedRegion(id: nil, text: region.text, box: region.box)
        }
        var blocks = anchors
        var used = Set<UUID>()
        var unmatched: [RecognizedBlock] = []
        var located: [RecognizedBlock] = []
        var parts: [Int: [(text: String, box: CGRect)]] = [:]
        func area(_ rect: CGRect) -> CGFloat { max(0, rect.width) * max(0, rect.height) }
        func shared(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let intersection = a.intersection(b)
            return intersection.isNull ? 0 : area(intersection)
        }
        // image width / height, to compare shapes in pixel proportions.
        let aspect = locator.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 1
        for region in regions {
            let text = region.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelBox = visionRect(from: region.box)
            let byID = region.id.flatMap(UUID.init(uuidString:)).flatMap { id in anchors.firstIndex { $0.id == id } }
            let candidates = anchors.indices.filter { index in
                guard let rect = modelBox else { return false }
                let anchor = anchors[index].boundingBox
                let overlap = shared(anchor, rect) / max(area(anchor), area(rect))
                return overlap >= 0.65 && !anchors[index].original.isEmpty && similarity(text, anchors[index].original) >= 0.55
            }
            let index = byID ?? (candidates.count == 1 ? candidates.first : nil)
            // A recognized anchor is corrected when the model's text resembles
            // it, or when the model's own box shows it read that very place:
            // a badly misread line must not keep its misreading.
            let corrects = index.map { index -> Bool in
                let anchor = anchors[index]
                guard !used.contains(anchor.id), !anchor.original.isEmpty else { return false }
                if similarity(text, anchor.original) >= 0.65 { return true }
                guard let modelBox, text.count <= max(8, anchor.original.count * 3) else { return false }
                return shared(anchor.boundingBox, modelBox) >= min(area(anchor.boundingBox), area(modelBox)) * 0.6
            } ?? false
            // Ink the on-device recognizer located but could not read is
            // matched by position: the ID a model picks among several unread
            // anchors is not reliable, its own box is.
            var unread: [Int] = []
            if !corrects {
                if let modelBox {
                    // A second line the model read inside an unread area that
                    // already received text continues that text.
                    if let index = anchors.indices.first(where: { parts[$0] != nil && shared(anchors[$0].boundingBox, modelBox) >= area(modelBox) * 0.6 }) {
                        parts[index]?.append((text, modelBox))
                        continue
                    }
                    unread = anchors.indices.filter { index in
                        let anchor = anchors[index]
                        guard anchor.original.isEmpty, !used.contains(anchor.id) else { return false }
                        let common = shared(anchor.boundingBox, modelBox)
                        return common >= area(anchor.boundingBox) * 0.5 || common >= area(modelBox) * 0.6
                    }
                    if let first = unread.first {
                        let union = unread.dropFirst().reduce(anchors[first].boundingBox) { $0.union(anchors[$1].boundingBox) }
                        // The anchors must account for what the model read, in
                        // the same writing direction; otherwise its verified
                        // box describes the text better than they do.
                        let upright = modelBox.height > modelBox.width * aspect * 1.2
                        let flat = modelBox.width * aspect > modelBox.height * 1.2
                        let agrees = anchors[first].flow == .vertical ? !flat : !upright
                        if area(union) < area(modelBox) * 0.35 || !agrees { unread = [] }
                    }
                } else if let index = byID, anchors[index].original.isEmpty, !used.contains(anchors[index].id) {
                    unread = [index]
                }
            }
            if corrects, let index {
                used.insert(anchors[index].id)
                let anchor = anchors[index]
                blocks[index] = RecognizedBlock(id: anchor.id, original: text, translation: text, boundingBox: anchor.boundingBox, confidence: anchor.confidence, sourceLineHeight: anchor.originalLineHeight, flow: anchor.flow, sourceColumnWidth: anchor.sourceColumnWidth, sourceGlyphBoxes: anchor.sourceGlyphBoxes, container: anchor.container, inkColor: anchor.inkColor)
            } else if let first = unread.first {
                // The model's reading takes the verified local position.
                for index in unread { used.insert(anchors[index].id) }
                let anchor = anchors[first]
                let members = unread.map { anchors[$0] }
                let box = members.dropFirst().reduce(anchor.boundingBox) { $0.union($1.boundingBox) }
                let vertical = anchor.flow == .vertical && VerticalTextLayout.supports(text)
                let widths = members.compactMap(\.sourceColumnWidth).sorted()
                parts[first] = [(text, modelBox ?? box)]
                blocks[first] = RecognizedBlock(id: anchor.id, original: text, translation: text, boundingBox: box, confidence: 0.5,
                    sourceLineHeight: anchor.sourceLineHeight, flow: vertical ? .vertical : .horizontal,
                    sourceColumnWidth: vertical && !widths.isEmpty ? widths[widths.count / 2] : nil,
                    sourceGlyphBoxes: members.flatMap { $0.sourceGlyphBoxes ?? [$0.boundingBox] }, container: anchor.container)
            } else if let locator, let modelBox, let box = locator.verifiedBox(modelBox),
                      !covered(box, by: (blocks + located).filter { $0.placement == .overlay && !$0.original.isEmpty }.map(\.boundingBox)) {
                // Text the local recognizer missed (often handwriting). Overlay
                // it only where local pixels confirm contrasting ink.
                located.append(locatedBlock(text, box: box, aspect: aspect))
            } else {
                unmatched.append(RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: .zero, confidence: 0, placement: .textOnly))
            }
        }
        // Several lines read inside one unread area: join them in reading
        // order (columns right to left, rows top to bottom).
        for (index, lines) in parts where lines.count > 1 {
            let block = blocks[index]
            let ordered = lines.sorted { block.flow == .vertical ? $0.box.midX > $1.box.midX : $0.box.midY > $1.box.midY }
            let text = ordered.map(\.text).joined(separator: block.flow == .vertical ? "" : " ")
            blocks[index] = RecognizedBlock(id: block.id, original: text, translation: text, boundingBox: block.boundingBox, confidence: block.confidence,
                sourceLineHeight: block.sourceLineHeight, flow: block.flow, sourceColumnWidth: block.sourceColumnWidth,
                sourceGlyphBoxes: block.sourceGlyphBoxes, container: block.container)
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
