import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Removes locally contrasted ink, not its enclosing rectangle. The result
/// preserves every unmasked source pixel, including a translucent bubble's art.
nonisolated enum TextInkRestoration {
    struct Patch: Sendable {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let changedPixels: Int
    }

    /// Keep a narrow band of unchanged, matching background opaque around
    /// repaired pixels. Otherwise resizing source and patch separately filters
    /// the old ink into translucent patch edges, producing a ghost outline.
    static func compositingPixels(original: [UInt8], patch: Patch) -> [UInt8] {
        let width = patch.width, height = patch.height
        guard width > 0, height > 0, original.count == width * height * 4,
              patch.pixels.count == original.count else { return patch.pixels }
        var covered = [Bool](repeating: false, count: width * height)
        for i in covered.indices where (0..<3).contains(where: { original[i * 4 + $0] != patch.pixels[i * 4 + $0] }) {
            covered[i] = true
            let x = i % width, y = i / width
            for yy in max(0, y - 2)...min(height - 1, y + 2) {
                for xx in max(0, x - 2)...min(width - 1, x + 2) {
                    let j = yy * width + xx
                    // Never reintroduce nearby original ink or artwork from
                    // another region into an overlapping restoration layer.
                    if (0..<3).allSatisfy({ abs(Int(original[j * 4 + $0]) - Int(patch.pixels[i * 4 + $0])) <= 12 }) {
                        covered[j] = true
                    }
                }
            }
        }
        var result = patch.pixels
        for i in covered.indices where !covered[i] {
            for c in 0..<4 { result[i * 4 + c] = 0 }
        }
        return result
    }

    /// Remove lettering that stands as islands on a plain background: the
    /// usual case inside speech bubbles and on flat or softly shaded areas.
    /// The background is estimated from the band just around the text; every
    /// connected patch that differs from it (dark fill, white outline and
    /// antialiased fringe together), lies in the text box and is completely
    /// surrounded by background is cleared. Anything reaching the edge of
    /// the search window (bubble outlines, panel borders, artwork) is kept.
    /// `source` is the text box in pixel coordinates (top-left origin);
    /// `slack` widens it, in glyph sizes, for marks that belong to the text.
    /// Returns the input unchanged when the surroundings are not plain.
    static func removingIslands(pixels: [UInt8], width: Int, height: Int, source: CGRect, glyphSize: Double, slack: Double = 0.3) -> Patch {
        let unchanged = Patch(pixels: pixels, width: width, height: height, changedPixels: 0)
        guard width > 4, height > 4, width * height <= 1_000_000, pixels.count == width * height * 4,
              source.width >= 2, source.height >= 2, glyphSize.isFinite else { return unchanged }
        let glyph = max(4, glyphSize)
        func clamped(_ rect: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
            (max(0, Int(rect.minX.rounded(.down))), max(0, Int(rect.minY.rounded(.down))),
             min(width - 1, Int(rect.maxX.rounded(.up)) - 1), min(height - 1, Int(rect.maxY.rounded(.up)) - 1))
        }
        let box = clamped(source)
        guard box.x0 <= box.x1, box.y0 <= box.y1 else { return unchanged }
        var luminance = [UInt8](repeating: 0, count: width * height)
        for index in luminance.indices {
            let pixel = index * 4
            luminance[index] = UInt8((Int(pixels[pixel]) * 77 + Int(pixels[pixel + 1]) * 150 + Int(pixels[pixel + 2]) * 29) / 256)
        }
        // Background: the most common tone between the strokes that also
        // surrounds the text box. Checking both sides tells paper from ink
        // (which stays inside the box) and from artwork beyond a tight bubble.
        let band = clamped(source.insetBy(dx: -max(3, glyph * 0.25), dy: -max(3, glyph * 0.25)))
        var inner = [Int](repeating: 0, count: 32), outer = [Int](repeating: 0, count: 32)
        var innerCount = 0, outerCount = 0
        for y in band.y0...band.y1 { for x in band.x0...band.x1 {
            let bin = Int(luminance[y * width + x]) / 8
            if x < box.x0 || x > box.x1 || y < box.y0 || y > box.y1 { outer[bin] += 1; outerCount += 1 }
            else { inner[bin] += 1; innerCount += 1 }
        } }
        guard innerCount >= 12, outerCount >= 12 else { return unchanged }
        func share(_ histogram: [Int], _ bin: Int, _ total: Int) -> Double {
            var sum = 0
            for b in max(0, bin - 1)...min(31, bin + 1) { sum += histogram[b] }
            return Double(sum) / Double(total)
        }
        var mode: Int?
        for bin in (0..<32).sorted(by: { share(inner, $0, innerCount) > share(inner, $1, innerCount) }) {
            guard share(inner, bin, innerCount) >= 0.12 else { break }
            if share(outer, bin, outerCount) >= 0.2 { mode = bin; break }
        }
        guard let mode else { return unchanged }
        var toneSum = 0, toneCount = 0, red = 0, green = 0, blue = 0
        for y in band.y0...band.y1 { for x in band.x0...band.x1 {
            let value = Int(luminance[y * width + x])
            guard abs(value / 8 - mode) <= 1 else { continue }
            let pixel = (y * width + x) * 4
            toneSum += value; toneCount += 1
            red += Int(pixels[pixel]); green += Int(pixels[pixel + 1]); blue += Int(pixels[pixel + 2])
        } }
        guard toneCount > 0 else { return unchanged }
        let background = toneSum / toneCount
        let tolerance = 38
        func differs(_ index: Int) -> Bool { abs(Int(luminance[index]) - background) > tolerance }

        let window = clamped(source.insetBy(dx: -max(6, glyph), dy: -max(6, glyph)))
        let reach = clamped(source.insetBy(dx: -glyph * slack, dy: -glyph * slack))
        let ww = window.x1 - window.x0 + 1, wh = window.y1 - window.y0 + 1
        // 0 unvisited, 1 kept, 2 removable
        var state = [UInt8](repeating: 0, count: ww * wh)
        var stack: [Int] = []
        var component: [Int] = []
        var removed = 0
        for wy in 0..<wh { for wx in 0..<ww {
            let start = wy * ww + wx
            guard state[start] == 0, differs((wy + window.y0) * width + wx + window.x0) else { continue }
            component.removeAll(keepingCapacity: true)
            stack.append(start); state[start] = 1
            var touches = false, minX = wx, maxX = wx, minY = wy, maxY = wy
            while let current = stack.popLast() {
                component.append(current)
                let cx = current % ww, cy = current / ww
                minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
                if cx == 0 || cy == 0 || cx == ww - 1 || cy == wh - 1 { touches = true }
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, nx < ww, ny >= 0, ny < wh else { continue }
                    let next = ny * ww + nx
                    if state[next] == 0, differs((ny + window.y0) * width + nx + window.x0) { state[next] = 1; stack.append(next) }
                } }
            }
            guard !touches else { continue }
            // Mostly inside the (widened) text box: lettering, not a neighbour.
            let x0 = max(minX + window.x0, reach.x0), x1 = min(maxX + window.x0, reach.x1)
            let y0 = max(minY + window.y0, reach.y0), y1 = min(maxY + window.y0, reach.y1)
            let extent = (maxX - minX + 1) * (maxY - minY + 1)
            guard x0 <= x1, y0 <= y1, (x1 - x0 + 1) * (y1 - y0 + 1) * 10 >= extent * 7 else { continue }
            // Strokes leave most of their bounding box empty. A large solid
            // patch is a shape (a whole bubble on a wrongly judged tone).
            let large = Double(maxX - minX + 1) > glyph * 2.5 && Double(maxY - minY + 1) > glyph * 2.5
            guard !(large && component.count * 10 > extent * 6) else { continue }
            for index in component { state[index] = 2; removed += 1 }
        } }
        // Lettering never covers most of its own box.
        guard removed > 0, removed * 10 <= (box.x1 - box.x0 + 1) * (box.y1 - box.y0 + 1) * 7 else { return unchanged }
        // Take the antialiased fringe with the strokes.
        for _ in 0..<2 {
            var grown: [Int] = []
            for wy in 0..<wh { for wx in 0..<ww where state[wy * ww + wx] == 0 {
                var near = false
                for dy in -1...1 where !near { for dx in -1...1 {
                    let nx = wx + dx, ny = wy + dy
                    if nx >= 0, nx < ww, ny >= 0, ny < wh, state[ny * ww + nx] == 2 { near = true; break }
                } }
                if near { grown.append(wy * ww + wx) }
            } }
            for index in grown { state[index] = 2 }
        }
        // A very even background is filled with its exact tone; a shaded one
        // is interpolated from the nearest background in eight directions.
        var even = 0, similar = 0
        for y in band.y0...band.y1 { for x in band.x0...band.x1 where !differs(y * width + x) {
            similar += 1
            if abs(Int(luminance[y * width + x]) - background) <= 10 { even += 1 }
        } }
        let flat = even * 20 >= similar * 17
        let tone = [UInt8(red / toneCount), UInt8(green / toneCount), UInt8(blue / toneCount)]
        let directions = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]
        let steps = Int(glyph * 2.5) + 8
        var output = pixels, changed = 0
        for wy in 0..<wh { for wx in 0..<ww where state[wy * ww + wx] == 2 {
            let x = wx + window.x0, y = wy + window.y0, target = (y * width + x) * 4
            changed += 1
            var weight = 0.0, sums = [0.0, 0.0, 0.0], found = 0
            if !flat {
                for (dx, dy) in directions {
                    for step in 1...steps {
                        let sx = wx + dx * step, sy = wy + dy * step
                        guard sx >= 0, sx < ww, sy >= 0, sy < wh else { break }
                        guard state[sy * ww + sx] == 0 else { continue }
                        let sample = ((sy + window.y0) * width + sx + window.x0) * 4
                        let w = 1.0 / Double(step * step)
                        for c in 0..<3 { sums[c] += Double(pixels[sample + c]) * w }
                        weight += w; found += 1
                        break
                    }
                }
            }
            if found >= 2 {
                for c in 0..<3 { output[target + c] = UInt8(min(255, max(0, (sums[c] / weight).rounded()))) }
            } else {
                for c in 0..<3 { output[target + c] = tone[c] }
            }
        } }
        return Patch(pixels: output, width: width, height: height, changedPixels: changed)
    }

    /// `widerRetry` re-estimates the background once at 1.5× the radius when
    /// the first eight samples disagree, e.g. a bold stroke whose samples land
    /// in the neighbouring letter. Disabled only for the reference comparison.
    static func restore(pixels: [UInt8], width: Int, height: Int, glyphs: [CGRect], glyphSize: Double, widerRetry: Bool = true) -> Patch {
        guard width > 2, height > 2, width * height <= 1_000_000, pixels.count == width * height * 4 else {
            return Patch(pixels: pixels, width: width, height: height, changedPixels: 0)
        }
        let radius = min(32, max(3, Int(glyphSize * 0.65)))
        var luminance = [UInt8](repeating: 0, count: width * height)
        for index in luminance.indices {
            let pixel = index * 4
            let red = Int(pixels[pixel]) * 77
            let green = Int(pixels[pixel + 1]) * 150
            let blue = Int(pixels[pixel + 2]) * 29
            luminance[index] = UInt8((red + green + blue) / 256)
        }
        var allowed = [Bool](repeating: false, count: width * height)
        for rect in glyphs {
            let left = max(1, Int(floor(rect.minX))), right = min(width - 2, Int(ceil(rect.maxX)))
            let top = max(1, Int(floor(rect.minY))), bottom = min(height - 2, Int(ceil(rect.maxY)))
            guard left <= right, top <= bottom else { continue }
            for y in top...bottom { for x in left...right { allowed[y * width + x] = true } }
        }
        var mask = [Bool](repeating: false, count: width * height)
        var localBackground = luminance
        // Eight surrounding samples estimate background without a global dark/
        // light assumption. Both dark glyphs and white outline can be detected.
        // One reused scratch buffer: no heap allocation per pixel.
        let directions = [(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(1,-1),(-1,1),(1,1)]
        let wide = radius * 3 / 2 + 1
        var samples = [Int](repeating: 0, count: 8)
        func estimate(_ x: Int, _ y: Int, _ distance: Int) -> Int {
            for (k, (dx, dy)) in directions.enumerated() {
                let xx = min(width - 1, max(0, x + dx * distance)), yy = min(height - 1, max(0, y + dy * distance))
                samples[k] = Int(luminance[yy * width + xx])
            }
            // Insertion sort of eight values, identical order to sort().
            for a in 1..<8 {
                let value = samples[a]
                var b = a - 1
                while b >= 0 && samples[b] > value { samples[b + 1] = samples[b]; b -= 1 }
                samples[b + 1] = value
            }
            return (samples[3] + samples[4]) / 2
        }
        for i in allowed.indices where allowed[i] {
            let x = i % width, y = i / width
            var middle = estimate(x, y, radius)
            // Ignore uncertain picture edges; outlined text remains readable
            // there even if conservative restoration retains some original ink.
            var ink = abs(Int(luminance[i]) - middle) > 58 && samples[5] - samples[2] < 80
            if !ink && widerRetry {
                let second = estimate(x, y, wide)
                if abs(Int(luminance[i]) - second) > 58 && samples[5] - samples[2] < 80 { middle = second; ink = true }
            }
            localBackground[i] = UInt8(middle)
            mask[i] = ink
        }
        // Recover connected stroke edges from a confirmed ink seed. Periodic
        // letters can contaminate the surrounding samples at a cap/descender.
        // Stay inside OCR guidance and limit growth to a fraction of a glyph.
        var frontier = mask.indices.filter { mask[$0] }
        for _ in 0..<min(8, max(2, Int(ceil(glyphSize * 0.2)))) {
            var next: [Int] = []
            for i in frontier {
                let x = i % width, y = i / width
                for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, xx < width, yy >= 0, yy < height else { continue }
                    let j = yy * width + xx
                    if allowed[j] && !mask[j] && abs(Int(luminance[j]) - Int(localBackground[i])) > 8 {
                        mask[j] = true
                        localBackground[j] = localBackground[i]
                        next.append(j)
                    }
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        var output = pixels, changed = 0
        var found = [Int](repeating: 0, count: 8), distances = [Int](repeating: 0, count: 8), weights = [Double](repeating: 0, count: 8)
        for i in mask.indices where mask[i] {
            let x = i % width, y = i / width
            var count = 0
            for (dx, dy) in directions {
                for step in 1...radius * 2 {
                    let xx = x + dx * step, yy = y + dy * step
                    if xx < 0 || xx >= width || yy < 0 || yy >= height { break }
                    let j = yy * width + xx
                    if !mask[j] && abs(Int(luminance[j]) - Int(localBackground[i])) < 40 { found[count] = j; distances[count] = step; count += 1; break }
                }
            }
            guard count >= 3 else { continue }
            // Same inverse-square weighting and summation order as before.
            var total = 0.0
            for k in 0..<count { weights[k] = 1.0 / Double(distances[k] * distances[k]); total += weights[k] }
            for c in 0..<3 {
                var sum = 0.0
                for k in 0..<count { sum += Double(pixels[found[k] * 4 + c]) * weights[k] }
                output[i * 4 + c] = UInt8(min(255, max(0, (sum / total).rounded())))
            }
            changed += 1
        }
        return Patch(pixels: output, width: width, height: height, changedPixels: changed)
    }
}
