import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One character cell of a vertical line, in Vision-normalized coordinates.
/// `rotate` marks marks that turn with the writing direction (long vowel ー,
/// wave dash, vertical ellipsis): an upright copy reads as another character.
nonisolated struct GlyphCell: Sendable, Equatable {
    var box: CGRect
    var rotate: Bool
}

nonisolated enum BubbleText {
    /// Text inside a dialogue bubble that no recognized line covers, split
    /// into vertical columns (right to left) of character cells (top to
    /// bottom). Furigana beside full-size characters and punctuation-only
    /// columns are omitted: they need no translation of their own.
    static func missingColumns(in bubble: SpeechBubble, blocks: [RecognizedBlock], imageSize: CGSize) -> [[GlyphCell]] {
        guard bubble.holdsText, imageSize.width > 0, imageSize.height > 0 else { return [] }
        let W = imageSize.width, H = imageSize.height
        // Work in top-left pixel space so sizes compare in both directions.
        func pixels(_ r: CGRect) -> CGRect { CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: r.width * W, height: r.height * H) }
        func vision(_ r: CGRect) -> CGRect { CGRect(x: r.minX / W, y: 1 - r.maxY / H, width: r.width / W, height: r.height / H) }
        let ink = bubble.ink.map(pixels).filter { max($0.width, $0.height) >= 2 }
        guard !ink.isEmpty else { return [] }
        let sizes = ink.map { max($0.width, $0.height) }.sorted()
        let main = sizes[min(sizes.count - 1, sizes.count * 3 / 4)]
        guard main >= 6 else { return [] }
        let covered = blocks.filter { $0.placement == .overlay }.map { pixels($0.boundingBox) }
        func isCovered(_ r: CGRect) -> Bool {
            covered.contains { line in
                let i = r.intersection(line.insetBy(dx: -main * 0.15, dy: -main * 0.15))
                return !i.isNull && i.width * i.height >= r.width * r.height * 0.5
            }
        }
        let uncovered = ink.filter { !isCovered($0) }
        guard !uncovered.isEmpty else { return [] }

        // Cluster into columns, right to left.
        var columns: [[CGRect]] = []
        for part in uncovered.sorted(by: { $0.midX > $1.midX }) {
            if let index = columns.firstIndex(where: { column in
                let span = column.reduce(CGRect.null) { $0.union($1) }
                let overlap = min(span.maxX, part.maxX) - max(span.minX, part.minX)
                return overlap >= min(span.width, part.width) * 0.3 || abs(span.midX - part.midX) < main * 0.35
            }) { columns[index].append(part) } else { columns.append([part]) }
        }
        // Full-size characters anywhere in the bubble (recognized or not).
        let bodies = ink.filter { max($0.width, $0.height) >= main * 0.75 }

        var result: [[GlyphCell]] = []
        for column in columns {
            let parts = column.sorted { $0.minY < $1.minY }
            let span = parts.reduce(CGRect.null) { $0.union($1) }
            // Furigana: a column of small kana just right of full-size text.
            let small = parts.allSatisfy { max($0.width, $0.height) < main * 0.62 }
            if small, bodies.contains(where: { body in
                body.maxX <= span.minX + main * 0.15 && span.minX - body.maxX < main * 0.6
                    && min(body.maxY, span.maxY) > max(body.minY, span.minY)
            }) { continue }
            let cells = cells(from: parts, main: main)
            // Only punctuation (dots, bars, "!"): nothing to translate.
            guard cells.contains(where: { !$0.rotate && max($0.box.width, $0.box.height) >= main * 0.45 && !isExclamation($0.box, parts: parts, main: main) }) else { continue }
            result.append(cells.map { GlyphCell(box: vision($0.box), rotate: $0.rotate) })
        }
        return result
    }

    private static func isTallThin(_ r: CGRect, main: CGFloat) -> Bool { r.height >= r.width * 2.5 && r.height >= main * 0.4 }
    private static func isDot(_ r: CGRect, main: CGFloat) -> Bool { max(r.width, r.height) < main * 0.3 && r.height < r.width * 2 && r.width < r.height * 2 }
    private static func isExclamation(_ cell: CGRect, parts: [CGRect], main: CGFloat) -> Bool {
        let inside = parts.filter { cell.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        return inside.count == 2 && inside.contains { isTallThin($0, main: main) } && inside.contains { isDot($0, main: main) }
    }

    /// Group the components of one column into character cells (pixel space).
    static func cells(from parts: [CGRect], main: CGFloat) -> [(box: CGRect, rotate: Bool)] {
        var cells: [(box: CGRect, rotate: Bool)] = []
        var index = 0
        while index < parts.count {
            let part = parts[index]
            // "!" is a bar with a dot just below it; keep it upright.
            if isTallThin(part, main: main), index + 1 < parts.count, isDot(parts[index + 1], main: main),
               parts[index + 1].minY - part.maxY < main * 0.35 {
                cells.append((part.union(parts[index + 1]), false)); index += 2; continue
            }
            // A lone bar or wave in vertical text: ー or 〜, written rotated.
            if isTallThin(part, main: main) { cells.append((part, true)); index += 1; continue }
            // Two or more stacked dots: a vertical ellipsis.
            if isDot(part, main: main) {
                var run = part, end = index + 1
                while end < parts.count, isDot(parts[end], main: main), parts[end].minY - run.maxY < main * 0.6 { run = run.union(parts[end]); end += 1 }
                if end - index >= 2 { cells.append((run, true)); index = end; continue }
            }
            // Strokes of one character overlap vertically or nearly touch;
            // a merged cell never grows beyond a character's height.
            if let last = cells.last, !last.rotate,
               part.minY - last.box.maxY < main * 0.12,
               last.box.union(part).height <= main * 1.15,
               !isExclamationLike(last.box, main: main) {
                cells[cells.count - 1].box = last.box.union(part)
            } else {
                cells.append((part, false))
            }
            index += 1
        }
        return cells
    }

    private static func isExclamationLike(_ r: CGRect, main: CGFloat) -> Bool { r.height >= r.width * 2.5 }

    /// Attach each positioned line to the dialogue bubble that encloses it.
    /// The smallest enclosing bubble wins (captions inside larger areas).
    static func assignContainers(_ blocks: [RecognizedBlock], bubbles: [SpeechBubble]) -> [RecognizedBlock] {
        let candidates = bubbles.filter(\.holdsText)
        guard !candidates.isEmpty else { return blocks }
        return blocks.map { block in
            guard block.placement == .overlay, block.container == nil else { return block }
            let box = block.boundingBox
            let center = CGPoint(x: box.midX, y: box.midY)
            let enclosing = candidates.filter { bubble in
                guard bubble.bounds.contains(center) else { return false }
                let inside = bubble.bounds.intersection(box)
                return !inside.isNull && inside.width * inside.height >= box.width * box.height * 0.6
            }
            guard let bubble = enclosing.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return block }
            var result = block
            result.container = bubble.textArea
            return result
        }
    }
}
