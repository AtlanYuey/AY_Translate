import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated enum TranslationPlanner {
    /// Join likely wrapped prose before either translator sees it. Keep columns,
    /// short UI labels, unpositioned text, and widely separated rows independent.
    static func paragraphs(_ blocks: [RecognizedBlock], preference: TranslationPreference) -> [RecognizedBlock] {
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
               lineCount < (preference == .quality ? 8 : 4), canJoin(previous, block) {
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
            }), count < 8 {
                let next = remaining.remove(at: index)
                let text = group.original + "\n" + next.original
                let columnWidth = (group.originalColumnWidth * count + next.originalColumnWidth) / (count + 1)
                group = RecognizedBlock(id: group.id, original: text, translation: text, boundingBox: group.boundingBox.union(next.boundingBox), confidence: min(group.confidence, next.confidence), sourceLineHeight: min(group.originalLineHeight, next.originalLineHeight), flow: .vertical, sourceColumnWidth: columnWidth, sourceGlyphBoxes: (group.sourceGlyphBoxes ?? [group.boundingBox]) + (next.sourceGlyphBoxes ?? [next.boundingBox]))
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
