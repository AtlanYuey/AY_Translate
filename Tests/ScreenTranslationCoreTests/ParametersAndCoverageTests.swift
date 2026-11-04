import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import ScreenTranslationCore

final class ParametersAndCoverageTests: XCTestCase {
    func testOldServicesDecodeWithoutChangingModelDefaults() throws {
        let old = Data(#"{"baseURL":"https://example.test/v1","model":"m"}"#.utf8)
        let configuration = try JSONDecoder().decode(AIServiceConfiguration.self, from: old)
        XCTAssertNil(configuration.requestOptions)
        XCTAssertTrue(try AIRequestOptions().parameters().isEmpty)
    }
    func testPresetsAndNestedCustomJSONUseTypedValues() throws {
        let options = AIRequestOptions(preset: .deepSeekFast, bodyJSON: #"{"temperature":0.2,"max_completion_tokens":4096,"thinking":{"type":"enabled"}}"#)
        let values = try options.parameters()
        XCTAssertEqual((values["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(values["temperature"] as? Double, 0.2)
        XCTAssertEqual(values["max_completion_tokens"] as? Int, 4096)
        XCTAssertEqual(try AIRequestOptions(preset: .openAINone).parameters()["reasoning_effort"] as? String, "none")
        XCTAssertEqual(try AIRequestOptions(preset: .qwenFast).parameters()["enable_thinking"] as? Bool, false)
    }
    func testInvalidOrPromptOverridingParametersAreRejected() {
        for text in ["[]", "broken", #"{"messages":[]}"#, #"{"stream":true}"#, #"{"api_key":"not-allowed"}"#] {
            XCTAssertThrowsError(try AIRequestOptions(bodyJSON: text).parameters(), text)
        }
    }
    func testCoverageChecksTheMissingRestOfAColumnAndKeepsCompleteColumns() {
        let column = (0..<5).map { CGRect(x: 0.1, y: 0.8 - Double($0) * 0.04, width: 0.025, height: 0.03) }
        let partial = RecognizedBlock(id: UUID(), original: "あ", translation: "あ", boundingBox: column[0], confidence: 1, flow: .vertical)
        XCTAssertEqual(OCRCoverage.uncoveredColumns([column], blocks: [partial], imageSize: CGSize(width: 1000, height: 1000)).count, 1)
        let complete = RecognizedBlock(id: partial.id, original: "あいうえお", translation: "あいうえお", boundingBox: column.reduce(.null) { $0.union($1) }, confidence: 1, flow: .vertical)
        XCTAssertTrue(OCRCoverage.uncoveredColumns([column], blocks: [complete], imageSize: CGSize(width: 1000, height: 1000)).isEmpty)
    }
    func testTranslationCoverageDoesNotRetryNumbersChineseOrNames() {
        XCTAssertTrue(TranslationCoverage.needsRetry(original: "一口だけです", translation: "一口だけです", target: "Chinese"))
        XCTAssertFalse(TranslationCoverage.needsRetry(original: "一口だけです", translation: "只吃一口", target: "Chinese"))
        for text in ["1234", "中文原文", "カノウ"] { XCTAssertFalse(TranslationCoverage.needsRetry(original: text, translation: text, target: "Chinese")) }
        XCTAssertFalse(TranslationCoverage.needsRetry(original: "一口だけです", translation: "一口だけです", target: "Japanese"))
    }
    func testAntialiasedStrokeEdgesDisappearWithoutChangingCleanBackground() {
        let width = 60, height = 60
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 15..<40 { for x in 28...32 { for c in 0..<3 { pixels[(y * width + x) * 4 + c] = x == 28 || x == 32 ? 220 : 5 } } }
        let result = TextInkRestoration.restore(pixels: pixels, width: width, height: height, glyphs: [CGRect(x: 24, y: 10, width: 16, height: 35)], glyphSize: 20)
        XCTAssertGreaterThan(result.pixels[(25 * width + 28) * 4], 245)
        XCTAssertGreaterThan(result.pixels[(25 * width + 30) * 4], 245)
        XCTAssertEqual(result.pixels[(25 * width + 25) * 4], 255)
    }
}
