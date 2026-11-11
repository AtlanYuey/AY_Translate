import XCTest
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import ScreenTranslationCore

/// The allocation-free restoration must stay byte-identical to the previous
/// implementation (kept verbatim below as the reference).
final class RestorationEquivalenceTests: XCTestCase {
    func testOptimizedRestorationMatchesTheReferenceByteForByte() {
        var generator = SystemRandomNumberGenerator()
        for trial in 0..<24 {
            let width = Int.random(in: 20...90, using: &generator), height = Int.random(in: 20...70, using: &generator)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let paper = UInt8.random(in: 150...255, using: &generator), ink = UInt8.random(in: 0...90, using: &generator)
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                let stroke = (x / 3 + y / 5 + trial) % 4 == 0 && x > 6 && x < width - 6 && y > 6 && y < height - 6
                let noise = UInt8.random(in: 0...12, using: &generator)
                let value = stroke ? ink &+ noise : paper &- noise
                pixels[i] = value; pixels[i + 1] = value &+ UInt8(x % 7); pixels[i + 2] = value &- UInt8(y % 5); pixels[i + 3] = 255
            } }
            let glyphs = [CGRect(x: 4, y: 4, width: Double(width) * 0.45, height: Double(height) - 8),
                          CGRect(x: Double(width) * 0.5, y: 6, width: Double(width) * 0.4, height: Double(height) * 0.6)]
            let size = Double.random(in: 4...30, using: &generator)
            let fast = TextInkRestoration.restore(pixels: pixels, width: width, height: height, glyphs: glyphs, glyphSize: size)
            let reference = Self.legacyRestore(pixels: pixels, width: width, height: height, glyphs: glyphs, glyphSize: size)
            XCTAssertEqual(fast.pixels, reference.pixels, "trial \(trial)")
            XCTAssertEqual(fast.changedPixels, reference.changedPixels, "trial \(trial)")
        }
    }

    // MARK: - Reference implementation (AY Translate 1.0.0)

        static func legacyRestore(pixels: [UInt8], width: Int, height: Int, glyphs: [CGRect], glyphSize: Double) -> TextInkRestoration.Patch {
        guard width > 2, height > 2, width * height <= 1_000_000, pixels.count == width * height * 4 else {
            return TextInkRestoration.Patch(pixels: pixels, width: width, height: height, changedPixels: 0)
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
        return TextInkRestoration.Patch(pixels: output, width: width, height: height, changedPixels: changed)
    }
}
