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

    static func restore(pixels: [UInt8], width: Int, height: Int, glyphs: [CGRect], glyphSize: Double) -> Patch {
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
        for i in allowed.indices where allowed[i] {
            let x = i % width, y = i / width
            var samples: [Int] = []
            for (dx, dy) in [(-radius,0),(radius,0),(0,-radius),(0,radius),(-radius,-radius),(radius,-radius),(-radius,radius),(radius,radius)] {
                let xx = min(width - 1, max(0, x + dx)), yy = min(height - 1, max(0, y + dy))
                samples.append(Int(luminance[yy * width + xx]))
            }
            samples.sort()
            let middle = (samples[3] + samples[4]) / 2
            localBackground[i] = UInt8(middle)
            // Ignore uncertain picture edges; outlined text remains readable
            // there even if conservative restoration retains some original ink.
            mask[i] = abs(Int(luminance[i]) - middle) > 58 && samples[5] - samples[2] < 80
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
        for i in mask.indices where mask[i] {
            let x = i % width, y = i / width
            var samples: [(index: Int, distance: Int)] = []
            for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(1,-1),(-1,1),(1,1)] {
                for step in 1...radius * 2 {
                    let xx = x + dx * step, yy = y + dy * step
                    if xx < 0 || xx >= width || yy < 0 || yy >= height { break }
                    let j = yy * width + xx
                    if !mask[j] && abs(Int(luminance[j]) - Int(localBackground[i])) < 40 { samples.append((j, step)); break }
                }
            }
            guard samples.count >= 3 else { continue }
            let weights = samples.map { 1.0 / Double($0.distance * $0.distance) }
            let total = weights.reduce(0, +)
            for c in 0..<3 {
                let value = zip(samples, weights).reduce(0.0) { $0 + Double(pixels[$1.0.index * 4 + c]) * $1.1 } / total
                output[i * 4 + c] = UInt8(min(255, max(0, value.rounded())))
            }
            changed += 1
        }
        return Patch(pixels: output, width: width, height: height, changedPixels: changed)
    }
}
