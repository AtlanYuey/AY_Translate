import XCTest
@testable import ScreenTranslationCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Optional end-to-end check against a real OpenAI-compatible service. It is
/// skipped unless a developer points it at their own key and page:
///   AY_LIVE_KEY_FILE   file holding the API key (never the key itself)
///   AY_LIVE_BASE_URL   e.g. https://generativelanguage.googleapis.com/v1beta/openai
///   AY_LIVE_MODEL      model ID
///   AY_LIVE_PAGE_JPEG  the page as JPEG
///   AY_LIVE_PAGE_GRAY  the same page as raw 8-bit grayscale, named *-<W>x<H>.gray
///   AY_LIVE_EFFORT     optional reasoning_effort to send (none, low, …)
///   AY_LIVE_OUTPUT     optional file for the recognized/translated regions (JSON)
/// No on-device recognizer runs here: the cloud model reads the page with only
/// the locally detected, unread bubble positions as anchors (the hardest case).
final class LiveServiceTests: XCTestCase {
    func testRecognizeAndTranslateAPage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let keyFile = environment["AY_LIVE_KEY_FILE"], let base = environment["AY_LIVE_BASE_URL"], let model = environment["AY_LIVE_MODEL"],
              let jpegPath = environment["AY_LIVE_PAGE_JPEG"], let grayPath = environment["AY_LIVE_PAGE_GRAY"] else {
            throw XCTSkip("Live service check not configured")
        }
        let key = try String(contentsOfFile: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let jpeg = try Data(contentsOf: URL(fileURLWithPath: jpegPath))
        let gray = [UInt8](try Data(contentsOf: URL(fileURLWithPath: grayPath)))
        let name = URL(fileURLWithPath: grayPath).deletingPathExtension().lastPathComponent
        let size = name.split(separator: "-").last?.split(separator: "x").compactMap { Int($0) } ?? []
        guard size.count == 2, size[0] * size[1] == gray.count else { return XCTFail("Name the raster <name>-<W>x<H>.gray") }
        let width = size[0], height = size[1]
        let imageSize = CGSize(width: width, height: height)
        var configuration = AIServiceConfiguration()
        configuration.baseURL = base
        configuration.model = model
        if let effort = environment["AY_LIVE_EFFORT"] {
            configuration.requestOptions = AIRequestOptions(preset: .custom, bodyJSON: #"{"reasoning_effort":""# + effort + #""}"#)
        }
        let client = OpenAIClient()

        var clock = Date()
        let bubbles = BubbleDetector.bubbles(grayscale: gray, width: width, height: height)
        let unread = BubbleText.unreadAnchors(bubbles: bubbles, blocks: [], imageSize: imageSize)
        let local = Date().timeIntervalSince(clock)
        clock = Date()
        var result = try await client.recognize(imageData: jpeg, anchors: unread, configuration: configuration, apiKey: key,
                                                locator: InkLocator(pixels: gray, width: width, height: height))
        let recognition = Date().timeIntervalSince(clock)
        result.blocks = OCRNoise.suppress(BubbleText.assignContainers(OCRReconciler.separatingRuby(result.blocks), bubbles: bubbles, imageSize: imageSize))
        let paragraphs = TranslationPlanner.paragraphs(result.blocks, preference: .speed)
        clock = Date()
        let translations = try await client.translate(paragraphs, source: "auto-detect", target: "Simplified Chinese (zh-Hans)",
                                                      preference: .speed, configuration: configuration, apiKey: key)
        let translation = Date().timeIntervalSince(clock)

        struct Region: Encodable { let original: String; let translation: String; let box: [Double]; let overlay: Bool; let vertical: Bool; let bubble: Bool }
        let regions = paragraphs.map { block in
            Region(original: block.original, translation: translations[block.id] ?? "", box: OCRAlignment.topLeftBox(block.boundingBox).map { ($0 * 1000).rounded() / 1000 },
                   overlay: block.placement == .overlay, vertical: block.flow == .vertical, bubble: block.container != nil)
        }
        print("live: bubbles=\(bubbles.count) dialogue=\(bubbles.filter(\.isDialogue).count) unread=\(unread.count) regions=\(result.blocks.count) paragraphs=\(paragraphs.count)")
        print(String(format: "live: local=%.2fs recognize=%.2fs translate=%.2fs", local, recognition, translation))
        if let output = environment["AY_LIVE_OUTPUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(regions).write(to: URL(fileURLWithPath: output))
        }
        XCTAssertFalse(paragraphs.isEmpty)
        XCTAssertTrue(paragraphs.allSatisfy { translations[$0.id]?.isEmpty == false })
    }
}
