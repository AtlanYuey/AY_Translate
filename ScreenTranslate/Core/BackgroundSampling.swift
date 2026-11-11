import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated struct SampledColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    /// Distinctly coloured text ink inside the region (RGB, 0–1), if any.
    var ink: [Double]? = nil

    var usesDarkText: Bool {
        func linear(_ channel: Double) -> Double { channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) > 0.179
    }
}

/// RGBA bitmap rows run from the top edge; Vision regions use a bottom-left
/// origin. Convert that boundary explicitly before sampling the perimeter.
nonisolated enum BackgroundSampling {
    /// The text's own colour: pixels far from the background, strongest half.
    /// Returns nil for black/grey ink, which keeps the usual contrast rule.
    static func ink(pixels: [UInt8], width: Int, height: Int, region: CGRect, background: SampledColor) -> [Double]? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        let left = max(0, Int(region.minX * Double(width))), right = min(width - 1, Int(region.maxX * Double(width)))
        let top = max(0, Int((1 - region.maxY) * Double(height))), bottom = min(height - 1, Int((1 - region.minY) * Double(height)))
        guard left <= right, top <= bottom else { return nil }
        let br = background.red * 255, bg = background.green * 255, bb = background.blue * 255
        let step = max(1, Int(Double((right - left + 1) * (bottom - top + 1)).squareRoot() / 80))
        var samples: [(distance: Double, r: Double, g: Double, b: Double)] = []
        for y in stride(from: top, through: bottom, by: step) { for x in stride(from: left, through: right, by: step) {
            let i = (y * width + x) * 4
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
            let dr = r - br, dg = g - bg, db = b - bb
            let distance: Double = (dr * dr + dg * dg + db * db).squareRoot()
            if distance > 90 { samples.append((distance, r, g, b)) }
        } }
        guard samples.count >= 6 else { return nil }
        let strongest = samples.sorted { $0.distance > $1.distance }.prefix(max(3, samples.count / 2))
        let n = Double(strongest.count) * 255
        var red = 0.0, green = 0.0, blue = 0.0
        for sample in strongest { red += sample.r; green += sample.g; blue += sample.b }
        let color = [red / n, green / n, blue / n]
        guard let high = color.max(), let low = color.min(), high - low >= 0.16 else { return nil }
        return color
    }

    /// Ink colours of two text regions that clearly differ (speaker colours).
    static func inksDiffer(_ a: [Double]?, _ b: [Double]?) -> Bool {
        guard let a, let b, a.count == 3, b.count == 3 else { return false }
        let dr = a[0] - b[0], dg = a[1] - b[1], db = a[2] - b[2]
        let distance: Double = (dr * dr + dg * dg + db * db).squareRoot()
        return distance > 0.22
    }

    static func sample(pixels: [UInt8], width: Int, height: Int, region: CGRect) -> SampledColor {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else {
            return SampledColor(red: 1, green: 1, blue: 1)
        }
        let left = Int(region.minX * Double(width)), right = Int(region.maxX * Double(width))
        let firstRow = Int((1 - region.maxY) * Double(height))
        let lastRow = Int((1 - region.minY) * Double(height))
        var points: [(Int, Int)] = []
        for step in 0...10 {
            let x = left + (right - left) * step / 10
            let y = firstRow + (lastRow - firstRow) * step / 10
            points += [(x, firstRow - 2), (x, lastRow + 2), (left - 2, y), (right + 2, y)]
        }
        var bins: [Int: [(Int, Int, Int)]] = [:]
        for (x, y) in points where x >= 0 && x < width && y >= 0 && y < height {
            let i = (y * width + x) * 4
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let bin = (r / 16) * 256 + (g / 16) * 16 + b / 16
            bins[bin, default: []].append((r, g, b))
        }
        guard let dominant = bins.max(by: { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count < $1.value.count })?.value, !dominant.isEmpty else {
            return SampledColor(red: 1, green: 1, blue: 1)
        }
        let count = Double(dominant.count) * 255
        return SampledColor(red: Double(dominant.reduce(0) { $0 + $1.0 }) / count,
                            green: Double(dominant.reduce(0) { $0 + $1.1 }) / count,
                            blue: Double(dominant.reduce(0) { $0 + $1.2 }) / count)
    }
}
