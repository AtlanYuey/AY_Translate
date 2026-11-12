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
        guard bubble.isDialogue, imageSize.width > 0, imageSize.height > 0 else { return [] }
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

    /// Unread bubble text as empty anchors for a cloud recognizer: the
    /// position is verified locally, the reading is left to the model.
    static func unreadAnchors(bubbles: [SpeechBubble], blocks: [RecognizedBlock], imageSize: CGSize, limit: Int = 40) -> [RecognizedBlock] {
        var result: [RecognizedBlock] = []
        for bubble in bubbles where bubble.isDialogue {
            for column in missingColumns(in: bubble, blocks: blocks, imageSize: imageSize) where result.count < limit {
                let boxes = column.map(\.box)
                guard let first = boxes.first else { continue }
                let widths = boxes.map(\.width).sorted()
                let heights = boxes.map { max($0.width * imageSize.width, $0.height * imageSize.height) / imageSize.height }.sorted()
                result.append(RecognizedBlock(id: UUID(), original: "", translation: "",
                    boundingBox: boxes.dropFirst().reduce(first) { $0.union($1) }, confidence: 0,
                    sourceLineHeight: heights[heights.count * 3 / 4], flow: .vertical,
                    sourceColumnWidth: widths[widths.count * 3 / 4], sourceGlyphBoxes: boxes))
            }
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

    /// Attach each positioned line to the text container that encloses it
    /// (the smallest one wins). Lines close together in one container form a
    /// group that is translated as one utterance; each group receives the
    /// free rectangle around its own text inside the bubble's shape, so a
    /// translation can use nearby space but never leaves the bubble or drifts
    /// away from where the original text was.
    static func assignContainers(_ blocks: [RecognizedBlock], bubbles: [SpeechBubble], imageSize: CGSize) -> [RecognizedBlock] {
        let candidates = bubbles.filter(\.holdsText)
        guard !candidates.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return blocks }
        let W = imageSize.width, H = imageSize.height
        func area(_ r: CGRect) -> CGFloat { max(0, r.width) * max(0, r.height) }
        var members = [[Int]](repeating: [], count: candidates.count)
        for (index, block) in blocks.enumerated() where block.placement == .overlay && block.container == nil {
            let box = block.boundingBox
            let center = CGPoint(x: box.midX, y: box.midY)
            var best: Int?
            for (b, bubble) in candidates.enumerated() where bubble.bounds.contains(center) {
                let inside = bubble.bounds.intersection(box)
                guard !inside.isNull, area(inside) >= area(box) * 0.6 else { continue }
                if best == nil || area(bubble.bounds) < area(candidates[best!].bounds) { best = b }
            }
            if let best { members[best].append(index) }
        }
        var result = blocks
        func pixels(_ r: CGRect) -> CGRect { CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: r.width * W, height: r.height * H) }
        func glyph(_ block: RecognizedBlock) -> CGFloat {
            block.flow == .vertical ? block.originalColumnWidth * W : block.originalLineHeight * H
        }
        for (b, bubble) in candidates.enumerated() where !members[b].isEmpty {
            let lines = members[b]
            // Union-find over lines that sit next to each other.
            var parent = Array(lines.indices)
            func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
            for i in lines.indices { for j in lines.indices where j > i {
                let a = pixels(blocks[lines[i]].boundingBox), c = pixels(blocks[lines[j]].boundingBox)
                let size = max(glyph(blocks[lines[i]]), glyph(blocks[lines[j]]))
                let dx = max(0, max(a.minX - c.maxX, c.minX - a.maxX)), dy = max(0, max(a.minY - c.maxY, c.minY - a.maxY))
                if dx <= size * 1.3 && dy <= size * 1.0 { parent[root(i)] = root(j) }
            } }
            var groups: [Int: [Int]] = [:]
            for i in lines.indices { groups[root(i), default: []].append(lines[i]) }
            let sources = groups.mapValues { group in group.dropFirst().reduce(blocks[group[0]].boundingBox) { $0.union(blocks[$1].boundingBox) } }
            for (key, group) in groups {
                guard let source = sources[key] else { continue }
                let sizes = group.map { glyph(blocks[$0]) }.sorted()
                let size = sizes[sizes.count / 2]
                let others = sources.filter { $0.key != key }.map(\.value)
                let free = bubble.freeArea(around: source, growX: size / W, growY: size / H, avoiding: others)
                for index in group { result[index].container = free }
            }
        }
        return result
    }
}
