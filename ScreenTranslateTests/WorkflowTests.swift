import XCTest
import UIKit
@testable import ScreenTranslate

@MainActor
final class WorkflowTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var keys: MemoryKeys!
    private var settings: AppSettings!
    private var historyURL: URL!

    override func setUp() async throws {
        suite = "ScreenTranslate.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        keys = MemoryKeys()
        settings = AppSettings(defaults: defaults, keyStore: keys)
        historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: historyURL.deletingLastPathComponent())
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 400, height: 160)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 160))
            ("Hello World" as NSString).draw(at: CGPoint(x: 24, y: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black])
        }
    }

    private func block(_ text: String = "Hello World") -> RecognizedBlock {
        RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.1), confidence: 1)
    }

    private func services(vision: @escaping (UIImage, AppLanguage) async throws -> [RecognizedBlock]) -> ProcessingServices {
        ProcessingServices(vision: vision, aiOCR: { _, _, _, _ in XCTFail("Cloud OCR must not run"); throw AIServiceError.transport }, aiTranslation: { _, _, _, _, _, _ in XCTFail("Cloud translation must not run"); throw AIServiceError.transport })
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Workflow did not reach the expected state")
    }

    func testDefaultAppleRouteNeedsNoKeyOrCloudAndKeepsHistoryOff() async throws {
        XCTAssertEqual(settings.ocrEngine, .appleVision)
        XCTAssertEqual(settings.translationEngine, .apple)
        XCTAssertFalse(settings.savesHistory)
        let region = block()
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: services { _, _ in [region] })
        state.process(image())
        try await waitUntil { state.translationConfiguration != nil }
        XCTAssertEqual(state.phase, .translating)
        XCTAssertEqual(state.document?.blocks.first?.original, region.original)
        XCTAssertEqual(keys.readCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
        state.closeResult()
        XCTAssertNil(state.document)
        XCTAssertFalse(state.hasSourceImage)
        XCTAssertNil(state.translationConfiguration)
    }

    func testOCRFailureCanRetryWithTheOriginalImage() async throws {
        var attempts = 0
        let region = block()
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: services { _, _ in
            attempts += 1
            if attempts == 1 { throw ScreenReadingError.noText }
            return [region]
        })
        state.process(image())
        try await waitUntil { if case .failed = state.phase { return true }; return false }
        XCTAssertTrue(state.hasSourceImage)
        XCTAssertNil(state.document)
        state.retry(using: .appleVision)
        try await waitUntil { state.phase == .translating }
        XCTAssertEqual(attempts, 2)
        XCTAssertNotNil(state.document)
        state.closeResult()
    }

    func testAIRequiresEndpointConsentBeforeAnyUploadOrKeyRead() async throws {
        try settings.saveConfiguration(.init(baseURL: "https://example.test/v1", model: "vision"), keyReplacement: nil, for: .ocr)
        settings.ocrEngine = .ai
        var uploads = 0
        let region = block()
        var injected = services { _, _ in [region] }
        injected.aiOCR = { _, anchors, _, _ in uploads += 1; return OCRResult(blocks: anchors) }
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: injected)
        state.process(image())
        XCTAssertEqual(state.phase, .awaitingConsent)
        XCTAssertEqual(uploads, 0)
        XCTAssertEqual(keys.readCount, 0)
        state.allowCloudProcessing()
        try await waitUntil { state.phase == .translating }
        XCTAssertEqual(uploads, 1)
        state.closeResult()
    }

    func testChangedEndpointCannotReceiveConsentForPreviouslyDisplayedHost() throws {
        try settings.saveConfiguration(.init(baseURL: "https://first.test/v1", model: "vision"), keyReplacement: nil, for: .ocr)
        settings.ocrEngine = .ai
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: services { _, _ in [] })
        state.process(image())
        try settings.saveConfiguration(.init(baseURL: "https://second.test/v1", model: "vision"), keyReplacement: nil, for: .ocr)
        state.allowCloudProcessing()
        XCTAssertEqual(state.phase, .awaitingConsent)
        XCTAssertFalse(settings.hasConsent(for: .ocr))
        XCTAssertTrue(state.consentDestinations.joined().contains("second.test"))
        state.closeResult()
    }

    func testClosingCancelsAndRejectsLateAITranslation() async throws {
        try settings.saveConfiguration(.init(baseURL: "https://example.test/v1", model: "translation"), keyReplacement: nil, for: .translation)
        settings.translationEngine = .ai
        settings.grantConsent(for: .translation)
        let region = block()
        var continuation: CheckedContinuation<[UUID: String], Never>?
        var injected = services { _, _ in [region] }
        injected.aiTranslation = { _, _, _, _, _, _ in await withCheckedContinuation { continuation = $0 } }
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: injected)
        state.process(image())
        try await waitUntil { continuation != nil }
        state.closeResult()
        continuation?.resume(returning: [region.id: "Late result"])
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.document)
        XCTAssertFalse(state.hasSourceImage)
        XCTAssertFalse(state.presentsResult)
    }

    func testFailedAIRecognitionFallsBackToLocalAnchors() async throws {
        try settings.saveConfiguration(.init(baseURL: "https://example.test/v1", model: "vision"), keyReplacement: nil, for: .ocr)
        settings.ocrEngine = .ai
        settings.grantConsent(for: .ocr)
        let region = block()
        var injected = services { _, _ in [region] }
        injected.aiOCR = { _, _, _, _ in throw AIServiceError.invalidResponse }
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: injected)
        state.process(image())
        try await waitUntil { state.phase == .translating }
        XCTAssertEqual(state.document?.blocks.first?.id, region.id)
        XCTAssertNotNil(state.notice)
        state.closeResult()
    }

    func testChangingProviderDuringOCRCannotSendNewKeyToOldEndpoint() async throws {
        try settings.saveConfiguration(.init(baseURL: "https://first.test/v1", model: "m"), keyReplacement: "original-test-credential", for: .translation)
        settings.translationEngine = .ai
        settings.grantConsent(for: .translation)
        let region = block()
        var continuation: CheckedContinuation<[RecognizedBlock], Never>?
        var injected = services { _, _ in await withCheckedContinuation { continuation = $0 } }
        injected.aiTranslation = { _, _, _, _, configuration, key in
            XCTAssertEqual(configuration.baseURL, "https://first.test/v1")
            XCTAssertEqual(key, "original-test-credential")
            return [region.id: "Hola"]
        }
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: injected)
        state.process(image())
        try await waitUntil { continuation != nil }
        try settings.saveConfiguration(.init(baseURL: "https://second.test/v1", model: "m"), keyReplacement: "new-test-credential", for: .translation)
        continuation?.resume(returning: [region])
        try await waitUntil { state.phase == .ready }
        XCTAssertEqual(state.document?.translatedText, "Hola")
        state.closeResult()
    }

    func testConsentAndCredentialsAreScopedToEndpointAndProfile() throws {
        let initial = AIServiceConfiguration(baseURL: "https://first.test/v1", model: "m")
        try settings.saveConfiguration(initial, keyReplacement: "test-credential", for: .ocr)
        settings.grantConsent(for: .ocr)
        XCTAssertTrue(settings.hasConsent(for: .ocr))
        XCTAssertFalse(settings.hasConsent(for: .translation))
        let updated = AIServiceConfiguration(baseURL: "https://second.test/v1", model: "m")
        try settings.saveConfiguration(updated, keyReplacement: nil, for: .ocr)
        XCTAssertFalse(settings.hasConsent(for: .ocr))
        XCTAssertEqual(try keys.read(.ocr), "")
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: "ai.ocr")), as: UTF8.self)
        XCTAssertFalse(persisted.contains("test-credential"))
    }

    func testVisionRecognizesTextFromAnActualRenderedImage() async throws {
        let blocks = try await ScreenReader.recognize(in: image(), source: .english)
        XCTAssertTrue(blocks.map(\.original).joined(separator: " ").contains("Hello"))
        XCTAssertTrue(blocks.allSatisfy { $0.boundingBox.minX >= 0 && $0.boundingBox.maxX <= 1 && $0.boundingBox.minY >= 0 && $0.boundingBox.maxY <= 1 })
    }

    func testTemporaryShortcutImageIsConsumedAndInvalidDataRemoved() throws {
        try PendingScreenshotStore.save(try XCTUnwrap(image().pngData()))
        XCTAssertNotNil(PendingScreenshotStore.take())
        XCTAssertNil(PendingScreenshotStore.take())
        try PendingScreenshotStore.save(Data("invalid-image".utf8))
        XCTAssertNil(PendingScreenshotStore.take())
        let handoff = FileManager.default.temporaryDirectory.appendingPathComponent("pending-translate-screen-image")
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoff.path))
    }

    func testKeychainRoundTripUpdateAndDeletionAreIsolatedByProfile() throws {
        let store = KeychainStore(service: "ScreenTranslate.tests." + UUID().uuidString)
        defer { try? store.save("", for: .ocr); try? store.save("", for: .translation) }
        XCTAssertEqual(try store.read(.ocr), "")
        try store.save("test-credential-one", for: .ocr)
        try store.save("test-credential-two", for: .translation)
        try store.save("updated-test-credential", for: .ocr)
        XCTAssertEqual(try store.read(.ocr), "updated-test-credential")
        XCTAssertEqual(try store.read(.translation), "test-credential-two")
        try store.save("", for: .ocr)
        XCTAssertEqual(try store.read(.ocr), "")
    }
}

@MainActor
private final class MemoryKeys: APIKeyStoring {
    var readCount = 0
    private var values: [AIProfile: String] = [:]
    func read(_ profile: AIProfile) throws -> String { readCount += 1; return values[profile] ?? "" }
    func save(_ key: String, for profile: AIProfile) throws { values[profile] = key }
}
