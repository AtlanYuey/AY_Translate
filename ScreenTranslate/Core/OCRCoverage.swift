import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated enum OCRCoverage {
    /// Count individual glyph coverage. A recognized first character must not
    /// make the rest of a column disappear from the supplemental check.
    static func uncoveredColumns(_ columns: [[CGRect]], blocks: [RecognizedBlock], imageSize: CGSize) -> [[CGRect]] {
        columns.filter { column in
            guard column.count >= 3,
                  !VerticalOCRGeometry.horizontalConflicts(column: column, blocks: blocks, imageSize: imageSize).protected else { return false }
            let uncovered = column.filter { glyph in
                !blocks.contains { block in
                    guard block.flow == .vertical else { return false }
                    let intersection = glyph.intersection(block.boundingBox)
                    return !intersection.isNull && intersection.width * intersection.height >= glyph.width * glyph.height * 0.65
                }
            }.count
            return uncovered >= 2 && Double(uncovered) / Double(column.count) >= 0.25
        }.sorted { $0.count > $1.count }
    }
}
