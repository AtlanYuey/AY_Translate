import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The extension's process budget, not the device's total RAM, determines the
/// working window. Zero available bytes is an unknown simulator measurement.
nonisolated struct OCRResourcePolicy: Sendable {
    let memoryLimited: Bool
    let constrained: Bool
    var tileDimension: Int { constrained ? 1024 : 1536 }
    var prefersCPU: Bool { memoryLimited }

    init(memoryLimited: Bool, recentWarning: Bool = false, availableBytes: UInt64 = 0, footprintBytes: UInt64 = 0) {
        self.memoryLimited = memoryLimited
        constrained = memoryLimited && (recentWarning || (availableBytes > 0 && availableBytes < 96 * 1_024 * 1_024)
            || footprintBytes >= 140 * 1_024 * 1_024)
    }

    /// Overlap preserves lines straddling a tile boundary. Each tile uses source
    /// pixels rather than shrinking the whole page (and its small ruby text).
    func regions(for size: CGSize) -> [CGRect] {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return [] }
        guard memoryLimited else { return [CGRect(x: 0, y: 0, width: 1, height: 1)] }
        let dimension = CGFloat(tileDimension)
        func starts(_ extent: CGFloat) -> [CGFloat] {
            guard extent > dimension else { return [0] }
            let count = Int(ceil((extent - dimension) / (dimension * 0.8))) + 1
            return (0..<count).map { CGFloat($0) * (extent - dimension) / CGFloat(count - 1) }
        }
        return starts(size.height).reversed().flatMap { y in
            starts(size.width).map { x in
                CGRect(x: x / size.width, y: y / size.height,
                       width: min(dimension, size.width) / size.width, height: min(dimension, size.height) / size.height)
            }
        }
    }
}
