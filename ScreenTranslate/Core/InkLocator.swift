import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Local pixel evidence for a text region that only a cloud recognizer found
/// (handwriting, stylized titles, text the on-device recognizer skipped).
/// A model's box is accepted for an overlay only when the area actually holds
/// contrasting ink, and the box is tightened to that ink. It reads no text.
nonisolated struct InkLocator: Sendable {
    /// Grayscale rows with a top-left origin.
    let pixels: [UInt8]
    let width: Int
    let height: Int

    init?(pixels: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.pixels = pixels; self.width = width; self.height = height
    }

    /// `box` uses Vision's normalized coordinates (origin bottom left). Returns
    /// the tightened ink box in the same space, or nil without text-like ink.
    func verifiedBox(_ box: CGRect) -> CGRect? {
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let left = box.minX * w, top = (1 - box.maxY) * h, boxWidth = box.width * w, boxHeight = box.height * h
        guard boxWidth >= 3, boxHeight >= 3 else { return nil }
        func clampX(_ value: CGFloat) -> Int { min(width, max(0, Int(value.rounded()))) }
        func clampY(_ value: CGFloat) -> Int { min(height, max(0, Int(value.rounded()))) }
        let ix0 = clampX(left), ix1 = clampX(left + boxWidth), iy0 = clampY(top), iy1 = clampY(top + boxHeight)
        guard ix1 - ix0 >= 3, iy1 - iy0 >= 3 else { return nil }

        // Otsu threshold inside the model's box separates ink from paper.
        var histogram = [Int](repeating: 0, count: 256)
        for y in iy0..<iy1 { for x in ix0..<ix1 { histogram[Int(pixels[y * width + x])] += 1 } }
        let total = (ix1 - ix0) * (iy1 - iy0)
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var backgroundWeight = 0, backgroundSum = 0.0, best = -1.0, threshold = 0
        for level in 0..<256 {
            backgroundWeight += histogram[level]
            guard backgroundWeight > 0 else { continue }
            let foregroundWeight = total - backgroundWeight
            guard foregroundWeight > 0 else { break }
            backgroundSum += Double(level * histogram[level])
            let darkMean = backgroundSum / Double(backgroundWeight)
            let lightMean = (sum - backgroundSum) / Double(foregroundWeight)
            let between = Double(backgroundWeight) * Double(foregroundWeight) * (darkMean - lightMean) * (darkMean - lightMean)
            if between > best { best = between; threshold = level }
        }
        var dark = 0, darkSum = 0.0
        for level in 0...threshold { dark += histogram[level]; darkSum += Double(level * histogram[level]) }
        let light = total - dark
        guard dark > 0, light > 0 else { return nil }
        let contrast = (sum - darkSum) / Double(light) - darkSum / Double(dark)
        // Text is the minority class whether it is dark-on-light or inverted.
        let inkIsDark = dark <= light
        let ink = min(dark, light)
        let fraction = Double(ink) / Double(total)
        guard contrast >= 48, fraction >= 0.01, fraction <= 0.62 else { return nil }
        func isInk(_ value: UInt8) -> Bool { inkIsDark ? Int(value) <= threshold : Int(value) > threshold }

        // Tighten within a small margin: model boxes are often a few pixels
        // short of descenders or the last handwritten stroke.
        let marginX = boxWidth * 0.12 + 2, marginY = boxHeight * 0.12 + 2
        let sx0 = clampX(left - marginX), sx1 = clampX(left + boxWidth + marginX)
        let sy0 = clampY(top - marginY), sy1 = clampY(top + boxHeight + marginY)
        var rows = [Int](repeating: 0, count: sy1 - sy0), columns = [Int](repeating: 0, count: sx1 - sx0)
        for y in sy0..<sy1 { for x in sx0..<sx1 where isInk(pixels[y * width + x]) { rows[y - sy0] += 1; columns[x - sx0] += 1 } }
        // Ignore stray specks at the margin: a row/column needs a few ink pixels.
        let minimumRow = max(1, (sx1 - sx0) / 200), minimumColumn = max(1, (sy1 - sy0) / 200)
        guard let firstRow = rows.firstIndex(where: { $0 >= minimumRow }), let lastRow = rows.lastIndex(where: { $0 >= minimumRow }),
              let firstColumn = columns.firstIndex(where: { $0 >= minimumColumn }), let lastColumn = columns.lastIndex(where: { $0 >= minimumColumn }) else { return nil }
        let tight = CGRect(x: CGFloat(sx0 + firstColumn) - 1, y: CGFloat(sy0 + firstRow) - 1,
                           width: CGFloat(lastColumn - firstColumn + 1) + 2, height: CGFloat(lastRow - firstRow + 1) + 2)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        let model = CGRect(x: left, y: top, width: boxWidth, height: boxHeight)
        let overlap = tight.intersection(model)
        guard !overlap.isNull, overlap.width * overlap.height >= min(tight.width * tight.height, model.width * model.height) * 0.5 else { return nil }
        return CGRect(x: tight.minX / w, y: 1 - tight.maxY / h, width: tight.width / w, height: tight.height / h)
    }
}
