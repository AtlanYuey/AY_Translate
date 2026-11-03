import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated struct SampledColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var usesDarkText: Bool {
        func linear(_ channel: Double) -> Double { channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) > 0.179
    }
}

/// RGBA bitmap rows run from the top edge; Vision regions use a bottom-left
/// origin. Convert that boundary explicitly before sampling the perimeter.
nonisolated enum BackgroundSampling {
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
