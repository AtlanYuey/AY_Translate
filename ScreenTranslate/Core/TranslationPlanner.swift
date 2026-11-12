import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated enum TranslationPlanner {
    /// Join likely wrapped prose before either translator sees it. Keep columns,
    /// short UI labels, unpositioned text, and widely separated rows independent.
    static func paragraphs(_ blocks: [RecognizedBlock]) -> [RecognizedBlock] {
        // Everything inside one dialogue bubble is one utterance: translate it
        // together and lay it out once. Other text keeps the line heuristics.
        let bubbles = bubbleParagraphs(blocks.filter { $0.placement == .overlay && $0.container != nil })
        let blocks = blocks.filter { $0.placement != .overlay || $0.container == nil }
        return bubbles + lineParagraphs(blocks)
    }

    /// Merge the lines of each bubble in reading order and drop a second
    /// reading of the same ink, so a bubble never receives two overlays.
    static func bubbleParagraphs(_ blocks: [RecognizedBlock]) -> [RecognizedBlock] {
        var groups: [(container: CGRect, members: [RecognizedBlock])] = []
        for block in blocks {
            guard let container = block.container else { continue }
            if let index = groups.firstIndex(where: { $0.container == container }) { groups[index].members.append(block) }
            else { groups.append((container, [block])) }
        }
        func area(_ r: CGRect) -> CGFloat { max(0, r.width) * max(0, r.height) }
        let merged = groups.map { group -> RecognizedBlock in
            var kept: [RecognizedBlock] = []
            for member in group.members.sorted(by: { $0.original.count != $1.original.count ? $0.original.count > $1.original.count : $0.confidence > $1.confidence }) {
                var covered: CGFloat = 0
                var duplicate = false
                for other in kept {
                    let overlap = other.boundingBox.intersection(member.boundingBox)
                    guard !overlap.isNull else { continue }
                    covered += area(overlap)
                    if area(overlap) >= min(area(other.boundingBox), area(member.boundingBox)) * 0.6 { duplicate = true }
                }
                // A short reading that lies across longer lines already kept
                // (a "column" cut through two stacked rows of a title) is the
                // same ink read a second time, in the wrong direction.
                if covered >= area(member.boundingBox) * 0.6 { duplicate = true }
                if !duplicate { kept.append(member) }
            }
            // The writing direction most of the text was read in; one stray
            // vertical fragment must not turn a horizontal title on its side.
            let total = kept.reduce(0) { $0 + $1.original.count }
            let upright = kept.filter { $0.flow == .vertical }.reduce(0) { $0 + $1.original.count }
            let vertical = upright * 2 > total
            let ordered = kept.sorted { a, b in
                if vertical {
                    if abs(a.boundingBox.midX - b.boundingBox.midX) > min(a.originalColumnWidth, b.originalColumnWidth) * 0.5 { return a.boundingBox.midX > b.boundingBox.midX }
                    return a.boundingBox.maxY > b.boundingBox.maxY
                }
                if abs(a.boundingBox.midY - b.boundingBox.midY) > min(a.originalLineHeight, b.originalLineHeight) * 0.5 { return a.boundingBox.midY > b.boundingBox.midY }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            guard ordered.count > 1 else { return ordered[0] }
            var text = ordered[0].original
            for next in ordered.dropFirst() {
                // Japanese/Chinese lines continue without a separator.
                let cjk = text.unicodeScalars.last.map(isCJK) == true || next.original.unicodeScalars.first.map(isCJK) == true
                text += (cjk ? "" : " ") + next.original
            }
            func median(_ values: [CGFloat]) -> CGFloat { let sorted = values.sorted(); return sorted[sorted.count / 2] }
            return RecognizedBlock(id: ordered[0].id, original: text, translation: text,
                boundingBox: ordered.dropFirst().reduce(ordered[0].boundingBox) { $0.union($1.boundingBox) },
                confidence: ordered.map(\.confidence).min() ?? 0,
                sourceLineHeight: median(ordered.map(\.originalLineHeight)),
                flow: vertical ? .vertical : .horizontal,
                sourceColumnWidth: vertical ? median(ordered.filter { $0.flow == .vertical }.map(\.originalColumnWidth)) : nil,
                sourceGlyphBoxes: ordered.flatMap { $0.sourceGlyphBoxes ?? [$0.boundingBox] },
                container: group.container, inkColor: ordered.compactMap(\.inkColor).first)
        }
        // Reading order: top band first; vertical (manga) bubbles right to left.
        return merged.sorted { a, b in
            if abs(a.boundingBox.maxY - b.boundingBox.maxY) > 0.06 { return a.boundingBox.maxY > b.boundingBox.maxY }
            return a.flow == .vertical ? a.boundingBox.midX > b.boundingBox.midX : a.boundingBox.midX < b.boundingBox.midX
        }
    }

    private static func lineParagraphs(_ blocks: [RecognizedBlock]) -> [RecognizedBlock] {
        let positioned = blocks.filter { $0.placement == .overlay && $0.flow == .horizontal }.sorted {
            if $0.boundingBox.midY == $1.boundingBox.midY {
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            return $0.boundingBox.midY > $1.boundingBox.midY
        }
        var result: [RecognizedBlock] = []
        var lastLine: RecognizedBlock?
        var lineCount = 0
        for block in positioned {
            if let previous = lastLine, let group = result.last,
               lineCount < 8, canJoin(previous, block) {
                let joinsWithoutSpace = previous.original.hasSuffix("-") || (previous.original.unicodeScalars.last.map(isCJK) == true && block.original.unicodeScalars.first.map(isCJK) == true)
                let joiner = joinsWithoutSpace ? "" : " "
                let prefix = previous.original.hasSuffix("-") ? String(group.original.dropLast()) : group.original
                let text = prefix + joiner + block.original
                let lineHeight = (group.originalLineHeight * CGFloat(lineCount) + block.originalLineHeight) / CGFloat(lineCount + 1)
                result[result.count - 1] = RecognizedBlock(id: group.id, original: text, translation: text, boundingBox: group.boundingBox.union(block.boundingBox), confidence: min(group.confidence, block.confidence), sourceLineHeight: lineHeight, sourceGlyphBoxes: (group.sourceGlyphBoxes ?? [group.boundingBox]) + (block.sourceGlyphBoxes ?? [block.boundingBox]))
                lineCount += 1
            } else {
                result.append(block)
                lineCount = 1
            }
            lastLine = block
        }
        return result + verticalParagraphs(blocks.filter { $0.placement == .overlay && $0.flow == .vertical }) + blocks.filter { $0.placement == .textOnly }
    }

    private static func verticalParagraphs(_ blocks: [RecognizedBlock]) -> [RecognizedBlock] {
        var remaining = blocks.sorted { $0.boundingBox.maxX > $1.boundingBox.maxX }
        var result: [RecognizedBlock] = []
        while !remaining.isEmpty {
            var group = remaining.removeFirst()
            var previous = group
            var count: CGFloat = 1
            // Adjacent columns within one bubble, never a jump across panels.
            while let index = remaining.firstIndex(where: { candidate in
                let a = previous.boundingBox, b = candidate.boundingBox
                let overlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
                let width = max(previous.originalColumnWidth, candidate.originalColumnWidth)
                let gap = a.minX - b.maxX
                return gap >= -width * 0.2 && gap <= width * 1.1
                    && overlap / max(0.0001, min(a.height, b.height)) >= 0.65
                    && min(previous.originalColumnWidth, candidate.originalColumnWidth) / max(0.0001, width) >= 0.6
                    && !"。！？!?".contains(previous.original.last ?? " ")
                    // Hand-lettered pages colour each speaker differently.
                    && !BackgroundSampling.inksDiffer(previous.inkColor, candidate.inkColor)
            }), count < 8 {
                let next = remaining.remove(at: index)
                let text = group.original + "\n" + next.original
                let columnWidth = (group.originalColumnWidth * count + next.originalColumnWidth) / (count + 1)
                group = RecognizedBlock(id: group.id, original: text, translation: text, boundingBox: group.boundingBox.union(next.boundingBox), confidence: min(group.confidence, next.confidence), sourceLineHeight: min(group.originalLineHeight, next.originalLineHeight), flow: .vertical, sourceColumnWidth: columnWidth, sourceGlyphBoxes: (group.sourceGlyphBoxes ?? [group.boundingBox]) + (next.sourceGlyphBoxes ?? [next.boundingBox]), inkColor: group.inkColor ?? next.inkColor)
                previous = next; count += 1
            }
            result.append(group)
        }
        return result
    }

    private static func canJoin(_ a: RecognizedBlock, _ b: RecognizedBlock) -> Bool {
        let aa = a.boundingBox, bb = b.boundingBox
        let lineHeight = max(aa.height, bb.height)
        let gap = aa.minY - bb.maxY
        let overlap = max(0, min(aa.maxX, bb.maxX) - max(aa.minX, bb.minX))
        return proseLength(a.original) >= 14 && proseLength(b.original) >= 8
            && !".!?。？！:：".contains(a.original.last ?? " ")
            && aa.width >= 0.25 && bb.width >= 0.15
            && gap >= -lineHeight * 0.15 && gap <= lineHeight * 0.65
            && abs(aa.minX - bb.minX) <= lineHeight * 0.8
            && overlap / max(0.001, min(aa.width, bb.width)) >= 0.8
            && min(aa.height, bb.height) / max(0.001, lineHeight) >= 0.65
    }

    private static func proseLength(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (isCJK($1) ? 2 : 1) }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        // Chinese/Japanese wraps omit a separator. Korean words still need spaces.
        (0x2E80...0x9FFF).contains(scalar.value)
    }
}

nonisolated enum ImageViewport {
    static func fittedSize(image: CGSize, container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let factor = min(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * factor, height: image.height * factor)
    }

    static func scale(_ current: CGFloat, magnification: CGFloat) -> CGFloat {
        guard current.isFinite, magnification.isFinite else { return 1 }
        return min(6, max(1, current * magnification))
    }

    static func boundedOffset(_ proposed: CGSize, image: CGSize, container: CGSize, scale: CGFloat) -> CGSize {
        let horizontal = max(0, (image.width * scale - container.width) / 2)
        let vertical = max(0, (image.height * scale - container.height) / 2)
        return CGSize(width: min(horizontal, max(-horizontal, proposed.width)), height: min(vertical, max(-vertical, proposed.height)))
    }
}
