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
    /// The interior's inscribed core joined with the original text ink.
    let textArea: CGRect
    /// Enclosed dark components (candidate glyph ink), Vision-normalized.
    let ink: [CGRect]
    /// Share of the bounding box covered by the shape (ellipse ≈ 0.785).
    let fill: Double
    /// Every enclosed component is glyph-sized and the ink spreads across the
    /// interior: a dialogue bubble or caption, not a face, shirt or a panel
    /// background that merely surrounds other bubbles.
    let holdsText: Bool
    /// A compact text container sized like a speech bubble for its lettering
    /// (not a whole panel background): unread ink in it is worth re-reading.
    let isDialogue: Bool
    /// Coarse interior mask over `bounds`; row 0 is the top row.
    let maskColumns: Int
    let maskRows: Int
    let mask: [Bool]

    /// The largest rectangle around `source` that stays inside the bubble,
    /// growing at most `growX`/`growY` (normalized) per side and never into
    /// `avoiding` (other text groups in the same bubble).
    func freeArea(around source: CGRect, growX: CGFloat, growY: CGFloat, avoiding: [CGRect] = []) -> CGRect {
        guard maskColumns > 0, maskRows > 0, mask.count == maskColumns * maskRows, bounds.width > 0, bounds.height > 0 else { return source }
        let cw = bounds.width / CGFloat(maskColumns), ch = bounds.height / CGFloat(maskRows)
        func column(_ value: CGFloat) -> Int { min(maskColumns - 1, max(0, Int(value))) }
        func row(_ value: CGFloat) -> Int { min(maskRows - 1, max(0, Int(value))) }
        var c0 = column(((source.minX - bounds.minX) / cw).rounded(.down)), c1 = column(((source.maxX - bounds.minX) / cw).rounded(.up) - 1)
        var r0 = row(((bounds.maxY - source.maxY) / ch).rounded(.down)), r1 = row(((bounds.maxY - source.minY) / ch).rounded(.up) - 1)
        if c1 < c0 { c1 = c0 }
        if r1 < r0 { r1 = r0 }
        func rect(_ c0: Int, _ c1: Int, _ r0: Int, _ r1: Int) -> CGRect {
            let x: CGFloat = bounds.minX + CGFloat(c0) * cw
            let y: CGFloat = bounds.maxY - CGFloat(r1 + 1) * ch
            let w: CGFloat = CGFloat(c1 - c0 + 1) * cw
            let h: CGFloat = CGFloat(r1 - r0 + 1) * ch
            return CGRect(x: x, y: y, width: w, height: h)
        }
        func inside(_ c0: Int, _ c1: Int, _ r0: Int, _ r1: Int) -> Bool {
            var count = 0
            for r in r0...r1 { for c in c0...c1 where mask[r * maskColumns + c] { count += 1 } }
            let total = (c1 - c0 + 1) * (r1 - r0 + 1)
            // Strict: a strip that leaves the shape would put text on the outline.
            return count + (total >= 12 ? 1 : 0) >= total && !avoiding.contains { $0.intersects(rect(c0, c1, r0, r1).insetBy(dx: cw * 0.1, dy: ch * 0.1)) }
        }
        let limitColumns = max(0, Int((growX / cw).rounded())), limitRows = max(0, Int((growY / ch).rounded()))
        var grown = [0, 0, 0, 0]
        var progressed = true
        while progressed {
            progressed = false
            if grown[0] < limitColumns, c0 > 0, inside(c0 - 1, c0 - 1, r0, r1) { c0 -= 1; grown[0] += 1; progressed = true }
            if grown[1] < limitColumns, c1 < maskColumns - 1, inside(c1 + 1, c1 + 1, r0, r1) { c1 += 1; grown[1] += 1; progressed = true }
            if grown[2] < limitRows, r0 > 0, inside(c0, c1, r0 - 1, r0 - 1) { r0 -= 1; grown[2] += 1; progressed = true }
            if grown[3] < limitRows, r1 < maskRows - 1, inside(c0, c1, r1 + 1, r1 + 1) { r1 += 1; grown[3] += 1; progressed = true }
        }
        return rect(c0, c1, r0, r1).union(source)
    }
}

extension SpeechBubble {
    /// The separate bubbles inside one outline. Two speech bubbles drawn
    /// overlapping share a single enclosed area; where their outlines cross,
    /// the shape has a notch on each side. A short cut between two deep
    /// notches that leaves two large parts separates the bubbles. Returns one
    /// mask per part (same grid as `mask`), or nothing for an ordinary bubble:
    /// a tail, a cloud's bumps or a clipped edge leave no such cut.
    func lobes() -> [[Bool]] { lobeCut()?.parts ?? [] }

    /// A cut longer than this many times its two notch depths together is a
    /// slice through a single shape, not the seam of two bubbles.
    private var cutRatio: Double { 1.6 }

    /// The cut `lobes()` uses, with its measurements.
    func lobeCut() -> (parts: [[Bool]], length: Double, depths: (Double, Double), ends: ((Int, Int), (Int, Int)))? {
        let columns = maskColumns, rows = maskRows, count = columns * rows
        guard columns >= 6, rows >= 6, mask.count == count else { return nil }
        func inside(_ c: Int, _ r: Int) -> Bool { c >= 0 && r >= 0 && c < columns && r < rows && mask[r * columns + c] }
        var cells: [(c: Int, r: Int)] = []
        for r in 0..<rows { for c in 0..<columns where mask[r * columns + c] { cells.append((c, r)) } }
        guard cells.count >= 60 else { return nil }

        // Convex hull of the cell centres (monotone chain).
        typealias Point = (x: Double, y: Double)
        // Cells are generated row by row; order them by column, then row.
        let points: [Point] = cells.sorted { a, b in a.c != b.c ? a.c < b.c : a.r < b.r }.map { cell -> Point in (Double(cell.c), Double(cell.r)) }
        func cross(_ o: Point, _ a: Point, _ b: Point) -> Double {
            let first: Double = (a.x - o.x) * (b.y - o.y)
            let second: Double = (a.y - o.y) * (b.x - o.x)
            return first - second
        }
        var lower: [Point] = [], upper: [Point] = []
        for p in points {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in points.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        let hull = Array(lower.dropLast() + upper.dropLast())
        guard hull.count >= 3 else { return nil }
        func depth(_ x: Double, _ y: Double) -> Double {
            var best = Double.greatestFiniteMagnitude
            for i in hull.indices {
                let a = hull[i], b = hull[(i + 1) % hull.count]
                let dx: Double = b.x - a.x, dy: Double = b.y - a.y
                let squared: Double = dx * dx + dy * dy
                guard squared > 0 else { continue }
                let along: Double = (x - a.x) * dx + (y - a.y) * dy
                let t: Double = max(0, min(1, along / squared))
                let px: Double = a.x + t * dx - x, py: Double = a.y + t * dy - y
                best = min(best, (px * px + py * py).squareRoot())
            }
            return best
        }

        // Notches: boundary cells far inside the hull, at least 4 cells apart.
        let smallSide = Double(min(columns, rows))
        var candidates: [(c: Int, r: Int, depth: Double)] = []
        for cell in cells {
            let boundary = !inside(cell.c - 1, cell.r) || !inside(cell.c + 1, cell.r) || !inside(cell.c, cell.r - 1) || !inside(cell.c, cell.r + 1)
            guard boundary else { continue }
            let d = depth(Double(cell.c), Double(cell.r))
            if d >= max(2, smallSide * 0.08) { candidates.append((cell.c, cell.r, d)) }
        }
        candidates.sort { $0.depth > $1.depth }
        var notches: [(c: Int, r: Int, depth: Double)] = []
        for candidate in candidates where notches.count < 8 {
            if !notches.contains(where: { max(abs($0.c - candidate.c), abs($0.r - candidate.r)) < 4 }) { notches.append(candidate) }
        }
        guard notches.count >= 2 else { return nil }

        // The best cut: across the shape, yet short compared with how deep
        // its two notches are. Two walls of one notch are not a cut.
        var best: (ratio: Double, parts: [[Bool]], length: Double, depths: (Double, Double), ends: ((Int, Int), (Int, Int)))?
        for i in notches.indices { for j in notches.indices where j > i {
            let a = notches[i], b = notches[j]
            let dx = Double(b.c - a.c), dy = Double(b.r - a.r)
            let length: Double = (dx * dx + dy * dy).squareRoot()
            guard length >= smallSide * 0.25, a.depth >= length * 0.15, b.depth >= length * 0.15 else { continue }
            let ratio: Double = length / (a.depth + b.depth)
            guard ratio <= cutRatio, best.map({ ratio < $0.ratio }) ?? true else { continue }
            // The cut is a wall of cells along the segment, through the interior.
            let steps = Int(length * 3) + 1
            var wall = Set<Int>()
            var outside = 0
            for k in 0...steps {
                let t = Double(k) / Double(steps)
                let x: Double = Double(a.c) + dx * t, y: Double = Double(a.r) + dy * t
                let c = Int(x.rounded()), r = Int(y.rounded())
                if inside(c, r) { wall.insert(r * columns + c) } else { outside += 1 }
                // Close diagonal gaps so a four-way fill cannot slip through.
                let c2 = Int(x.rounded(.down)), r2 = Int(y.rounded(.down))
                for (wc, wr) in [(c2, r2), (c2 + 1, r2), (c2, r2 + 1)] where inside(wc, wr) { wall.insert(wr * columns + wc) }
            }
            guard Double(outside) <= Double(steps + 1) * 0.08 else { continue }
            // Flood each side of the wall. A real cut leaves exactly two large
            // pieces, each most of its side.
            var piece = [Int](repeating: -1, count: count)
            var sizes: [Int] = []
            for cell in cells {
                let start = cell.r * columns + cell.c
                guard piece[start] < 0, !wall.contains(start) else { continue }
                let id = sizes.count
                piece[start] = id
                var stack = [start], size = 0
                while let index = stack.popLast() {
                    size += 1
                    let c = index % columns, r = index / columns
                    for (nc, nr) in [(c - 1, r), (c + 1, r), (c, r - 1), (c, r + 1)] where inside(nc, nr) {
                        let next = nr * columns + nc
                        if piece[next] < 0 && !wall.contains(next) { piece[next] = id; stack.append(next) }
                    }
                }
                sizes.append(size)
            }
            let large = sizes.indices.filter { sizes[$0] * 5 >= cells.count }.sorted { sizes[$0] > sizes[$1] }
            guard large.count == 2, sizes.reduce(0, +) - sizes[large[0]] - sizes[large[1]] <= cells.count / 20 else { continue }
            // Wall cells and crumbs join the nearer large piece.
            var parts = [[Bool]](repeating: [Bool](repeating: false, count: count), count: 2)
            for cell in cells {
                let index = cell.r * columns + cell.c
                if let p = large.firstIndex(of: piece[index]) { parts[p][index] = true; continue }
                let across: Double = Double(cell.c - a.c) * dy - Double(cell.r - a.r) * dx
                let reference = cells.first { piece[$0.r * columns + $0.c] == large[0] }!
                let referenceSide: Double = Double(reference.c - a.c) * dy - Double(reference.r - a.r) * dx
                parts[(across >= 0) == (referenceSide >= 0) ? 0 : 1][index] = true
            }
            best = (ratio, parts, length, (a.depth, b.depth), ((a.c, a.r), (b.c, b.r)))
        } }
        return best.map { ($0.parts, $0.length, $0.depths, $0.ends) }
    }

    /// The same bubble limited to one of its lobes.
    func restricted(to lobe: [Bool]) -> SpeechBubble {
        SpeechBubble(bounds: bounds, textArea: textArea, ink: ink, fill: fill, holdsText: holdsText, isDialogue: isDialogue,
                     maskColumns: maskColumns, maskRows: maskRows, mask: lobe)
    }

    /// Index of the lobe that holds most of `box` (Vision-normalized), if any.
    func lobe(of box: CGRect, in lobes: [[Bool]]) -> Int? {
        guard !lobes.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }
        let cw = bounds.width / CGFloat(maskColumns), ch = bounds.height / CGFloat(maskRows)
        let c0 = max(0, Int(((box.minX - bounds.minX) / cw).rounded(.down))), c1 = min(maskColumns - 1, Int(((box.maxX - bounds.minX) / cw).rounded(.up)) - 1)
        let r0 = max(0, Int(((bounds.maxY - box.maxY) / ch).rounded(.down))), r1 = min(maskRows - 1, Int(((bounds.maxY - box.minY) / ch).rounded(.up)) - 1)
        guard c0 <= c1, r0 <= r1 else { return nil }
        var counts = [Int](repeating: 0, count: lobes.count)
        for r in r0...r1 { for c in c0...c1 {
            for (index, lobe) in lobes.enumerated() where lobe[r * maskColumns + c] { counts[index] += 1 }
        } }
        guard let best = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[best] > 0 else { return nil }
        return best
    }
}

nonisolated enum BubbleDetector {
    /// `grayscale` rows use a top-left origin. Two passes are merged: plain
    /// connectivity keeps tightly lettered and small bubbles whole, and a
    /// gap-closing pass recovers bubbles whose outline is dashed, broken or
    /// lost to scaling.
    static func bubbles(grayscale: [UInt8], width: Int, height: Int) -> [SpeechBubble] {
        let count = width * height
        guard width >= 32, height >= 32, grayscale.count == count, count <= 4_500_000 else { return [] }
        let closing = max(1, min(3, Int((Double(max(width, height)) / 1200).rounded())))
        var result: [SpeechBubble] = []
        func area(_ r: CGRect) -> CGFloat { max(0, r.width) * max(0, r.height) }
        for bubble in detect(grayscale: grayscale, width: width, height: height, reach: 0)
            + detect(grayscale: grayscale, width: width, height: height, reach: closing) {
            if let index = result.firstIndex(where: { other in
                let shared = other.bounds.intersection(bubble.bounds)
                // Nested regions are kept: a line joins its smallest enclosure.
                guard !shared.isNull else { return false }
                let union: CGFloat = area(other.bounds) + area(bubble.bounds) - area(shared)
                return area(shared) >= union * 0.7
            }) {
                // The same bubble seen twice: prefer the text container, then
                // the more regular shape.
                let other = result[index]
                if (bubble.holdsText && !other.holdsText) || (bubble.holdsText == other.holdsText && bubble.fill > other.fill) { result[index] = bubble }
            } else { result.append(bubble) }
        }
        return result
    }

    private static let stepX = [-1, 1, 0, 0, -1, 1, -1, 1]
    private static let stepY = [0, 0, -1, 1, -1, 1, 1, -1]

    private static func detect(grayscale: [UInt8], width: Int, height: Int, reach: Int) -> [SpeechBubble] {
        let count = width * height
        // Paper is light; screentone, art and text are not. JPEG ringing
        // keeps true bubble paper above ~205.
        let lightLevel: UInt8 = 205
        // Close small gaps in outlines: paper must be clear of line art by
        // `reach` pixels to connect two areas.
        var open = [Bool](repeating: false, count: count)
        if reach == 0 {
            for index in 0..<count { open[index] = grayscale[index] >= lightLevel }
        } else {
            // Separable erosion of the paper mask; outside the image counts as paper.
            var horizontal = [Bool](repeating: false, count: count)
            for y in 0..<height {
                var dark = 0
                let row = y * width
                for x in 0..<min(width, reach) where grayscale[row + x] < lightLevel { dark += 1 }
                for x in 0..<width {
                    if x + reach < width, grayscale[row + x + reach] < lightLevel { dark += 1 }
                    if x - reach - 1 >= 0, grayscale[row + x - reach - 1] < lightLevel { dark -= 1 }
                    horizontal[row + x] = dark == 0
                }
            }
            for x in 0..<width {
                var blocked = 0
                for y in 0..<min(height, reach) where !horizontal[y * width + x] { blocked += 1 }
                for y in 0..<height {
                    if y + reach < height, !horizontal[(y + reach) * width + x] { blocked += 1 }
                    if y - reach - 1 >= 0, !horizontal[(y - reach - 1) * width + x] { blocked -= 1 }
                    open[y * width + x] = blocked == 0
                }
            }
        }
        var labels = [Int32](repeating: -1, count: count)
        struct Region { var area = 0; var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1; var left = 0, right = 0, top = 0, bottom = 0 }
        var regions: [Region] = []
        var queue = [Int](); queue.reserveCapacity(4096)
        for start in 0..<count where labels[start] < 0 && open[start] {
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
                if x == 0 { region.left += 1 }; if x == width - 1 { region.right += 1 }
                if y == 0 { region.top += 1 }; if y == height - 1 { region.bottom += 1 }
                // Four explicit neighbours: no temporary array per pixel.
                if x > 0, labels[index - 1] < 0, open[index - 1] { labels[index - 1] = id; queue.append(index - 1) }
                if x < width - 1, labels[index + 1] < 0, open[index + 1] { labels[index + 1] = id; queue.append(index + 1) }
                if y > 0, labels[index - width] < 0, open[index - width] { labels[index - width] = id; queue.append(index - width) }
                if y < height - 1, labels[index + width] < 0, open[index + width] { labels[index + width] = id; queue.append(index + width) }
                // Large page backgrounds: keep only the unprocessed frontier.
                if head >= 8192 && head * 2 >= queue.count { queue.removeFirst(head); head = 0 }
            }
            regions.append(region)
        }
        let minimumArea = max(60, count / 6000), maximumArea = count / 5
        var result: [SpeechBubble] = []
        for (index, region) in regions.enumerated() {
            let bw = region.maxX - region.minX + 1, bh = region.maxY - region.minY + 1
            guard region.area >= minimumArea, region.area <= maximumArea else { continue }
            guard bw >= 10, bh >= 10, Double(max(bw, bh)) / Double(min(bw, bh)) <= 6 else { continue }
            // A bubble can be cut by one page edge; page margins and gutters
            // run along an edge or touch several.
            let edges = [region.left, region.right, region.top, region.bottom]
            guard edges.filter({ $0 > 0 }).count <= 1 else { continue }
            let id = Int32(index)
            // Row and column extents of the interior decide what it encloses.
            var rowMin = [Int](repeating: Int.max, count: bh), rowMax = [Int](repeating: -1, count: bh)
            var colMin = [Int](repeating: Int.max, count: bw), colMax = [Int](repeating: -1, count: bw)
            for y in region.minY...region.maxY { for x in region.minX...region.maxX where labels[y * width + x] == id {
                let ry = y - region.minY, rx = x - region.minX
                rowMin[ry] = min(rowMin[ry], x); rowMax[ry] = max(rowMax[ry], x)
                colMin[rx] = min(colMin[rx], y); colMax[rx] = max(colMax[rx], y)
            } }
            var span = 0
            for ry in 0..<bh where rowMax[ry] >= 0 { span += rowMax[ry] - rowMin[ry] + 1 }
            let fill = Double(span) / Double(bw * bh)
            // Text holes are allowed; a thin ring around something else is not.
            guard fill >= 0.45, Double(region.area) / Double(span) >= 0.3 else { continue }
            // The eroded interior stops `reach` pixels short of the outline.
            func enclosed(_ x: Int, _ y: Int) -> Bool {
                let ry = y - region.minY, rx = x - region.minX
                guard rowMax[ry] >= 0, colMax[rx] >= 0 else { return false }
                let inRow = x >= rowMin[ry] - reach && x <= rowMax[ry] + reach
                let inColumn = y >= colMin[rx] - reach && y <= colMax[rx] + reach
                return inRow && inColumn
            }
            // Enclosed non-paper components are the bubble's content.
            var seen = [Bool](repeating: false, count: bw * bh)
            var ink: [CGRect] = []
            var inkArea = 0
            for y in region.minY...region.maxY { for x in region.minX...region.maxX {
                let local = (y - region.minY) * bw + (x - region.minX)
                guard !seen[local], grayscale[y * width + x] < lightLevel, enclosed(x, y) else { continue }
                var stack = [(x, y)]; seen[local] = true
                var minX = x, maxX = x, minY = y, maxY = y, area = 0, dark = 0, leaks = false
                while let (cx, cy) = stack.popLast() {
                    area += 1
                    if grayscale[cy * width + cx] < 150 { dark += 1 }
                    minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
                    for step in 0..<8 {
                        let nx = cx + Self.stepX[step], ny = cy + Self.stepY[step]
                        guard nx >= region.minX, nx <= region.maxX, ny >= region.minY, ny <= region.maxY else {
                            if nx >= 0, nx < width, ny >= 0, ny < height, grayscale[ny * width + nx] < lightLevel { leaks = true }
                            continue
                        }
                        let n = (ny - region.minY) * bw + (nx - region.minX)
                        guard !seen[n], grayscale[ny * width + nx] < lightLevel else { continue }
                        if !enclosed(nx, ny) { leaks = true; continue }
                        seen[n] = true; stack.append((nx, ny))
                    }
                }
                // Pieces touching the outline belong to it (or to art behind).
                guard !leaks, dark > 0, area >= 3 else { continue }
                inkArea += area
                ink.append(CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
            } }
            guard !ink.isEmpty, Double(inkArea) / Double(span) <= 0.5 else { continue }
            // A stray piece of outline or art among many glyphs (a bubble open
            // to the page margin encloses part of its own outline) must not
            // disqualify the lettering around it.
            if ink.count >= 6 {
                let ordered = ink.map { max($0.width, $0.height) }.sorted()
                let typical = ordered[ordered.count / 2]
                let strays = ink.filter { max($0.width, $0.height) > typical * 3.2 }
                if strays.count <= 2 { ink.removeAll { max($0.width, $0.height) > typical * 3.2 } }
            }
            func vision(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX / CGFloat(width), y: 1 - r.maxY / CGFloat(height), width: r.width / CGFloat(width), height: r.height / CGFloat(height))
            }
            let box = CGRect(x: region.minX, y: region.minY, width: bw, height: bh)
            // The inscribed rectangle of an ellipse spans 1/√2 of each axis.
            let inset = fill >= 0.88 ? 0.06 : 0.15
            let core = box.insetBy(dx: CGFloat(bw) * inset, dy: CGFloat(bh) * inset)
            let text = ink.reduce(core) { $0.union($1) }.intersection(box)
            let shortSide = CGFloat(min(bw, bh))
            // One mark alone must be clearly smaller than its bubble.
            let glyphSized = ink.allSatisfy { max($0.width, $0.height) <= shortSide * (ink.count >= 2 ? 0.75 : 0.55) }
            let spread = ink.reduce(CGRect.null) { $0.union($1) }
            // Several glyph-sized marks, or one mark in a clean bubble shape;
            // a few specks in a large area are not lettering.
            let inkShare: Double = Double(inkArea) / Double(span)
            let spreadShare: CGFloat = spread.width * spread.height / CGFloat(bw * bh)
            let holdsText = glyphSized && (ink.count >= 2 || fill >= 0.6) && inkShare >= 0.008 && spreadShare >= 0.02
            let sizes = ink.map { max($0.width, $0.height) }.sorted()
            let glyph = sizes[min(sizes.count - 1, sizes.count * 3 / 4)]
            let isDialogue = holdsText && Double(span).squareRoot() <= Double(glyph) * 12 && ink.count <= 80
            // Coarse interior mask for laying text out inside the shape.
            let step = max(1, Int((Double(max(bw, bh)) / 64).rounded(.up)))
            let columns = (bw + step - 1) / step, rows = (bh + step - 1) / step
            var mask = [Bool](repeating: false, count: columns * rows)
            for r in 0..<rows { for c in 0..<columns {
                let x = min(region.maxX, region.minX + c * step + step / 2), y = min(region.maxY, region.minY + r * step + step / 2)
                mask[r * columns + c] = enclosed(x, y)
            } }
            result.append(SpeechBubble(bounds: vision(box), textArea: vision(text), ink: ink.map(vision), fill: fill, holdsText: holdsText, isDialogue: isDialogue,
                                       maskColumns: columns, maskRows: rows, mask: mask))
        }
        return result
    }
}
