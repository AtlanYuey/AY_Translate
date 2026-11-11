import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A light region enclosed by line art: a speech bubble, caption box or any
/// other enclosed panel area that holds dark ink. Detection reads no text;
/// recognition and grouping decide whether the ink is actually text.
nonisolated struct SpeechBubble: Sendable, Equatable {
    /// Vision-normalized bounds of the light interior (origin bottom left).
    let bounds: CGRect
    /// The area a translation may use: the interior's inscribed core joined
    /// with the original text ink, never larger than the interior.
    let textArea: CGRect
    /// Enclosed dark components (candidate glyph ink), Vision-normalized.
    let ink: [CGRect]
    /// Share of the bounding box covered by the interior (ellipse ≈ 0.785).
    let fill: Double
    /// Every enclosed component is glyph-sized and the ink spreads across the
    /// interior: a dialogue bubble or caption, not a face, shirt or a panel
    /// background that merely surrounds other bubbles.
    let holdsText: Bool
}

nonisolated enum BubbleDetector {
    /// `grayscale` rows use a top-left origin.
    static func bubbles(grayscale: [UInt8], width: Int, height: Int) -> [SpeechBubble] {
        let count = width * height
        guard width >= 32, height >= 32, grayscale.count == count, count <= 4_000_000 else { return [] }
        // Paper is light; screentone, art and text are not. JPEG ringing
        // keeps true bubble paper above ~205.
        let lightLevel: UInt8 = 205
        var labels = [Int32](repeating: -1, count: count)
        struct Region { var area = 0; var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1; var border = false }
        var regions: [Region] = []
        var queue = [Int](); queue.reserveCapacity(4096)
        for start in 0..<count where labels[start] < 0 && grayscale[start] >= lightLevel {
            let id = Int32(regions.count)
            var region = Region()
            labels[start] = id
            queue.removeAll(keepingCapacity: true); queue.append(start)
            var head = 0
            while head < queue.count {
                let index = queue[head]; head += 1
                let x = index % width, y = index / width
                region.area += 1
                region.minX = min(region.minX, x); region.maxX = max(region.maxX, x)
                region.minY = min(region.minY, y); region.maxY = max(region.maxY, y)
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 { region.border = true }
                for next in [x > 0 ? index - 1 : -1, x < width - 1 ? index + 1 : -1, y > 0 ? index - width : -1, y < height - 1 ? index + width : -1]
                    where next >= 0 && labels[next] < 0 && grayscale[next] >= lightLevel {
                    labels[next] = id; queue.append(next)
                }
                // Large page backgrounds: keep only the unprocessed frontier.
                if head >= 8192 && head * 2 >= queue.count { queue.removeFirst(head); head = 0 }
            }
            regions.append(region)
        }
        let minimumArea = max(150, count / 1500), maximumArea = count / 6
        var result: [SpeechBubble] = []
        for (index, region) in regions.enumerated() {
            guard !region.border, region.area >= minimumArea, region.area <= maximumArea else { continue }
            let bw = region.maxX - region.minX + 1, bh = region.maxY - region.minY + 1
            guard bw >= 14, bh >= 14, max(bw, bh) <= min(width, height) * 9 / 10 || max(bw, bh) <= max(width, height) / 2 else { continue }
            let fill = Double(region.area) / Double(bw * bh)
            guard fill >= 0.42, Double(max(bw, bh)) / Double(min(bw, bh)) <= 6 else { continue }
            let id = Int32(index)
            // Row and column extents of the interior decide what it encloses.
            var rowMin = [Int](repeating: Int.max, count: bh), rowMax = [Int](repeating: -1, count: bh)
            var colMin = [Int](repeating: Int.max, count: bw), colMax = [Int](repeating: -1, count: bw)
            for y in region.minY...region.maxY { for x in region.minX...region.maxX where labels[y * width + x] == id {
                let ry = y - region.minY, rx = x - region.minX
                rowMin[ry] = min(rowMin[ry], x); rowMax[ry] = max(rowMax[ry], x)
                colMin[rx] = min(colMin[rx], y); colMax[rx] = max(colMax[rx], y)
            } }
            func enclosed(_ x: Int, _ y: Int) -> Bool {
                let ry = y - region.minY, rx = x - region.minX
                return x > rowMin[ry] && x < rowMax[ry] && y > colMin[rx] && y < colMax[rx]
            }
            // Enclosed non-paper components are the bubble's content.
            var seen = [Bool](repeating: false, count: bw * bh)
            var ink: [CGRect] = []
            var inkArea = 0
            for y in region.minY...region.maxY { for x in region.minX...region.maxX {
                let local = (y - region.minY) * bw + (x - region.minX)
                guard !seen[local], labels[y * width + x] != id, grayscale[y * width + x] < lightLevel, enclosed(x, y) else { continue }
                var stack = [(x, y)]; seen[local] = true
                var minX = x, maxX = x, minY = y, maxY = y, area = 0, dark = 0, leaks = false
                while let (cx, cy) = stack.popLast() {
                    area += 1
                    if grayscale[cy * width + cx] < 150 { dark += 1 }
                    minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
                    for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1), (cx - 1, cy - 1), (cx + 1, cy + 1), (cx - 1, cy + 1), (cx + 1, cy - 1)] {
                        guard nx >= region.minX, nx <= region.maxX, ny >= region.minY, ny <= region.maxY else { leaks = true; continue }
                        let n = (ny - region.minY) * bw + (nx - region.minX)
                        guard !seen[n], labels[ny * width + nx] != id, grayscale[ny * width + nx] < lightLevel else { continue }
                        if !enclosed(nx, ny) { leaks = true; continue }
                        seen[n] = true; stack.append((nx, ny))
                    }
                }
                // Pieces touching the outline belong to it (or to art behind).
                guard !leaks, dark > 0, area >= 3 else { continue }
                inkArea += area
                ink.append(CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
            } }
            guard !ink.isEmpty, Double(inkArea) / Double(region.area + inkArea) <= 0.45 else { continue }
            func vision(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX / CGFloat(width), y: 1 - r.maxY / CGFloat(height), width: r.width / CGFloat(width), height: r.height / CGFloat(height))
            }
            let box = CGRect(x: region.minX, y: region.minY, width: bw, height: bh)
            // The inscribed rectangle of an ellipse spans 1/√2 of each axis.
            let inset = fill >= 0.88 ? 0.06 : 0.15
            let core = box.insetBy(dx: CGFloat(bw) * inset, dy: CGFloat(bh) * inset)
            let text = ink.reduce(core) { $0.union($1) }.intersection(box)
            let shortSide = CGFloat(min(bw, bh))
            let glyphSized = ink.allSatisfy { max($0.width, $0.height) <= shortSide * 0.55 }
            let spread = ink.reduce(CGRect.null) { $0.union($1) }
            let holdsText = glyphSized && fill >= 0.5 && ink.count >= 1
                && spread.width * spread.height >= CGFloat(bw * bh) * 0.02
            result.append(SpeechBubble(bounds: vision(box), textArea: vision(text), ink: ink.map(vision), fill: fill, holdsText: holdsText))
        }
        return result
    }
}
