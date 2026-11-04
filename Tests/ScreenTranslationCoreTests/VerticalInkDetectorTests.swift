import Foundation
import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import ScreenTranslationCore

final class VerticalInkDetectorTests: XCTestCase {
    func testDisconnectedKanaPartsAndVoicingMarksStayInTheirOriginalCells() {
        let width = 120, height = 180
        var pixels = [UInt8](repeating: 255, count: width * height)
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            for yy in y..<(y + h) { for xx in x..<(x + w) { pixels[yy * width + xx] = 0 } }
        }
        // First glyph is disconnected, like こ; later glyphs establish pitch.
        fill(70, 20, 16, 2); fill(70, 32, 16, 2)
        for y in [44, 68, 92] {
            fill(70, y, 16, 2); fill(70, y + 14, 16, 2)
            fill(70, y, 2, 16); fill(84, y, 2, 16)
        }
        fill(88, 90, 2, 3) // Small independent mark must not be thrown away.
        let columns = VerticalInkDetector.columns(grayscale: pixels, width: width, height: height)
        XCTAssertEqual(columns.count, 1)
        XCTAssertEqual(columns[0].count, 4)
        XCTAssertEqual(columns[0][0].minY, 1 - 34.0 / Double(height), accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(columns[0][3].maxX * CGFloat(width), 90)
    }

    func testLowContrastPictureTextureIsNotTreatedAsVerifiedTextGeometry() {
        let width = 120, height = 180
        var pixels = [UInt8](repeating: 150, count: width * height)
        for y in [20, 44, 68, 92] {
            for yy in y..<(y + 16) { for x in 70..<86 { pixels[yy * width + x] = 0 } }
        }
        XCTAssertTrue(VerticalInkDetector.columns(grayscale: pixels, width: width, height: height).isEmpty)
    }

    func testOneRecognizedCharacterDoesNotBlockTheRestOfAVerticalColumn() {
        let column = (0..<4).map { CGRect(x: 0.2, y: 0.8 - Double($0) * 0.03, width: 0.02, height: 0.02) }
        let fragment = RecognizedBlock(id: UUID(), original: "の", translation: "の", boundingBox: column[1], confidence: 0.9)
        let result = VerticalOCRGeometry.horizontalConflicts(column: column, blocks: [fragment], imageSize: CGSize(width: 1000, height: 1000))
        XCTAssertFalse(result.protected)
        XCTAssertEqual(result.fragmentedRows, [fragment.id])
    }
}
