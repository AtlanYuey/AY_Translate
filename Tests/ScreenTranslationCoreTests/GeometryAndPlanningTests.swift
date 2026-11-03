import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import ScreenTranslationCore

final class GeometryAndPlanningTests: XCTestCase {
    private func block(_ text: String, x: Double = 0.1, y: Double = 0.8, width: Double = 0.7, height: Double = 0.04) -> RecognizedBlock {
        RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: CGRect(x: x, y: y, width: width, height: height), confidence: 0.9)
    }

    func testCoordinateOriginRoundTrip() throws {
        let original = CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1)
        let box = OCRAlignment.topLeftBox(original)
        XCTAssertEqual(box[1], 0.2, accuracy: 0.00001)
        let restored = try XCTUnwrap(OCRAlignment.visionRect(from: box))
        XCTAssertEqual(restored.minY, original.minY, accuracy: 0.00001)
        XCTAssertEqual(restored.size, original.size)
    }

    func testRejectsInvalidOrUnboundedCoordinates() {
        let invalid: [[Double]?] = [nil, [], [0, 0, 1], [-0.1, 0, 0.2, 0.1], [0.9, 0, 0.2, 0.1], [0, 0, 0, 1], [0, 0.9, 1, 0.2], [.nan, 0, 1, 1], [0, 0, .infinity, 1]]
        for box in invalid { XCTAssertNil(OCRAlignment.visionRect(from: box)) }
    }

    func testUnverifiedAICoordinatesNeverBecomeOverlays() throws {
        let result = try OCRAlignment.resolve([.init(id: nil, text: "AI only", box: [0.1, 0.1, 0.4, 0.1])], anchors: [])
        XCTAssertEqual(result.blocks.count, 1)
        XCTAssertEqual(result.blocks[0].placement, .textOnly)
        XCTAssertNotNil(result.notice)
    }

    func testIDsPreserveVerifiedGeometryDespiteWrongModelCoordinates() throws {
        let first = block("First paragraph"), second = block("Second paragraph", y: 0.4)
        let result = try OCRAlignment.resolve([
            .init(id: second.id.uuidString, text: "Second paragraph!", box: [0, 0, 1, 1]),
            .init(id: first.id.uuidString, text: "First paragraph!", box: nil)
        ], anchors: [first, second])
        XCTAssertEqual(result.blocks.map(\.id), [first.id, second.id])
        XCTAssertEqual(result.blocks.map(\.boundingBox), [first.boundingBox, second.boundingBox])
        XCTAssertEqual(result.blocks[1].original, "Second paragraph!")
    }

    func testTextAndGeometryCanRecoverMissingAnchorID() throws {
        let anchor = block("Recognized sentence")
        let result = try OCRAlignment.resolve([.init(id: nil, text: anchor.original, box: OCRAlignment.topLeftBox(anchor.boundingBox))], anchors: [anchor])
        XCTAssertEqual(result.blocks.count, 1)
        XCTAssertEqual(result.blocks.first?.id, anchor.id)
    }

    func testAmbiguousGeometryAndHallucinationsRemainTextOnly() throws {
        let anchor = block("Recognized sentence")
        let other = block(anchor.original)
        let result = try OCRAlignment.resolve([.init(id: nil, text: anchor.original, box: OCRAlignment.topLeftBox(anchor.boundingBox))], anchors: [anchor, other])
        XCTAssertEqual(result.blocks.last?.placement, .textOnly)
        let hallucination = try OCRAlignment.resolve([.init(id: anchor.id.uuidString, text: "Unrelated invented content", box: nil)], anchors: [anchor])
        XCTAssertEqual(hallucination.blocks[0].original, anchor.original)
        XCTAssertEqual(hallucination.blocks.last?.placement, .textOnly)
    }

    func testMissingAIRegionsPreserveLocalText() throws {
        let a = block("Original first"), b = block("Original second", y: 0.2)
        let result = try OCRAlignment.resolve([.init(id: a.id.uuidString, text: a.original, box: nil)], anchors: [a, b])
        XCTAssertEqual(result.blocks.map(\.original), [a.original, b.original])
    }

    func testDuplicateAndEmptyAIRegionsAreRejected() {
        let anchor = block("Original text")
        let region = AIRecognizedRegion(id: anchor.id.uuidString, text: anchor.original, box: nil)
        XCTAssertThrowsError(try OCRAlignment.resolve([region, region], anchors: [anchor]))
        XCTAssertThrowsError(try OCRAlignment.resolve([], anchors: []))
        XCTAssertThrowsError(try OCRAlignment.resolve([.init(id: nil, text: "  ", box: nil)], anchors: []))
    }

    func testWrappedSentenceIsTranslatedAsOneRegion() {
        let a = block("This is a long sentence that wraps"), b = block("onto the next line", y: 0.75)
        let grouped = TranslationPlanner.paragraphs([b, a], preference: .speed)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].original, a.original + " " + b.original)
        XCTAssertEqual(grouped[0].boundingBox, a.boundingBox.union(b.boundingBox))
        XCTAssertEqual(grouped[0].id, a.id)
    }

    func testMenusColumnsAndCompleteSentencesStaySeparate() {
        let cases: [[RecognizedBlock]] = [
            [block("Settings"), block("Account", y: 0.75)],
            [block("A sentence ends here."), block("Another paragraph", y: 0.75)],
            [block("Long text in left column", width: 0.3), block("Long text in right column", x: 0.6, y: 0.75, width: 0.3)],
            [block("A very distant sentence"), block("Not the same paragraph", y: 0.2)]
        ]
        for input in cases { XCTAssertEqual(TranslationPlanner.paragraphs(input, preference: .quality).count, 2) }
    }

    func testQualityRetainsLongerParagraphContext() {
        let lines = (0..<6).map { block("A continuation of a long sentence", y: 0.85 - Double($0) * 0.05) }
        XCTAssertEqual(TranslationPlanner.paragraphs(lines, preference: .quality).count, 1)
        XCTAssertEqual(TranslationPlanner.paragraphs(lines, preference: .speed).count, 2)
    }

    func testHyphenatedLineWrapAndTextOnlyRegions() {
        let a = block("This is a hyphenated trans-"), b = block("lation example", y: 0.75)
        let unplaced = RecognizedBlock(id: UUID(), original: "Extra", translation: "Extra", boundingBox: .zero, confidence: 0, placement: .textOnly)
        let groups = TranslationPlanner.paragraphs([a, b, unplaced], preference: .quality)
        XCTAssertEqual(groups[0].original, "This is a hyphenated translation example")
        XCTAssertEqual(groups.last?.placement, .textOnly)
    }

    func testConsecutivePinchesAccumulateAndClamp() {
        let first = ImageViewport.scale(1, magnification: 2)
        XCTAssertEqual(ImageViewport.scale(first, magnification: 1.5), 3)
        XCTAssertEqual(ImageViewport.scale(5, magnification: 3), 6)
        XCTAssertEqual(ImageViewport.scale(2, magnification: 0.1), 1)
        XCTAssertEqual(ImageViewport.scale(.nan, magnification: 2), 1)
    }

    func testChineseWrappedProseRetainsSentenceWithoutInsertedSpaces() {
        let a = block("这是一段需要保留上下文的文字"), b = block("接下来的文字属于同一句话", y: 0.75)
        let result = TranslationPlanner.paragraphs([a, b], preference: .quality)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].original, a.original + b.original)
    }

    func testPanningBoundsAndAspectFit() {
        let container = CGSize(width: 300, height: 600)
        let fitted = ImageViewport.fittedSize(image: CGSize(width: 600, height: 1200), container: container)
        XCTAssertEqual(fitted, container)
        XCTAssertEqual(ImageViewport.boundedOffset(CGSize(width: 900, height: -900), image: fitted, container: container, scale: 2), CGSize(width: 150, height: -300))
        XCTAssertEqual(ImageViewport.boundedOffset(CGSize(width: 10, height: 20), image: fitted, container: container, scale: 1), .zero)
        XCTAssertEqual(ImageViewport.fittedSize(image: .zero, container: container), .zero)
    }
}
