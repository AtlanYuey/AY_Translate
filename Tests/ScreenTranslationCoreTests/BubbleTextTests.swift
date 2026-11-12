import XCTest
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import ScreenTranslationCore

final class BubbleTextTests: XCTestCase {
    private let width = 400, height = 600

    /// White page with an elliptical speech bubble outline; `fill` paints dark
    /// pixel rectangles (top-left coordinates) standing in for glyph strokes.
    private func page(center: (Int, Int) = (200, 200), radii: (Double, Double) = (70, 110), glyphs: [(Int, Int, Int, Int)]) -> [UInt8] {
        var pixels = [UInt8](repeating: 250, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let dx = Double(x - center.0) / radii.0, dy = Double(y - center.1) / radii.1
            let r = (dx * dx + dy * dy).squareRoot()
            if r >= 1 && r <= 1 + 3 / min(radii.0, radii.1) { pixels[y * width + x] = 20 }
        } }
        for (x, y, w, h) in glyphs { for yy in y..<(y + h) { for xx in x..<(x + w) { pixels[yy * width + xx] = 15 } } }
        return pixels
    }

    private var size: CGSize { CGSize(width: width, height: height) }
    private func vision(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: Double(x) / Double(width), y: 1 - Double(y + h) / Double(height), width: Double(w) / Double(width), height: Double(h) / Double(height))
    }

    // Right column "わっ": a full glyph and a small kana. Left column "ぱぱー!":
    // two glyphs, a rotated long-vowel bar, then a bar with a dot ("!").
    private let shortReplies = [(215, 140, 22, 22), (219, 168, 12, 12),
                                (172, 120, 22, 22), (172, 148, 22, 22), (181, 176, 4, 22), (181, 204, 4, 14), (181, 221, 4, 4)]

    func testDialogueBubbleIsFoundAndShortKanaColumnsAreSplitIntoCells() throws {
        let bubbles = BubbleDetector.bubbles(grayscale: page(glyphs: shortReplies), width: width, height: height)
        let bubble = try XCTUnwrap(bubbles.first { $0.holdsText })
        XCTAssertEqual(bubbles.filter(\.holdsText).count, 1)
        XCTAssertEqual(bubble.fill, Double.pi / 4, accuracy: 0.05)
        let glyph = vision(172, 120, 22, 22), area = bubble.textArea
        XCTAssertTrue(area.minX <= glyph.minX + 0.001 && area.maxX >= glyph.maxX - 0.001 && area.minY <= glyph.minY + 0.001 && area.maxY >= glyph.maxY - 0.001, "\(area)")

        let columns = BubbleText.missingColumns(in: bubble, blocks: [], imageSize: size)
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].count, 2, "わ and the small っ are separate cells")
        XCTAssertGreaterThan(columns[0][0].box.midX, columns[1][0].box.midX, "Columns are returned right to left")
        XCTAssertEqual(columns[1].map(\.rotate), [false, false, true, false], "ぱ ぱ ー(rotated) !(upright)")
        XCTAssertGreaterThan(columns[1][0].box.maxY, columns[1][1].box.maxY, "Cells run top to bottom")
    }

    func testRecognizedColumnsAreNotReadAgain() throws {
        let bubble = try XCTUnwrap(BubbleDetector.bubbles(grayscale: page(glyphs: shortReplies), width: width, height: height).first { $0.holdsText })
        let line = RecognizedBlock(id: UUID(), original: "わっ", translation: "わっ", boundingBox: vision(213, 138, 26, 44), confidence: 0.9, flow: .vertical)
        let columns = BubbleText.missingColumns(in: bubble, blocks: [line], imageSize: size)
        XCTAssertEqual(columns.count, 1)
        XCTAssertEqual(columns[0].count, 4)
    }

    func testFuriganaBesideFullSizeCharactersIsNotTreatedAsMissingText() throws {
        // A recognized kanji column with small ruby kana immediately to its right.
        let body = [(185, 120, 24, 24), (185, 150, 24, 24), (185, 180, 24, 24)]
        let ruby = [(212, 124, 9, 9), (212, 136, 9, 9), (212, 154, 9, 9)]
        let bubble = try XCTUnwrap(BubbleDetector.bubbles(grayscale: page(glyphs: body + ruby), width: width, height: height).first { $0.holdsText })
        let line = RecognizedBlock(id: UUID(), original: "図書館", translation: "図書館", boundingBox: vision(184, 119, 26, 86), confidence: 0.9, flow: .vertical)
        XCTAssertTrue(BubbleText.missingColumns(in: bubble, blocks: [line], imageSize: size).isEmpty)
    }

    func testPunctuationOnlyBubbleNeedsNoTranslation() throws {
        let dots = [(198, 150, 5, 5), (198, 162, 5, 5), (198, 174, 5, 5), (198, 194, 5, 5), (198, 206, 5, 5), (198, 218, 5, 5)]
        let bubble = try XCTUnwrap(BubbleDetector.bubbles(grayscale: page(radii: (40, 90), glyphs: dots), width: width, height: height).first { $0.holdsText })
        XCTAssertTrue(BubbleText.missingColumns(in: bubble, blocks: [], imageSize: size).isEmpty)
    }

    func testFacesAndPanelBackgroundsAreNotDialogueBubbles() {
        // A large light area surrounding another bubble's outline is not a
        // text container, and an enclosed area with one big shape is not text.
        var pixels = page(glyphs: shortReplies)
        for y in 420..<560 { for x in 60..<340 where y == 420 || y == 559 || x == 60 || x == 339 { pixels[y * width + x] = 10 } }
        for y in 460..<520 { for x in 150..<250 { pixels[y * width + x] = 30 } }
        let bubbles = BubbleDetector.bubbles(grayscale: pixels, width: width, height: height)
        XCTAssertEqual(bubbles.filter(\.holdsText).count, 1)
    }

    func testLinesInOneBubbleBecomeOneUtteranceWithoutDuplicates() {
        let container = CGRect(x: 0.3, y: 0.5, width: 0.3, height: 0.3)
        func column(_ text: String, x: Double, id: UUID = UUID()) -> RecognizedBlock {
            RecognizedBlock(id: id, original: text, translation: text, boundingBox: CGRect(x: x, y: 0.55, width: 0.04, height: 0.2),
                            confidence: 0.9, sourceLineHeight: 0.03, flow: .vertical, sourceColumnWidth: 0.04, container: container)
        }
        let right = column("無理は", x: 0.52), middle = column("しなくて", x: 0.46), left = column("…だから", x: 0.40)
        let duplicate = column("だから", x: 0.402)
        var ruby = column("としょかん", x: 0.56); ruby.placement = .textOnly
        let other = RecognizedBlock(id: UUID(), original: "わっ", translation: "わっ", boundingBox: CGRect(x: 0.8, y: 0.1, width: 0.03, height: 0.06),
                                    confidence: 0.9, flow: .vertical, container: CGRect(x: 0.78, y: 0.08, width: 0.07, height: 0.1))
        let result = TranslationPlanner.paragraphs([left, duplicate, right, middle, ruby, other], preference: .speed)
        let bubble = result.first { $0.container == container }
        XCTAssertEqual(bubble?.original, "無理はしなくて…だから", "Right-to-left columns, no repeated column")
        XCTAssertEqual(bubble?.flow, .vertical)
        XCTAssertEqual(result.filter { $0.container == container && $0.placement == .overlay }.count, 1)
        XCTAssertEqual(result.first { $0.original == "わっ" }?.container, other.container, "Separate bubbles stay separate")
        XCTAssertEqual(result.first { $0.original == "としょかん" }?.placement, .textOnly, "Ruby is never merged into the dialogue")
    }

    func testLinesAreAssignedToTheSmallestEnclosingDialogueBubble() throws {
        let bubbles = BubbleDetector.bubbles(grayscale: page(glyphs: shortReplies), width: width, height: height)
        let inside = RecognizedBlock(id: UUID(), original: "ぱぱー!", translation: "ぱぱー!", boundingBox: vision(171, 119, 24, 108), confidence: 0.9, flow: .vertical)
        let outside = RecognizedBlock(id: UUID(), original: "外", translation: "外", boundingBox: vision(20, 500, 30, 30), confidence: 0.9)
        let assigned = BubbleText.assignContainers([inside, outside], bubbles: bubbles)
        XCTAssertNotNil(assigned[0].container)
        XCTAssertNil(assigned[1].container)
    }
}

final class LetteringColourTests: XCTestCase {
    func testColouredLetteringIsSampledAndKeptReadable() throws {
        // 60 × 40 white region with brown strokes and antialiased pink fringes.
        let width = 60, height = 40
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 10..<30 { for x in 10..<50 where x % 6 < 2 {
            let i = (y * width + x) * 4
            let edge = x % 6 == 1
            pixels[i] = edge ? 220 : 158; pixels[i + 1] = edge ? 170 : 71; pixels[i + 2] = edge ? 165 : 61
        } }
        let region = CGRect(x: 0, y: 0, width: 1, height: 1)
        let background = BackgroundSampling.sample(pixels: pixels, width: width, height: height, region: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        let ink = try XCTUnwrap(BackgroundSampling.ink(pixels: pixels, width: width, height: height, region: region, background: background))
        XCTAssertEqual(ink[0], 158.0 / 255, accuracy: 0.05, "The stroke core, not its washed-out fringe")
        XCTAssertGreaterThan(ink[0] - ink[2], 0.2)
        let pale = BackgroundSampling.readableInk([0.85, 0.65, 0.62], on: background)
        XCTAssertGreaterThan(pale[0], pale[2], "Hue is preserved")
        XCTAssertLessThan(pale[0], 0.62, "Pale ink is darkened until it reads on white")
        XCTAssertTrue(BackgroundSampling.inksDiffer([0.62, 0.28, 0.24], [0.22, 0.28, 0.68]))
        XCTAssertFalse(BackgroundSampling.inksDiffer([0.62, 0.28, 0.24], [0.60, 0.30, 0.25]))
        XCTAssertFalse(BackgroundSampling.inksDiffer(nil, [0.22, 0.28, 0.68]), "Unknown colour never splits text")
        // Black or grey lettering keeps the ordinary contrast rule.
        var black = [UInt8](repeating: 255, count: width * height * 4)
        for y in 10..<30 { for x in 10..<50 where x % 6 < 2 { let i = (y * width + x) * 4; black[i] = 20; black[i + 1] = 20; black[i + 2] = 20 } }
        XCTAssertNil(BackgroundSampling.ink(pixels: black, width: width, height: height, region: region, background: background))
    }
}
