import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A local geometry fallback for upright vertical writing which Vision's
/// horizontal text detector can miss entirely. It reads no text itself.
nonisolated enum VerticalInkDetector {
    private struct Component {
        let box: CGRect
        var centerX: CGFloat { box.midX }
        var centerY: CGFloat { box.midY }
    }

    /// Input rows use a top-left origin; output boxes use Vision coordinates.
    static func columns(grayscale: [UInt8], width: Int, height: Int) -> [[CGRect]] {
        guard width > 0, height > 0, width * height <= 3_000_000, grayscale.count == width * height else { return [] }
        let inverted = grayscale.filter { $0 < 80 }.count > grayscale.count * 4 / 5
        func ink(_ i: Int) -> Bool { inverted ? grayscale[i] > 200 : grayscale[i] < 110 }
        func background(_ i: Int) -> Bool { inverted ? grayscale[i] < 90 : grayscale[i] > 190 }
        var visited = [Bool](repeating: false, count: grayscale.count)
        var components: [Component] = []
        let largest = max(24, min(width, height) / 10)
        for start in grayscale.indices where !visited[start] && ink(start) {
            var queue = [start], head = 0, area = 0
            visited[start] = true
            var left = start % width, right = left, top = start / width, bottom = top
            while head < queue.count {
                let index = queue[head]; head += 1; area += 1
                let x = index % width, y = index / width
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, xx < width, yy >= 0, yy < height else { continue }
                        let next = yy * width + xx
                        if !visited[next] && ink(next) { visited[next] = true; queue.append(next) }
                    }
                }
                // A screenshot's black margins can be one enormous component.
                // Retain the BFS frontier, not every pixel already visited.
                if head >= 4096 && head * 2 >= queue.count {
                    queue.removeFirst(head); head = 0
                }
            }
            let w = right - left + 1, h = bottom - top + 1
            // Small kana voicing marks belong to the glyph too; keep them for
            // assignment after the larger components establish the text grid.
            guard area >= 3, w <= largest, h <= largest, max(w, h) >= 2 else { continue }
            // Reject picture texture without a light/dark, mostly uniform ring.
            var count = 0, matching = 0
            for y in max(0, top - 2)...min(height - 1, bottom + 2) {
                for x in max(0, left - 2)...min(width - 1, right + 2) where x < left || x > right || y < top || y > bottom {
                    count += 1
                    if background(y * width + x) { matching += 1 }
                }
            }
            guard count > 0, Double(matching) / Double(count) >= 0.65 else { continue }
            components.append(Component(box: CGRect(x: left, y: top, width: w, height: h)))
            if components.count > 15_000 { return [] }
        }
        let seeds = components.filter { $0.box.height >= 8 && $0.box.width >= 4 && $0.box.width <= $0.box.height * 1.7 }
            .sorted { $0.box.height > $1.box.height }
        var tracks: [[Component]] = []
        for seed in seeds {
            if let index = tracks.firstIndex(where: { track in
                let scale = track[0].box.height
                let center = track.map(\.centerX).reduce(0, +) / CGFloat(track.count)
                return seed.box.height >= scale * 0.55 && abs(seed.centerX - center) < scale * 0.55
            }) { tracks[index].append(seed) }
            else { tracks.append([seed]) }
        }
        // Separate panels/bubbles before estimating the character grid. Two
        // columns at the same x need not share the same vertical starting phase.
        var spans: [[Component]] = []
        for track in tracks {
            let scale = track.map { $0.box.height }.sorted()[track.count / 2]
            var span: [Component] = []
            for seed in track.sorted(by: { $0.centerY < $1.centerY }) {
                if let last = span.last, seed.centerY - last.centerY > scale * 3.8 { spans.append(span); span = [] }
                span.append(seed)
            }
            if !span.isEmpty { spans.append(span) }
        }
        var result: [[CGRect]] = []
        for track in spans where track.count >= 2 {
            let scale = track.map { $0.box.height }.sorted()[track.count / 2]
            let centerX = track.map(\.centerX).reduce(0, +) / CGFloat(track.count)
            var centers: [CGFloat] = []
            for value in track.map(\.centerY).sorted() {
                if let last = centers.last, value - last < scale * 0.55 { centers[centers.count - 1] = (last + value) / 2 }
                else { centers.append(value) }
            }
            let distances = zip(centers, centers.dropFirst()).map { $1 - $0 }.filter { $0 >= scale * 0.7 && $0 <= scale * 2.2 }.sorted()
            guard centers.count >= 2, !distances.isEmpty else { continue }
            let pitch = distances[distances.count / 2], origin = centers[0]
            let regular = centers.filter { abs(($0 - origin) / pitch - (($0 - origin) / pitch).rounded()) < 0.23 }
            guard regular.count * 4 >= centers.count * 3 else { continue }
            var cells: [Int: CGRect] = [:]
            for component in components where abs(component.centerX - centerX) <= scale * 0.72 && max(component.box.width, component.box.height) <= scale * 1.7
                && component.centerY >= centers[0] - scale * 2.5 && component.centerY <= centers[centers.count - 1] + scale * 2.5 {
                let row = Int(((component.centerY - origin) / pitch).rounded())
                guard abs(component.centerY - (origin + CGFloat(row) * pitch)) < pitch * 0.46 else { continue }
                cells[row] = (cells[row] ?? .null).union(component.box)
            }
            var run: [CGRect] = [], previous: Int?
            func finish() {
                guard run.count >= 2 else { return }
                let union = run.reduce(CGRect.null) { $0.union($1) }
                guard union.height > union.width * (run.count == 2 ? 1.65 : 2.2) else { return }
                result.append(run.map { box in
                    CGRect(x: box.minX / CGFloat(width), y: 1 - box.maxY / CGFloat(height), width: box.width / CGFloat(width), height: box.height / CGFloat(height))
                })
            }
            for row in cells.keys.sorted() {
                if let previous, row - previous > 1 { finish(); run = [] }
                if let box = cells[row] { run.append(box) }
                previous = row
            }
            finish()
        }
        return result
    }
}
