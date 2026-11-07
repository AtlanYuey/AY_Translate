import Foundation
import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import ScreenTranslationCore

final class VerticalInkDetectorTests: XCTestCase {
    func testLargeConnectedBlackMarginsDoNotBreakTheRemainingGlyphScan() {
        let width = 800, height = 1600
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 500..<1100 { for x in 0..<width { pixels[y * width + x] = 255 } }
        for top in [650, 684, 718, 752] {
            for y in top..<(top + 24) { for x in 390..<414 { pixels[y * width + x] = 0 } }
        }
        let columns = VerticalInkDetector.columns(grayscale: pixels, width: width, height: height)
        XCTAssertTrue(columns.contains { $0.count == 4 })
    }
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

    func testDifferentBubblesAtTheSameXKeepIndependentCharacterGrids() {
        let width = 120, height = 360
        var pixels = [UInt8](repeating: 255, count: width * height)
        for top in [20, 44, 68, 225, 249, 273] {
            for y in top..<(top + 16) {
                for x in 70..<86 where y < top + 2 || y >= top + 14 || x < 72 || x >= 84 { pixels[y * width + x] = 0 }
            }
        }
        let result = VerticalInkDetector.columns(grayscale: pixels, width: width, height: height)
        XCTAssertEqual(result.map(\.count).sorted(), [3, 3])
    }

    func testOneRecognizedCharacterDoesNotBlockTheRestOfAVerticalColumn() {
        let column = (0..<4).map { CGRect(x: 0.2, y: 0.8 - Double($0) * 0.03, width: 0.02, height: 0.02) }
        let fragment = RecognizedBlock(id: UUID(), original: "の", translation: "の", boundingBox: column[1], confidence: 0.9)
        let result = VerticalOCRGeometry.horizontalConflicts(column: column, blocks: [fragment], imageSize: CGSize(width: 1000, height: 1000))
        XCTAssertFalse(result.protected)
        XCTAssertEqual(result.fragmentedRows, [fragment.id])
    }
}
