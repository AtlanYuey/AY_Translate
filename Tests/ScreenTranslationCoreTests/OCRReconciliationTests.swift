import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import ScreenTranslationCore

final class OCRReconciliationTests: XCTestCase {
    private func block(_ text: String, x: Double = 0.2, y: Double, width: Double = 0.03, height: Double, flow: TextFlow = .vertical) -> RecognizedBlock {
        RecognizedBlock(id: UUID(), original: text, translation: text,
            boundingBox: CGRect(x: x, y: y, width: width, height: height), confidence: 0.8, flow: flow)
    }

    func testOverlappingTileFragmentsRecoverWholeSentenceInEitherOrder() {
        let first = block("明日は図書館に", y: 0.5, height: 0.21)
        let last = block("図書館に行きます", y: 0.41, height: 0.21)
        for order in [[first, last], [last, first]] {
            let result = OCRReconciler.merge(order)
            XCTAssertEqual(result.map(\.original), ["明日は図書館に行きます"])
            XCTAssertEqual(result[0].boundingBox, first.boundingBox.union(last.boundingBox))
        }
    }

    func testRepeatedTextInSeparateBubblesAndRubyAreNotDeduplicated() {
        let a = block("図書館", y: 0.7, height: 0.1)
        let b = block("図書館", y: 0.2, height: 0.1)
        let ruby = block("としょかん", x: 0.226, y: 0.7, width: 0.012, height: 0.1)
        XCTAssertEqual(OCRReconciler.merge([a, b, ruby]).count, 3)
    }

    func testStitchingHorizontalFragmentsPreservesWordSeparators() {
        let first = block("See you", x: 0.1, y: 0.7, width: 0.12, height: 0.03, flow: .horizontal)
        let last = block("you tomorrow", x: 0.16, y: 0.7, width: 0.22, height: 0.03, flow: .horizontal)
        XCTAssertEqual(OCRReconciler.merge([first, last]).map(\.original), ["See you tomorrow"])
    }

    func testIndependentReadRecoversLongMissingLineWithoutDuplicatingExistingText() {
        let known = block("一口食べますか", y: 0.5, height: 0.2)
        let duplicate = block("一口食べますか", y: 0.501, height: 0.2)
        let omitted = block("明日は図書館に行きます", x: 0.7, y: 0.1, height: 0.35)
        let result = OCRReconciler.supplement([known], with: [duplicate, omitted])
        XCTAssertEqual(Set(result.map(\.original)), [known.original, omitted.original])
        XCTAssertEqual(result.count, 2)
    }

    func testCoveredHorizontalFragmentsDoNotStackOverVerifiedColumns() {
        let a = block("こんにちは", y: 0.5, height: 0.2)
        let b = block("ありがとう", x: 0.25, y: 0.5, height: 0.2)
        var fragment = block("こあ", y: 0.67, width: 0.08, height: 0.03, flow: .horizontal)
        fragment.sourceGlyphBoxes = [CGRect(x: 0.2, y: 0.67, width: 0.03, height: 0.03), CGRect(x: 0.25, y: 0.67, width: 0.03, height: 0.03)]
        XCTAssertEqual(OCRReconciler.supplement([a, b], with: [fragment]).count, 2)
    }

    func testUnchangedOverlaySwitchDoesNotRewriteTextOrExposeUnpositionedRegions() {
        var chinese = block("请稍等", y: 0.5, height: 0.1)
        XCTAssertFalse(chinese.shouldOverlay(showUnchanged: false))
        XCTAssertTrue(chinese.shouldOverlay(showUnchanged: true))
        XCTAssertEqual(chinese.translation, "请稍等")
        chinese.placement = .textOnly
        XCTAssertFalse(chinese.shouldOverlay(showUnchanged: true))
    }

    func testRubyIsRetainedForInspectionWithoutOverlappingBodyText() {
        let body = block("図書館に行きます", x: 0.44, y: 0.2, width: 0.032, height: 0.2)
        let ruby = block("と", x: 0.47, y: 0.38, width: 0.01, height: 0.012, flow: .horizontal)
        let separate = block("はい", x: 0.65, y: 0.38, width: 0.01, height: 0.022)
        let result = OCRReconciler.separatingRuby([body, ruby, separate])
        XCTAssertEqual(result[0].placement, .overlay)
        XCTAssertEqual(result[1].placement, .textOnly)
        XCTAssertEqual(result[1].original, "と")
        XCTAssertEqual(result[2].placement, .overlay, "Small independent speech is not ruby")
        let wideCopy = block(body.original, x: 0.435, y: 0.2, width: 0.06, height: 0.2)
        XCTAssertEqual(OCRReconciler.merge([body, wideCopy]).count, 1)
    }

    func testObservationOrderDoesNotChangeWhichBubbleOrBoxSurvives() {
        let tight = block("図書館", y: 0.7, height: 0.1)
        let wide = block("図書館", x: 0.195, y: 0.7, width: 0.06, height: 0.1)
        let separate = block("図書館", y: 0.2, width: 0.04, height: 0.1)
        let expected = OCRReconciler.merge([tight, wide, separate]).map(\.boundingBox)
        for order in [[wide, tight, separate], [separate, wide, tight], [tight, separate, wide], [wide, separate, tight]] {
            XCTAssertEqual(OCRReconciler.merge(order).map(\.boundingBox), expected)
        }
    }
}
