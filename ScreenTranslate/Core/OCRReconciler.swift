import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Reconcile observations, not just their paragraph rectangles. A tile edge
/// can contain only the beginning/end of a line; nearby ruby is a separate run.
nonisolated enum OCRReconciler {
    static func merge(_ candidates: [RecognizedBlock]) -> [RecognizedBlock] {
        var result: [RecognizedBlock] = []
        for candidate in candidates.sorted(by: preferred) {
            if let index = result.firstIndex(where: { sameRun($0, candidate) || duplicateTranscript($0, candidate) }) {
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

    /// Furigana is retained for full-text inspection, but must not receive its
    /// own translated overlay on top of the larger kanji column it annotates.
    static func separatingRuby(_ blocks: [RecognizedBlock]) -> [RecognizedBlock] {
        blocks.map { candidate in
            let letters = candidate.original.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard candidate.placement == .overlay, !letters.isEmpty,
                  letters.allSatisfy({ (0x3040...0x30FF).contains($0.value) }) else { return candidate }
            let box = candidate.boundingBox
            let parent = blocks.contains { body in
                guard body.id != candidate.id, body.flow == .vertical, body.placement == .overlay,
                      body.original.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else { return false }
                let parent = body.boundingBox
                return box.width < body.originalColumnWidth * 0.6 && box.height < parent.height * 0.65
                    && box.midX > parent.midX && box.minX < parent.maxX + body.originalColumnWidth * 0.55
                    && box.maxY <= parent.maxY + body.originalLineHeight * 0.5
                    && box.minY >= parent.minY - body.originalLineHeight * 0.5
            }
            var result = candidate
            if parent { result.placement = .textOnly }
            return result
        }
    }

    private static func duplicateTranscript(_ a: RecognizedBlock, _ b: RecognizedBlock) -> Bool {
        guard a.flow == b.flow, a.placement == .overlay, b.placement == .overlay,
              normalized(a.original) == normalized(b.original) else { return false }
        // A detector can include ruby in the line's width while another one
        // tightly bounds only the kanji; text + containment still proves a copy.
        return intersection(a.boundingBox, b.boundingBox) >= min(area(a.boundingBox), area(b.boundingBox)) * 0.85
    }

    /// A second recognizer contributes uncovered text, without replacing a
    /// complete document observation with cross-column horizontal fragments.
    static func supplement(_ primary: [RecognizedBlock], with additions: [RecognizedBlock]) -> [RecognizedBlock] {
        let regions: [(bounds: CGRect, glyphs: [CGRect])] = primary.map { existing in
            let glyphs = existing.sourceGlyphBoxes?.isEmpty == false ? existing.sourceGlyphBoxes! : [existing.boundingBox]
            return (glyphs.reduce(existing.boundingBox) { $0.union($1) }, glyphs)
        }
        let verified = additions.filter { candidate in
            let glyphs = candidate.sourceGlyphBoxes?.isEmpty == false ? candidate.sourceGlyphBoxes! : [candidate.boundingBox]
            let covered = glyphs.filter { glyph in
                regions.contains { existing in
                    guard existing.bounds.intersects(glyph) else { return false }
                    return existing.glyphs.contains { intersection(glyph, $0) >= area(glyph) * 0.65 }
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
        if a.original == b.original, area(a.boundingBox) != area(b.boundingBox) {
            return area(a.boundingBox) < area(b.boundingBox)
        }
        if a.original != b.original { return a.original < b.original }
        if a.boundingBox.maxY != b.boundingBox.maxY { return a.boundingBox.maxY > b.boundingBox.maxY }
        if a.boundingBox.minX != b.boundingBox.minX { return a.boundingBox.minX < b.boundingBox.minX }
        if a.boundingBox.width != b.boundingBox.width { return a.boundingBox.width < b.boundingBox.width }
        return a.boundingBox.height < b.boundingBox.height
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
            var tail = trailing.original.startIndex, consumed = 0
            while tail < trailing.original.endIndex && consumed < count {
                if !trailing.original[tail].isWhitespace { consumed += 1 }
                tail = trailing.original.index(after: tail)
            }
            let text = leading.original + trailing.original[tail...]
            let union = a.boundingBox.union(b.boundingBox)
            let length = a.flow == .vertical ? union.height : union.width
            let sourceLength = a.flow == .vertical ? leading.boundingBox.height : leading.boundingBox.width
            // Text overlap must agree with spatial overlap; repeated words in
            // neighboring bubbles are not a license to concatenate them.
            let expected = sourceLength * CGFloat(normalized(text).count) / CGFloat(x.count)
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
