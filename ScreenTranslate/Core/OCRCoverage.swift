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
                    // A paragraph box can span characters the recognizer never
                    // read. Prefer its actual glyph evidence when available.
                    let evidence = block.sourceGlyphBoxes?.isEmpty == false ? block.sourceGlyphBoxes! : [block.boundingBox]
                    return evidence.contains { box in
                        let intersection = glyph.intersection(box)
                        return !intersection.isNull && intersection.width * intersection.height >= glyph.width * glyph.height * 0.65
                    }
                }
            }.count
            // A single final glyph can cross a document tile boundary. Requiring
            // two missing glyphs left that truncated syllable unexamined.
            return uncovered >= 1
        }.sorted { $0.count > $1.count }
    }
}
