import Foundation

/// Reconcile observations, not just their paragraph rectangles. A tile edge
/// can contain only the beginning/end of a line; nearby ruby is a separate run.
nonisolated enum OCRReconciler {
    static func merge(_ candidates: [RecognizedBlock]) -> [RecognizedBlock] {
        var result: [RecognizedBlock] = []
        for candidate in candidates.sorted(by: preferred) {
            if let index = result.firstIndex(where: { sameRun($0, candidate) }) {
                let old = result[index]
                if let joined = stitch(old, candidate) { result[index] = joined }
                else if intersection(old.boundingBox, candidate.boundingBox) < min(area(old.boundingBox), area(candidate.boundingBox)) * 0.7 {
                    result.append(candidate)
                }
                // Otherwise the stronger, deterministically sorted observation
                // is already retained. Never stack two readings of the same ink.
            } else { result.append(candidate) }
        }
        return result.sorted {
            if $0.boundingBox.maxY != $1.boundingBox.maxY { return $0.boundingBox.maxY > $1.boundingBox.maxY }
            if $0.boundingBox.minX != $1.boundingBox.minX { return $0.boundingBox.minX < $1.boundingBox.minX }
            return $0.original < $1.original
        }
    }

    /// A second recognizer contributes uncovered text, without replacing a
    /// complete document observation with cross-column horizontal fragments.
    static func supplement(_ primary: [RecognizedBlock], with additions: [RecognizedBlock]) -> [RecognizedBlock] {
        let verified = additions.filter { candidate in
            let glyphs = candidate.sourceGlyphBoxes?.isEmpty == false ? candidate.sourceGlyphBoxes! : [candidate.boundingBox]
            let covered = glyphs.filter { glyph in
                primary.contains { existing in
                    let evidence = existing.sourceGlyphBoxes?.isEmpty == false ? existing.sourceGlyphBoxes! : [existing.boundingBox]
                    return evidence.contains { intersection(glyph, $0) >= area(glyph) * 0.65 }
                }
            }.count
            // A genuinely longer line may correct a truncated native line.
            if primary.contains(where: { sameRun($0, candidate) && normalized(candidate.original).contains(normalized($0.original))
                && candidate.original.count > $0.original.count }) { return true }
            return covered * 2 < glyphs.count && candidate.confidence >= 0.3
        }
        return merge(primary + verified)
    }

    private static func normalized(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    private static func area(_ box: CGRect) -> CGFloat { max(0, box.width) * max(0, box.height) }
    private static func intersection(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let box = a.intersection(b)
        return box.isNull ? 0 : area(box)
    }

    private static func sameRun(_ a: RecognizedBlock, _ b: RecognizedBlock) -> Bool {
        guard a.placement == .overlay, b.placement == .overlay, a.flow == b.flow else { return false }
        let x = a.boundingBox, y = b.boundingBox
        let small = a.flow == .vertical ? min(x.width, y.width) : min(x.height, y.height)
        let large = a.flow == .vertical ? max(x.width, y.width) : max(x.height, y.height)
        let distance = a.flow == .vertical ? abs(x.midX - y.midX) : abs(x.midY - y.midY)
        guard small >= large * 0.6, distance < small * 0.45 else { return false }
        return intersection(x, y) >= min(area(x), area(y)) * 0.3
    }

    private static func preferred(_ a: RecognizedBlock, _ b: RecognizedBlock) -> Bool {
        // Completeness wins only between plausible observations; a long noisy
        // low-confidence string must not displace clear, short body text.
        let reliableA = a.confidence >= 0.3, reliableB = b.confidence >= 0.3
        if reliableA != reliableB { return reliableA }
        if a.original.count != b.original.count { return a.original.count > b.original.count }
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        let countA = a.sourceGlyphBoxes?.count ?? 0, countB = b.sourceGlyphBoxes?.count ?? 0
        if countA != countB { return countA > countB }
        if a.original != b.original { return a.original < b.original }
        if a.boundingBox.maxY != b.boundingBox.maxY { return a.boundingBox.maxY > b.boundingBox.maxY }
        return a.boundingBox.minX < b.boundingBox.minX
    }

    private static func stitch(_ a: RecognizedBlock, _ b: RecognizedBlock) -> RecognizedBlock? {
        let first = a.flow == .vertical ? a.boundingBox.maxY >= b.boundingBox.maxY : a.boundingBox.minX <= b.boundingBox.minX
        let leading = first ? a : b, trailing = first ? b : a
        let x = Array(normalized(leading.original)), y = Array(normalized(trailing.original))
        guard x.count >= 3, y.count >= 3, !String(x).contains(String(y)), !String(y).contains(String(x)) else { return nil }
        let extends = a.flow == .vertical ? trailing.boundingBox.minY < leading.boundingBox.minY : trailing.boundingBox.maxX > leading.boundingBox.maxX
        guard extends else { return nil }
        for count in stride(from: min(x.count, y.count) - 1, through: 2, by: -1) {
            guard Array(x.suffix(count)) == Array(y.prefix(count)) else { continue }
            let text = String(x) + String(y.dropFirst(count))
            let union = a.boundingBox.union(b.boundingBox)
            let length = a.flow == .vertical ? union.height : union.width
            let sourceLength = a.flow == .vertical ? leading.boundingBox.height : leading.boundingBox.width
            // Text overlap must agree with spatial overlap; repeated words in
            // neighboring bubbles are not a license to concatenate them.
            let expected = sourceLength * CGFloat(text.count) / CGFloat(x.count)
            guard length >= expected * 0.75, length <= expected * 1.25 else { continue }
            let glyphs = (leading.sourceGlyphBoxes ?? []) + (trailing.sourceGlyphBoxes ?? []).filter { glyph in
                !(leading.sourceGlyphBoxes ?? []).contains { intersection(glyph, $0) > area(glyph) * 0.65 }
            }
            return RecognizedBlock(id: a.id, original: text, translation: text, boundingBox: union,
                confidence: min(a.confidence, b.confidence), sourceLineHeight: a.sourceLineHeight, flow: a.flow,
                sourceColumnWidth: a.sourceColumnWidth, sourceGlyphBoxes: glyphs.isEmpty ? nil : glyphs)
        }
        return nil
    }
}
