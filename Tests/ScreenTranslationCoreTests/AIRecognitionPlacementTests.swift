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

    private func unread(_ box: CGRect, vertical: Bool = true) -> RecognizedBlock {
        RecognizedBlock(id: UUID(), original: "", translation: "", boundingBox: box, confidence: 0, sourceLineHeight: 0.1,
                        flow: vertical ? .vertical : .horizontal, sourceColumnWidth: vertical ? box.width : nil, sourceGlyphBoxes: [box])
    }

    func testUnreadAnchorsAreFilledByPositionNotByTheIDTheModelChose() throws {
        // Two unread columns; the model swaps their IDs but boxes its readings correctly.
        let right = unread(vision(300, 40, 20, 100)), left = unread(vision(100, 40, 20, 100))
        let result = try OCRAlignment.resolve([
            .init(id: left.id.uuidString, text: "みぎの行", box: [300.0 / 400, 40.0 / 200, 20.0 / 400, 100.0 / 200]),
            .init(id: right.id.uuidString, text: "ひだりの行", box: [100.0 / 400, 40.0 / 200, 20.0 / 400, 100.0 / 200])
        ], anchors: [right, left], locator: page([]))
        XCTAssertEqual(result.blocks.first { $0.id == right.id }?.original, "みぎの行")
        XCTAssertEqual(result.blocks.first { $0.id == left.id }?.original, "ひだりの行")
        XCTAssertTrue(result.blocks.allSatisfy { $0.placement == .overlay && $0.flow == .vertical })
    }

    func testAReadingBoxedElsewhereNeverLandsInAnUnreadAnchor() throws {
        let anchor = unread(vision(300, 40, 20, 100))
        // The model names the anchor's ID for text it boxed on the other side
        // of the page, where there is real ink.
        let strokes = handwriting()
        let result = try OCRAlignment.resolve([.init(id: anchor.id.uuidString, text: "ズコー", box: [56.0 / 400, 30.0 / 200, 108.0 / 400, 50.0 / 200])],
                                              anchors: [anchor], locator: page(strokes))
        XCTAssertNil(result.blocks.first { $0.id == anchor.id }, "The unread anchor stays unread and is dropped")
        let placed = try XCTUnwrap(result.blocks.first { $0.original == "ズコー" })
        XCTAssertEqual(placed.placement, .overlay)
        XCTAssertLessThan(placed.boundingBox.maxX, 0.5)
    }

    func testTwoColumnsReadInsideOneUnreadAreaAreJoinedRightToLeft() throws {
        // Slanted handwriting clustered as one wide unread area.
        let area = unread(vision(240, 40, 70, 100))
        let result = try OCRAlignment.resolve([
            .init(id: nil, text: "だし…", box: [244.0 / 400, 60.0 / 200, 26.0 / 400, 76.0 / 200]),
            .init(id: nil, text: "もう26", box: [278.0 / 400, 42.0 / 200, 30.0 / 400, 90.0 / 200])
        ], anchors: [area], locator: page([]))
        XCTAssertEqual(result.blocks.count, 1)
        XCTAssertEqual(result.blocks[0].original, "もう26だし…")
        XCTAssertEqual(result.blocks[0].boundingBox, area.boundingBox)
    }

    func testABadlyMisreadAnchorIsCorrectedWhenTheModelBoxesTheSamePlace() throws {
        let anchor = RecognizedBlock(id: UUID(), original: "走う", translation: "走う", boundingBox: vision(280, 40, 30, 90), confidence: 0.4,
                                     flow: .vertical, sourceColumnWidth: 30.0 / 400)
        let corrected = try OCRAlignment.resolve([.init(id: anchor.id.uuidString, text: "もう26", box: [278.0 / 400, 42.0 / 200, 30.0 / 400, 86.0 / 200])], anchors: [anchor])
        XCTAssertEqual(corrected.blocks.map(\.original), ["もう26"])
        XCTAssertEqual(corrected.blocks[0].boundingBox, anchor.boundingBox)
        // Without a box (or with a box elsewhere) an unrelated text is not trusted.
        let unrelated = try OCRAlignment.resolve([.init(id: anchor.id.uuidString, text: "もう26", box: [20.0 / 400, 42.0 / 200, 30.0 / 400, 86.0 / 200])], anchors: [anchor])
        XCTAssertEqual(unrelated.blocks.first?.original, "走う")
    }

    func testHorizontalReadingAboveKanjiIsNotTranslatedSeparately() {
        let name = RecognizedBlock(id: UUID(), original: "室水有(26)", translation: "", boundingBox: CGRect(x: 0.725, y: 0.442, width: 0.146, height: 0.014),
                                   confidence: 0.9, sourceLineHeight: 0.014)
        let ruby = RecognizedBlock(id: UUID(), original: "むろみず ある", translation: "", boundingBox: CGRect(x: 0.727, y: 0.456, width: 0.107, height: 0.008),
                                   confidence: 0.9, sourceLineHeight: 0.008)
        let caption = RecognizedBlock(id: UUID(), original: "ひらがなだけ", translation: "", boundingBox: CGRect(x: 0.2, y: 0.8, width: 0.107, height: 0.014),
                                      confidence: 0.9, sourceLineHeight: 0.014)
        let result = OCRReconciler.separatingRuby([name, ruby, caption])
        XCTAssertEqual(result.map(\.placement), [.overlay, .textOnly, .overlay])
    }

    func testAReplyMissingItsFinalBracketsIsStillDecoded() throws {
        struct Output: Decodable { let regions: [AIRecognizedRegion] }
        // Exactly what Gemini's JSON mode returned for a page: the last "}" is absent.
        let dropped = #"{"regions":[{"id":null,"text":"むろさん…","box_2d":[622, 89, 668, 106]},{"id":null,"text":"ですか?","box_2d":[622, 63, 658, 81]}]"#
        XCTAssertEqual(try OpenAIClient.decodeJSONPayload(Output.self, from: dropped).regions.map(\.text), ["むろさん…", "ですか?"])
        // A reply that stopped inside an item keeps the finished items.
        let cut = #"{"regions":[{"id":"0","text":"a } \" ]","box_2d":[1,2,3,4]},{"id":"1","text":"unfinis"#
        XCTAssertEqual(try OpenAIClient.decodeJSONPayload(Output.self, from: cut).regions.map(\.text), [#"a } " ]"#])
        // A remark written after the last item, inside the object.
        let remark = #"{"regions":[{"id":null,"text":"ですか?","box_2d":[622, 62, 659, 82]}] dialogue-bubble boxes are implied by the texts inside.}"#
        XCTAssertEqual(try OpenAIClient.decodeJSONPayload(Output.self, from: remark).regions.map(\.text), ["ですか?"])
        XCTAssertEqual(OpenAIClient.closingOpenJSON(#"{"a":[1,2]}"#), [])
        XCTAssertThrowsError(try OpenAIClient.decodeJSONPayload(Output.self, from: "{\"regions\":"))
    }

    func testSlantedOrHorizontalBubbleInkIsOneHorizontalAnchor() {
        func cell(_ x: CGFloat) -> [GlyphCell] { [GlyphCell(box: CGRect(x: x, y: 0.5, width: 0.02, height: 0.02), rotate: false)] }
        XCTAssertTrue(BubbleText.isHorizontalRow([cell(0.1), cell(0.13), cell(0.16), cell(0.19)]))
        let column = (0..<4).map { GlyphCell(box: CGRect(x: 0.1, y: 0.5 - CGFloat($0) * 0.03, width: 0.02, height: 0.02), rotate: false) }
        XCTAssertFalse(BubbleText.isHorizontalRow([column, column, column]))
        XCTAssertFalse(BubbleText.isHorizontalRow([cell(0.1), cell(0.13)]))
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
