import XCTest
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ScreenTranslationCore

final class AIRecognitionPlacementTests: XCTestCase {
    /// 400 × 200 white page, top-left rows. Draw dark "strokes" in pixel rects.
    private func page(_ strokes: [(x: Range<Int>, y: Range<Int>)], ink: UInt8 = 20, paper: UInt8 = 245) -> InkLocator {
        var pixels = [UInt8](repeating: paper, count: 400 * 200)
        for stroke in strokes { for y in stroke.y { for x in stroke.x { pixels[y * 400 + x] = ink } } }
        return InkLocator(pixels: pixels, width: 400, height: 200)!
    }

    /// Pixel rect (top-left) → Vision normalized rect (bottom-left).
    private func vision(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x / 400, y: 1 - (y + h) / 200, width: w / 400, height: h / 200)
    }

    private func handwriting() -> [(x: Range<Int>, y: Range<Int>)] {
        // Uneven strokes with gaps, like a short handwritten word.
        [(x: 60..<64, y: 40..<70), (x: 70..<100, y: 52..<56), (x: 108..<112, y: 36..<72), (x: 120..<150, y: 44..<48), (x: 156..<160, y: 50..<74)]
    }

    func testModelBoxIsTightenedToTheActualHandwrittenInk() throws {
        let locator = page(handwriting())
        // The model's box is a few pixels short on the right and too tall.
        let box = try XCTUnwrap(locator.verifiedBox(vision(56, 30, 98, 50)))
        XCTAssertEqual(box.minX * 400, 59, accuracy: 1.5)
        XCTAssertEqual(box.maxX * 400, 161, accuracy: 1.5, "A stroke just outside the model box is included")
        XCTAssertEqual((1 - box.maxY) * 200, 35, accuracy: 1.5)
        XCTAssertEqual((1 - box.minY) * 200, 75, accuracy: 1.5)
    }

    func testInvertedTextIsVerifiedToo() throws {
        let locator = page(handwriting(), ink: 240, paper: 15)
        XCTAssertNotNil(locator.verifiedBox(vision(56, 30, 98, 50)))
    }

    func testBlankOrInventedRegionsAreRejected() {
        let locator = page(handwriting())
        XCTAssertNil(locator.verifiedBox(vision(250, 100, 100, 60)), "No ink: a hallucinated region must not be painted")
        XCTAssertNil(locator.verifiedBox(vision(0, 0, 1, 1)), "Degenerate boxes are rejected")
        var faint = [UInt8](repeating: 200, count: 400 * 200)
        for y in 40..<70 { for x in 60..<160 where (x + y) % 3 == 0 { faint[y * 400 + x] = 185 } }
        XCTAssertNil(InkLocator(pixels: faint, width: 400, height: 200)!.verifiedBox(vision(56, 30, 98, 50)), "Low-contrast texture is not text evidence")
    }

    func testGeminiBox2DIsConvertedToTopLeftBoxes() throws {
        let data = Data(#"{"regions":[{"id":null,"text":"手書き","box_2d":[100,200,300,450]},{"id":1,"text":"x","box_2d":[0.1,0.2,0.3,0.45]}]}"#.utf8)
        struct Output: Decodable { let regions: [AIRecognizedRegion] }
        let regions = try JSONDecoder().decode(Output.self, from: data).regions
        for region in regions {
            let box = try XCTUnwrap(region.box)
            XCTAssertEqual(box[0], 0.2, accuracy: 0.0001); XCTAssertEqual(box[1], 0.1, accuracy: 0.0001)
            XCTAssertEqual(box[2], 0.25, accuracy: 0.0001); XCTAssertEqual(box[3], 0.2, accuracy: 0.0001)
        }
        XCTAssertEqual(regions[1].id, "1")
        XCTAssertNil(AIRecognizedRegion.normalizedBox2D([10, 10, 10, 20]), "Zero-height boxes are invalid")
    }

    func testAIOnlyHandwritingIsOverlaidOnlyWhereInkIsConfirmed() throws {
        let locator = page(handwriting() + [(x: 260..<330, y: 140..<150)])
        let anchor = RecognizedBlock(id: UUID(), original: "Printed", translation: "Printed", boundingBox: vision(255, 135, 80, 20), confidence: 0.9)
        func topLeft(_ rect: CGRect) -> [Double] { OCRAlignment.topLeftBox(rect).map { Double($0) } }
        let regions = [
            AIRecognizedRegion(id: anchor.id.uuidString, text: "Printed", box: topLeft(anchor.boundingBox)),
            AIRecognizedRegion(id: nil, text: "handwritten note", box: topLeft(vision(56, 30, 98, 50))),
            AIRecognizedRegion(id: nil, text: "invented", box: topLeft(vision(250, 20, 100, 40))),
            AIRecognizedRegion(id: nil, text: "Printed again", box: topLeft(vision(258, 137, 74, 16)))
        ]
        let result = try OCRAlignment.resolve(regions, anchors: [anchor], locator: locator)
        let handwritten = try XCTUnwrap(result.blocks.first { $0.original == "handwritten note" })
        XCTAssertEqual(handwritten.placement, .overlay)
        XCTAssertEqual(handwritten.flow, .horizontal)
        XCTAssertGreaterThan(handwritten.boundingBox.maxX * 400, 158)
        XCTAssertEqual(result.blocks.first { $0.original == "invented" }?.placement, .textOnly)
        XCTAssertEqual(result.blocks.first { $0.original == "Printed again" }?.placement, .textOnly, "Never paint known text twice")
        XCTAssertEqual(result.blocks.filter { $0.placement == .overlay }.count, 2)
        XCTAssertNotNil(result.notice)
    }

    func testVerticalHandwritingKeepsColumnGeometry() throws {
        var pixels = [UInt8](repeating: 250, count: 400 * 400)
        for row in 0..<6 { for y in (40 + row * 50)..<(70 + row * 50) { for x in 200..<230 where (x + y) % 2 == 0 || x % 7 == 0 { pixels[y * 400 + x] = 10 } } }
        let locator = try XCTUnwrap(InkLocator(pixels: pixels, width: 400, height: 400))
        let box = CGRect(x: 195.0 / 400, y: 1 - 345.0 / 400, width: 40.0 / 400, height: 310.0 / 400)
        let result = try OCRAlignment.resolve([AIRecognizedRegion(id: nil, text: "ありがとうね", box: OCRAlignment.topLeftBox(box).map { Double($0) })],
                                              anchors: [], locator: locator)
        let block = try XCTUnwrap(result.blocks.first)
        XCTAssertEqual(block.placement, .overlay)
        XCTAssertEqual(block.flow, .vertical)
        XCTAssertEqual(block.originalColumnWidth * 400, 31, accuracy: 3)
    }

    func testGeminiRequestSendsAnchorsInItsNativeBoxFormat() async throws {
        let anchor = RecognizedBlock(id: UUID(), original: "Hi", translation: "Hi",
            boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1), confidence: 1)
        let captured = CapturedText()
        PlacementMockProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            captured.value = ((body?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
            let content = #"{"regions":[{"id":0,"text":"Hi!","box_2d":[200,100,300,600]}]}"#
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        }
        defer { PlacementMockProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlacementMockProtocol.self]
        let client = OpenAIClient(session: URLSession(configuration: config))
        let result = try await client.recognize(imageData: Data([1]), anchors: [anchor],
            configuration: .init(baseURL: AIProviderPreset.gemini.baseURL, model: "gemini-3.8-flash"), apiKey: "")
        XCTAssertTrue(captured.value.contains("box_2d"))
        XCTAssertTrue(captured.value.contains("[200,100,300,600]"), captured.value)
        XCTAssertTrue(captured.value.contains("handwriting"))
        XCTAssertEqual(result.blocks.map(\.original), ["Hi!"])
        XCTAssertEqual(result.blocks.first?.boundingBox, anchor.boundingBox, "Anchored text keeps the verified local geometry")
    }
}

private final class CapturedText: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private final class PlacementMockProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
            request.httpBody = body
        }
        do {
            let data = try Self.handler?(request) ?? Data()
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
