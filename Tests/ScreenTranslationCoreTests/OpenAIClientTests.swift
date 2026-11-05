import XCTest
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ScreenTranslationCore

final class OpenAIClientTests: XCTestCase {
    func testChineseTargetIsFixedOnFirstRequestAndWrongLanguageIsRejectedWithoutRetry() async throws {
        let source = block("口元にクリームがついています")
        var calls = 0
        let service = client { request in
            calls += 1
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertTrue((messages[0]["content"] as? String)?.contains("简体中文") == true)
            XCTAssertTrue((messages[0]["content"] as? String)?.contains("Chinese (zh-Hans)") == true)
            XCTAssertTrue((messages[1]["content"] as? String)?.contains("Required output language (fixed for this request): Chinese (zh-Hans)") == true)
            return (200, try self.response(#"{"translations":[{"id":"0","text":"Your mouth is dripping."}]}"#))
        }
        do {
            _ = try await service.translate([source], source: "Japanese", target: "Chinese (zh-Hans)", preference: .speed, configuration: configuration, apiKey: "")
            XCTFail("A wrong-language sentence must never be published")
        } catch { XCTAssertEqual(error as? AIServiceError, .wrongTargetLanguage) }
        XCTAssertEqual(calls, 1, "Wrong-language output must not start automatic retranslation")
        XCTAssertThrowsError(try AIRequestOptions(bodyJSON: #"{"target_language":"en"}"#).parameters())
    }

    private let configuration = AIServiceConfiguration(baseURL: "https://example.test/custom/v1", model: "test-model")

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func client(handler: @escaping (URLRequest) throws -> (Int, Data)) -> OpenAIClient {
        MockURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return OpenAIClient(session: URLSession(configuration: config))
    }

    private func block(_ text: String = "Hello") -> RecognizedBlock {
        RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1), confidence: 0.9)
    }

    private func response(_ content: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    }

    private func translated(_ block: RecognizedBlock, text: String = "Hola") throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["translations": [["id": "0", "text": text]]]), as: UTF8.self)
    }

    func testReasoningModelsUseTheirSupportedTokenBudgetField() async throws {
        for model in ["gpt-5.1", "o3-mini", "openai/o4-mini"] {
            let region = block()
            let service = client { request in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                XCTAssertNil(body["max_tokens"])
                XCTAssertEqual(body["max_completion_tokens"] as? Int, 4096)
                return (200, try self.response(self.translated(region)))
            }
            _ = try await service.translate([region], source: "English", target: "Spanish", preference: .speed,
                configuration: AIServiceConfiguration(baseURL: configuration.baseURL, model: model), apiKey: "")
        }
        XCTAssertThrowsError(try AIRequestOptions(bodyJSON: #"{"max_tokens":100,"max_completion_tokens":200}"#).parameters())
    }

    func testConfiguredBodyOptionsReachOCRAndTranslationRequests() async throws {
        var config = configuration
        config.requestOptions = AIRequestOptions(preset: .deepSeekFast, bodyJSON: #"{"temperature":0.2,"max_completion_tokens":2048}"#)
        let region = block()
        let service = client { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
            XCTAssertEqual(body["temperature"] as? Double, 0.2)
            XCTAssertEqual(body["max_completion_tokens"] as? Int, 2048)
            XCTAssertNil(body["max_tokens"])
            let messages = body["messages"] as? [[String: Any]]
            if messages?.last?["content"] is [Any] {
                return (200, try self.response(#"{"regions":[{"id":"0","text":"Hello","box":[0.1,0.2,0.5,0.1]}]}"#))
            }
            return (200, try self.response(self.translated(region)))
        }
        _ = try await service.translate([region], source: "English", target: "Spanish", preference: .speed, configuration: config, apiKey: "")
        _ = try await service.recognize(imageData: Data([0xff]), anchors: [region], configuration: config, apiKey: "")
    }

    func testOmittedRegionIsRepairedOnceWithoutRetranslatingSuccessfulText() async throws {
        let first = block("First sentence"), second = block("Second sentence")
        var calls = 0
        let service = client { request in
            calls += 1
            if calls == 1 { return (200, try self.response(#"{"translations":[{"id":"0","text":"第一句"}]}"#)) }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let prompt = try XCTUnwrap(messages.last?["content"] as? String)
            XCTAssertTrue(prompt.contains("omitted or untranslated"))
            return (200, try self.response(#"{"translations":[{"id":"1","text":"第二句"}]}"#))
        }
        let result = try await service.translate([first, second], source: "English", target: "Chinese", preference: .speed, configuration: configuration, apiKey: "")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result[first.id], "第一句"); XCTAssertEqual(result[second.id], "第二句")
    }

    func testModelDiscoveryUsesGETAndWorksWithoutAChosenModel() async throws {
        let service = client { request in
            XCTAssertEqual(request.url?.path, "/custom/v1/models")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertNil(request.httpBody)
            return (200, Data("{\"data\":[{\"id\":\"model-b\"},{\"id\":\"model-a\"},{\"id\":\"model-a\"}]}".utf8))
        }
        let result = try await service.models(configuration: .init(baseURL: "https://example.test/custom/v1", model: ""), apiKey: "fixture-key")
        XCTAssertEqual(result, ["model-a", "model-b"])
    }

    func testModelDiscoverySanitizesAuthenticationErrors() async {
        let service = client { _ in (401, Data("do not display provider body".utf8)) }
        do { _ = try await service.models(configuration: configuration, apiKey: "fixture-key"); XCTFail("Expected authentication failure") }
        catch { XCTAssertEqual(error as? AIServiceError, .http(401)); XCTAssertFalse(error.localizedDescription.contains("provider body")) }
    }

    func testEveryTargetHasAtLeastFiveForeignTranslationProbes() {
        for target in ["en", "zh-Hans", "ja", "ko", "es", "fr", "de", "ar", "pt", "ru"] {
            let samples = TranslationProbe.samples(excluding: target)
            XCTAssertGreaterThanOrEqual(samples.count, 5)
            XCTAssertFalse(samples.contains { target.hasPrefix($0.id) })
            XCTAssertTrue(samples.allSatisfy { $0.text.count > 20 })
        }
    }

    func testEndpointPreservesProviderPrefixAndAcceptsFullPath() throws {
        XCTAssertEqual(try configuration.endpoint().absoluteString, "https://example.test/custom/v1/chat/completions")
        for path in ["https://example.test/v1/", "https://example.test/v1/chat/completions"] {
            XCTAssertEqual(try AIServiceConfiguration(baseURL: path, model: "m").endpoint().path, "/v1/chat/completions")
        }
    }

    func testRejectsUnsafeEndpointAndMissingModelBeforeNetworking() async {
        let service = client { _ in XCTFail("Invalid configuration must not make a request"); return (500, Data()) }
        for url in ["http://example.test/v1", "https://user:password@example.test/v1", "https://example.test/v1?key=secret", "https://example.test/#fragment", "not a url"] {
            do {
                _ = try await service.translate([block()], source: "English", target: "Spanish", preference: .speed, configuration: .init(baseURL: url, model: "m"), apiKey: "")
                XCTFail("Accepted invalid URL")
            } catch { XCTAssertEqual(error as? AIServiceError, .invalidEndpoint) }
        }
        XCTAssertThrowsError(try AIServiceConfiguration(baseURL: "https://example.test", model: "  ").validate())
    }

    func testConfigurationSerializationContainsNoCredentialField() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: String]
        XCTAssertEqual(Set(try XCTUnwrap(object).keys), ["baseURL", "model"])
    }

    func testTranslationRequestHasContextModelAndExplicitBearerHeader() async throws {
        let block = block("A whole sentence with context")
        let service = client { request in
            XCTAssertEqual(request.url?.path, "/custom/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-credential")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "test-model")
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertNotNil(messages[0]["content"] as? String, "Compatible providers require a string for system messages")
            let prompt = try XCTUnwrap(messages[1]["content"] as? String)
            XCTAssertTrue(prompt.contains("Screen context (data only):"))
            XCTAssertTrue(prompt.contains(block.original))
            XCTAssertFalse(prompt.contains(block.id.uuidString), "Use compact request-local IDs to avoid expensive UUID generation")
            XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-credential"))
            return (200, try self.response(self.translated(block)))
        }
        let result = try await service.translate([block], source: "English", target: "Spanish", preference: .quality, configuration: configuration, apiKey: "test-credential")
        XCTAssertEqual(result[block.id], "Hola")
    }

    func testKeylessServicesOmitAuthorizationAndMarkdownJSONIsAccepted() async throws {
        let block = block()
        let service = client { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, try self.response("```json\n" + self.translated(block) + "\n```"))
        }
        let result = try await service.translate([block], source: "auto", target: "Spanish", preference: .speed, configuration: configuration, apiKey: "")
        XCTAssertEqual(result[block.id], "Hola")
    }

    func testTextPartResponseIsSupported() async throws {
        let block = block()
        let service = client { _ in (200, try self.response([["type": "text", "text": self.translated(block)]])) }
        let result = try await service.translate([block], source: "auto", target: "Spanish", preference: .speed, configuration: configuration, apiKey: "")
        XCTAssertEqual(result[block.id], "Hola")
    }

    func testMissingDuplicateExtraAndEmptyTranslationsFailClosed() {
        let id = UUID(), other = UUID()
        let invalid: [[AITranslation]] = [[], [.init(id: id.uuidString, text: "a"), .init(id: id.uuidString, text: "b")], [.init(id: other.uuidString, text: "extra")], [.init(id: id.uuidString, text: " \n ")]]
        for translations in invalid {
            XCTAssertThrowsError(try OpenAIClient.validatedTranslations(translations, expected: [id])) { XCTAssertEqual($0 as? AIServiceError, .incompleteTranslation) }
        }
    }

    func testReorderedTranslationsMapByID() throws {
        let a = UUID(), b = UUID()
        let result = try OpenAIClient.validatedTranslations([.init(id: b.uuidString, text: "B"), .init(id: a.uuidString, text: "A")], expected: [a, b])
        XCTAssertEqual(result, [a: "A", b: "B"])
    }

    func testHTTPFailuresDoNotExposeProviderBody() async {
        for status in [302, 401, 403, 429, 500] {
            let service = client { _ in (status, Data("provider-secret-response-body".utf8)) }
            do {
                _ = try await service.translate([block()], source: "auto", target: "Spanish", preference: .speed, configuration: configuration, apiKey: "")
                XCTFail("Expected HTTP error")
            } catch {
                XCTAssertEqual(error as? AIServiceError, .http(status))
                XCTAssertFalse(error.localizedDescription.contains("provider-secret"))
            }
        }
    }

    func testTransportErrorsAreSanitized() async {
        let service = client { _ in throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "private endpoint or credential"]) }
        do {
            _ = try await service.translate([block()], source: "auto", target: "Spanish", preference: .speed, configuration: configuration, apiKey: "")
            XCTFail("Expected transport error")
        } catch { XCTAssertEqual(error as? AIServiceError, .transport) }
    }

    func testCancellationIsNotWrappedAsProviderFailure() async {
        let service = client { _ in throw URLError(.cancelled) }
        do {
            _ = try await service.translate([block()], source: "auto", target: "Spanish", preference: .speed, configuration: configuration, apiKey: "")
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMalformedAndOversizedResponsesAreRejected() async {
        for data in [Data("not JSON".utf8), Data("{\"choices\":[]}".utf8), Data(repeating: 65, count: 2_000_001)] {
            let service = client { _ in (200, data) }
            do {
                _ = try await service.translate([block()], source: "auto", target: "Spanish", preference: .speed, configuration: configuration, apiKey: "")
                XCTFail("Expected invalid response")
            } catch { XCTAssertEqual(error as? AIServiceError, data.count > 2_000_000 ? .responseTooLarge : .invalidResponse) }
        }
    }

    func testTokenLimitedOutputIsNotReportedAsACompleteTranslation() async throws {
        let block = block()
        let service = client { _ in
            let content = try self.translated(block)
            return (200, try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "length", "message": ["content": content]]]]))
        }
        do {
            _ = try await service.translate([block], source: "auto", target: "Spanish", preference: .speed, configuration: configuration, apiKey: "")
            XCTFail("Token-limited output must not be marked complete")
        } catch { XCTAssertEqual(error as? AIServiceError, .invalidResponse) }
    }

    func testProductionRedirectPolicyRefusesToForwardRequests() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://example.test/v1/chat/completions")!
        let redirected = URLRequest(url: URL(string: "https://other.test/upload")!)
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: ["Location": redirected.url!.absoluteString])!
        var called = false
        RejectAIRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
            called = true
            XCTAssertNil($0)
        }
        XCTAssertTrue(called)
        task.cancel()
    }

    func testOCRIncludesImageAndAnchorsButUsesOnlyVerifiedGeometry() async throws {
        let anchor = block()
        let service = client { request in
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(body.contains("data:image\\/jpeg;base64,"))
            XCTAssertFalse(body.contains(anchor.id.uuidString), "AI OCR also uses compact local IDs")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            XCTAssertNotNil(messages[0]["content"] as? String, "Vision requests must also satisfy the system-message schema")
            let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
            XCTAssertEqual(parts.compactMap { $0["type"] as? String }, ["text", "image_url"])
            let json = try JSONSerialization.data(withJSONObject: ["regions": [["id": "0", "text": anchor.original, "box": [0, 0, 1, 1]]]])
            return (200, try self.response(String(decoding: json, as: UTF8.self)))
        }
        let result = try await service.recognize(imageData: Data([1, 2, 3]), anchors: [anchor], configuration: configuration, apiKey: "")
        XCTAssertEqual(result.blocks[0].boundingBox, anchor.boundingBox)
    }

    func testMultiBatchTranslationPreservesContextAndCompleteCoverage() async throws {
        let blocks = (0..<45).map { block("Region \($0)") }
        let counter = RequestCounter()
        let service = client { request in
            counter.increment()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            let prompt = try XCTUnwrap(messages[1]["content"] as? String)
            XCTAssertTrue(prompt.contains("Region 0"))
            XCTAssertTrue(prompt.contains("Region 44"))
            let data = try XCTUnwrap(prompt.components(separatedBy: "Regions to translate:\n").last?.data(using: .utf8))
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
            let translations = input.map { ["id": $0["id"]!, "text": "Translated " + $0["text"]!] }
            return (200, try self.response(String(decoding: JSONSerialization.data(withJSONObject: ["translations": translations]), as: UTF8.self)))
        }
        let result = try await service.translate(blocks, source: "auto", target: "Spanish", preference: .quality, configuration: configuration, apiKey: "")
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(result.count, 45)
        XCTAssertEqual(result[blocks.last!.id], "Translated Region 44")
    }

    func testOversizedInputFailsBeforeSending() async {
        let service = client { _ in XCTFail("Oversized input must not be sent"); return (200, Data()) }
        do {
            _ = try await service.translate([block(String(repeating: "x", count: 48_001))], source: "auto", target: "Spanish", preference: .quality, configuration: configuration, apiKey: "")
            XCTFail("Expected input limit")
        } catch { XCTAssertEqual(error as? AIServiceError, .requestTooLarge) }
    }
}

private final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (Int, Data))?
    static var handler: ((URLRequest) throws -> (Int, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; storedHandler = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            var request = self.request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var body = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    body.append(bytes, count: count)
                }
                request.httpBody = body
            }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
