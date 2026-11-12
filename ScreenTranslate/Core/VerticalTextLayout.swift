import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated struct VerticalGlyph: Equatable, Sendable {
    let text: String
    let center: CGPoint
}

/// Upright glyphs in top-to-bottom columns, with columns ordered right-to-left.
/// The font follows the original column width, never the tall paragraph height.
nonisolated struct VerticalTextLayout: Sendable {
    let fontSize: CGFloat
    let glyphs: [VerticalGlyph]
    let fits: Bool
    /// Number of columns the glyphs occupy.
    let columnCount: Int

    init(scaling base: VerticalTextLayout, by factor: CGFloat) {
        fontSize = base.fontSize * factor
        glyphs = base.glyphs.map { VerticalGlyph(text: $0.text, center: CGPoint(x: $0.center.x * factor, y: $0.center.y * factor)) }
        fits = base.fits
        columnCount = base.columnCount
    }

    static func supports(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }

    /// Marks that must not begin a column: they belong to the text before.
    private static let closing = Set("。、，．,.！？!?…‥）)」』】〉》”’：；:;・ー～〜—")

    /// Characters per column, right to left. Columns are filled evenly, and a
    /// closing mark that would begin a column stays with the text before it
    /// when that column has room (or takes one character along otherwise).
    static func distribution(_ chars: [Character], columns: Int, maximumRows: Int) -> [Int] {
        let count = chars.count
        guard count > 0 else { return [] }
        let columns = min(count, max(1, columns))
        var sizes = (0..<columns).map { count / columns + ($0 < count % columns ? 1 : 0) }
        var start = 0
        var index = 0
        while index + 1 < sizes.count {
            let boundary = start + sizes[index]
            // Hang closing marks at the foot of the column they follow.
            while sizes[index + 1] > 0, sizes[index] < maximumRows, closing.contains(chars[start + sizes[index]]) {
                sizes[index] += 1; sizes[index + 1] -= 1
            }
            if sizes[index + 1] == 0 { sizes.remove(at: index + 1); continue }
            // No room: carry the last character over, so the mark does not lead.
            if start + sizes[index] == boundary, closing.contains(chars[boundary]), sizes[index] > 1,
               sizes[index + 1] < maximumRows, !closing.contains(chars[boundary - 1]) {
                sizes[index] -= 1; sizes[index + 1] += 1
            }
            start += sizes[index]
            index += 1
        }
        return sizes
    }

    /// Number of columns in a set of glyph or line boxes of vertical text.
    static func columnCount(of boxes: [CGRect], columnWidth: CGFloat) -> Int {
        var centers: [CGFloat] = []
        for box in boxes.sorted(by: { $0.midX > $1.midX }) {
            if let last = centers.last, abs(last - box.midX) < max(columnWidth, box.width) * 0.5 { continue }
            centers.append(box.midX)
        }
        return max(1, centers.count)
    }

    /// `compact` uses as few columns as the height allows (dialogue set in a
    /// bubble's free area); otherwise the source area's column rhythm is kept.
    init(text: String, size: CGSize, preferred: CGFloat, scale: CGFloat, compact: Bool = false) {
        let chars = Array(text.filter { !$0.isWhitespace })
        func capacity(_ font: CGFloat) -> Int {
            max(0, Int((size.width + font * 0.08) / (font * 1.08))) * max(0, Int(size.height / (font * 1.05)))
        }
        var base = max(0.001, preferred)
        while capacity(base) < chars.count && base > preferred * 0.75 { base = max(preferred * 0.75, base * 0.97) }
        let finalSize = base * max(0.1, scale)
        fontSize = finalSize
        let maximumRows = max(1, Int(size.height / (finalSize * 1.05)))
        // Keep the source area's column rhythm, distributing shorter Chinese
        // evenly instead of leaving a tall empty tail or a lone final character.
        let sourceColumns = max(1, Int((size.width + preferred * 0.08) / (preferred * 1.08)))
        let rhythm = compact ? 1 : min(sourceColumns, max(1, Int(ceil(Double(chars.count) / 3))))
        let needed = max(1, Int(ceil(Double(chars.count) / Double(maximumRows))))
        let sizes = Self.distribution(chars, columns: max(needed, rhythm), maximumRows: maximumRows)
        columnCount = max(1, sizes.count)
        fits = capacity(finalSize) >= chars.count && !chars.isEmpty
        let gridWidth = CGFloat(columnCount) * finalSize * 1.08
        let startX = (size.width + gridWidth) / 2 - finalSize * 0.54
        let usedRows = sizes.max() ?? 1
        let startY = max(0, (size.height - CGFloat(usedRows) * finalSize * 1.05) / 2)
        let punctuation: [Character: String] = ["。": "︒", "、": "︑", "，": "︐", "！": "！", "？": "？", "…": "︙", "（": "︵", "）": "︶", "「": "﹁", "」": "﹂", "『": "﹃", "』": "﹄", "ー": "丨", "—": "丨"]
        var placed: [VerticalGlyph] = []
        placed.reserveCapacity(chars.count)
        var next = 0
        for (column, rows) in sizes.enumerated() {
            for row in 0..<rows {
                let character = chars[next]
                next += 1
                let x: CGFloat = startX - CGFloat(column) * finalSize * 1.08
                let y: CGFloat = startY + finalSize * 0.525 + CGFloat(row) * finalSize * 1.05
                placed.append(VerticalGlyph(text: punctuation[character] ?? String(character), center: CGPoint(x: x, y: y)))
            }
        }
        glyphs = placed
    }
}

/// Locate candidate upright vertical columns using locally detected character
/// boxes. Stitching these glyphs into a horizontal strip preserves orientation.
nonisolated enum VerticalOCRGeometry {
    /// A partial native detection must not suppress a complete local column
    /// just because most of the smaller box overlaps it. Keep the longer,
    /// more complete run; separate bubbles at the same x remain independent.
    static func mergingColumns(_ native: [[CGRect]], supplemental: [[CGRect]]) -> [[CGRect]] {
        var result = native
        for candidate in supplemental {
            let box = candidate.reduce(CGRect.null) { $0.union($1) }
            let matches = result.indices.filter { index in
                let other = result[index].reduce(CGRect.null) { $0.union($1) }
                let intersection = other.intersection(box)
                return !intersection.isNull && abs(other.midX - box.midX) < max(other.width, box.width) * 0.6
                    && intersection.width * intersection.height >= min(other.width * other.height, box.width * box.height) * 0.7
            }
            if matches.isEmpty { result.append(candidate); continue }
            let canReplace = matches.allSatisfy { index in
                let other = result[index].reduce(CGRect.null) { $0.union($1) }
                return candidate.count >= result[index].count && box.height >= other.height * 1.05
            }
            if canReplace {
                for index in matches.reversed() { result.remove(at: index) }
                result.append(candidate)
            }
        }
        return result
    }

    static func horizontalConflicts(column: [CGRect], blocks: [RecognizedBlock], imageSize: CGSize) -> (protected: Bool, fragmentedRows: Set<UUID>) {
        var fragments = Set<UUID>()
        for block in blocks where block.flow == .horizontal {
            let touchesGlyph = column.contains { glyph in
                let overlap = glyph.intersection(block.boundingBox)
                return !overlap.isNull && overlap.width * overlap.height / max(0.000001, glyph.width * glyph.height) > 0.7
            }
            guard touchesGlyph else { continue }
            let count = max(1, block.original.filter { !$0.isWhitespace }.count)
            let advance = block.boundingBox.width * imageSize.width / CGFloat(count)
            let height = block.originalLineHeight * imageSize.height
            // CJK horizontal prose has roughly square, closely spaced glyphs.
            // Sparse rows across adjacent vertical columns are not reliable
            // horizontal text, even when Vision returns a horizontal box.
            let rowShaped = block.boundingBox.width * imageSize.width >= height * 1.4
            if count >= 2 && (!VerticalTextLayout.supports(block.original) || (rowShaped && advance <= height * 1.3)) {
                return (true, [])
            }
            fragments.insert(block.id)
        }
        return (false, fragments)
    }

    static func columns(_ boxes: [CGRect], imageSize: CGSize) -> [[CGRect]] {
        let valid = boxes.filter {
            let w = $0.width * imageSize.width, h = $0.height * imageSize.height
            return w >= 4 && h >= 5 && w / h >= 0.35 && w / h <= 1.8 && $0.width < 0.10 && $0.height < 0.10
        }.sorted { $0.midX > $1.midX }
        var columns: [[CGRect]] = []
        for box in valid {
            if let index = columns.indices.first(where: { abs(columns[$0][0].midX - box.midX) < min(columns[$0][0].width, box.width) * 0.55 }) {
                columns[index].append(box)
            } else { columns.append([box]) }
        }
        var result: [[CGRect]] = []
        for column in columns {
            var run: [CGRect] = []
            for box in column.sorted(by: { $0.maxY > $1.maxY }) {
                if let last = run.last, last.minY - box.maxY > max(last.height, box.height) * 1.8 {
                    if run.count >= 2 { result.append(run) }
                    run = []
                }
                run.append(box)
            }
            if run.count >= 2 { result.append(run) }
        }
        return result.filter { boxes in
            let union = boxes.reduce(CGRect.null) { $0.union($1) }
            return union.height * imageSize.height > union.width * imageSize.width * (boxes.count == 2 ? 1.65 : 2.2)
        }
    }
}
