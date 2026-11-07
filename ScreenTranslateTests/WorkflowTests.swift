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
        settings.target = .chinese
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

    func testImportHasOneJournalAndKeepsTheImageBeforeRecognitionStarts() async throws {
        let journal = ProcessingDiagnostics(defaults: defaults, keys: keys, context: "share")
        var calls = 0
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: services { _, _ in calls += 1; return [self.block()] }, diagnostics: journal)
        state.beginImport()
        let id = try XCTUnwrap(journal.reports().first?.id)
        XCTAssertEqual(journal.reports().first?.stage, "importing")
        XCTAssertTrue(state.isProcessing)
        let incoming = image()
        state.displayImportedImage(incoming)
        XCTAssertTrue(state.sourceImage === incoming)
        XCTAssertEqual(calls, 0, "Present the image before starting memory-intensive OCR")
        state.process(incoming)
        try await waitUntil { state.phase == .translating }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(journal.reports().count, 1)
        XCTAssertEqual(journal.reports().first?.id, id)
        XCTAssertNotNil(journal.reports().first?.footprintBytes)
        state.closeResult()
        XCTAssertNil(state.sourceImage)
        XCTAssertNil(state.document)
    }

    func testOldMemoryWarningReportsStillDecodeAndNewOnesRecordProcessBudget() throws {
        let old = Data(#"{"id":"1CBFF70C-A1B9-470E-85C5-BA69E1628545","started":815641228.687115,"updated":815641228.721464,"context":"share","target":"zh-Hans","stage":"reading","outcome":"unfinished","event":"memory_warning","memoryWarnings":1}"#.utf8)
        let entry = try JSONDecoder().decode(ProcessingDiagnostics.Entry.self, from: old)
        XCTAssertNil(entry.footprintBytes)
        XCTAssertEqual(entry.outcome, "unfinished")
        let journal = ProcessingDiagnostics(defaults: defaults, keys: keys, context: "share")
        journal.begin(id: UUID(), target: "zh-Hans", stage: "importing")
        journal.memoryWarning()
        let current = try XCTUnwrap(journal.reports().first)
        XCTAssertGreaterThan(current.footprintBytes ?? 0, 0)
        XCTAssertNotNil(current.availableBytes)
        XCTAssertEqual(current.memoryWarnings, 1)
        XCTAssertEqual(current.outcome, "unfinished", "A warning is not proof of a process kill")
    }

    func testMemoryCheckpointsRemainBoundedAndIgnoreLatePreviousRequests() throws {
        let journal = ProcessingDiagnostics(defaults: defaults, keys: keys, context: "share")
        let first = UUID(), second = UUID()
        journal.begin(id: first, target: "zh-Hans", stage: "importing")
        for _ in 0..<30 { journal.checkpoint("document_cpu_begin", id: first) }
        let report = try XCTUnwrap(journal.reports().first)
        XCTAssertEqual(report.checkpoints?.count, 20)
        XCTAssertEqual(report.checkpoints?.first?.point, "importing")
        journal.begin(id: second, target: "zh-Hans")
        journal.checkpoint("late_old_request", id: first)
        XCTAssertFalse(journal.reports().first?.checkpoints?.contains { $0.point == "late_old_request" } ?? true)
    }

    func testReleasingHistoryCacheDoesNotLoseSavedItemsOnNextWrite() throws {
        let history = HistoryStore(fileURL: historyURL)
        func document() -> TranslationDocument { TranslationDocument(id: UUID(), image: image(), blocks: [block()], source: .english, target: .chinese, createdAt: Date()) }
        history.add(document())
        history.releaseCache()
        XCTAssertTrue(history.items.isEmpty)
        history.add(document())
        XCTAssertEqual(history.items.count, 2)
        XCTAssertEqual(HistoryStore(fileURL: historyURL).items.count, 2)
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

    func testAutomaticAppleSourceIsResolvedAndChangesBetweenScreenshots() async throws {
        settings.source = .automatic
        let english = block("This delicious cake is made with fresh fruit."), japanese = block("このケーキはとてもおいしいです。もう一口食べてもいいですか？")
        var next = english
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: services { _, _ in [next] })
        state.process(image())
        try await waitUntil { state.translationConfiguration != nil }
        XCTAssertEqual(state.translationConfiguration?.source?.languageCode?.identifier, "en")
        next = japanese
        state.process(image())
        try await waitUntil { state.translationConfiguration != nil }
        XCTAssertEqual(state.translationConfiguration?.source?.languageCode?.identifier, "ja", "Automatic screenshots must not reuse the previous screenshot’s language model")
        XCTAssertEqual(keys.readCount, 0)
        state.closeResult()
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
        XCTAssertNotNil(state.displayedDocument, "Even failed OCR must retain a displayable original image")
        XCTAssertEqual(state.displayedDocument?.image.size, image().size)
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

    func testAIImageFailureKeepsSpecificReasonAndLocalResult() async throws {
        try settings.saveConfiguration(.init(baseURL: "https://example.test/v1", model: "vision"), keyReplacement: nil, for: .ocr)
        settings.ocrEngine = .ai
        settings.grantConsent(for: .ocr)
        let journal = ProcessingDiagnostics(defaults: defaults, keys: keys, context: "share")
        let region = block()
        var injected = services { _, _ in [region] }
        injected.aiOCR = { _, _, _, _ in throw AIServiceError.http(400) }
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: injected, diagnostics: journal)
        state.process(image())
        try await waitUntil { state.phase == .translating }
        XCTAssertEqual(state.document?.blocks.first?.original, region.original)
        XCTAssertTrue(state.notice?.contains("http_400") == true)
        let entry = try XCTUnwrap(journal.reports().first)
        XCTAssertEqual(entry.ocrFallback, "http_400")
        XCTAssertNotNil(entry.processSession)
        XCTAssertNotNil(entry.version)
        XCTAssertTrue(entry.checkpoints?.contains { $0.point == "ai_ocr_begin" } == true)
        state.closeResult()
    }

    func testImageRecognitionProbeIsAnActualBoundedJPEG() throws {
        let data = try ImageRecognitionProbe.jpeg()
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(image.size, CGSize(width: 640, height: 320))
        XCTAssertLessThan(data.count, 200_000)
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

    func testSlowAIKeepsResultOpenAndUsesTheCapturedChineseTarget() async throws {
        try settings.saveConfiguration(.init(baseURL: "https://example.test/v1", model: "deepseek-chat"), keyReplacement: nil, for: .translation)
        settings.translationEngine = .ai; settings.grantConsent(for: .translation)
        let region = block("これは何ですか")
        var continuation: CheckedContinuation<[UUID: String], Never>?
        var injected = services { _, _ in [region] }
        injected.aiTranslation = { _, _, target, _, _, _ in
            XCTAssertEqual(target, .chinese)
            return await withCheckedContinuation { continuation = $0 }
        }
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: injected)
        state.process(image())
        try await waitUntil { continuation != nil }
        settings.target = .english // A later settings change is for the next image.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.isProcessing)
        XCTAssertTrue(state.presentsResult)
        XCTAssertNotNil(state.displayedDocument)
        continuation?.resume(returning: [region.id: "这是什么？"])
        try await waitUntil { state.phase == .ready }
        XCTAssertTrue(state.presentsResult)
        XCTAssertEqual(state.document?.target, .chinese)
        XCTAssertEqual(state.document?.translatedText, "这是什么？")
        state.closeResult()
    }

    func testUnexpectedRequestCancellationKeepsOriginalAndRecordsTheOutcome() async throws {
        try settings.saveConfiguration(.init(baseURL: "https://example.test/v1", model: "fixture"), keyReplacement: nil, for: .translation)
        settings.translationEngine = .ai; settings.grantConsent(for: .translation)
        let secretText = "PRIVATE_SCREEN_TEXT"
        var injected = services { _, _ in [self.block(secretText)] }
        injected.aiTranslation = { _, _, _, _, _, _ in throw CancellationError() }
        let diagnostics = ProcessingDiagnostics(defaults: defaults, keys: keys, context: "share")
        let state = AppState(settings: settings, history: HistoryStore(fileURL: historyURL), services: injected, diagnostics: diagnostics)
        state.process(image())
        try await waitUntil { if case .failed = state.phase { return true }; return false }
        XCTAssertTrue(state.presentsResult)
        XCTAssertTrue(state.hasSourceImage)
        XCTAssertEqual(state.displayedDocument?.originalText, secretText)
        let record = try XCTUnwrap(diagnostics.reports().first)
        XCTAssertEqual(record.outcome, "cancelled")
        XCTAssertEqual(record.target, "zh-Hans")
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secretText))
        XCTAssertFalse(encoded.contains("example.test"))
        state.closeResult()
    }

    func testDiagnosticJournalSurvivesUnfinishedWorkWithoutCallingItACrash() throws {
        let journal = ProcessingDiagnostics(defaults: defaults, keys: keys, context: "share")
        journal.begin(id: UUID(), target: "zh-Hans")
        journal.stage("translating"); journal.memoryWarning(); journal.event("host_disappeared")
        let reloaded = ProcessingDiagnostics(defaults: defaults, keys: keys, context: "app")
        let entry = try XCTUnwrap(reloaded.reports().first)
        XCTAssertEqual(entry.outcome, "unfinished")
        XCTAssertEqual(entry.memoryWarnings, 1)
        XCTAssertEqual(entry.event, "host_disappeared")
        journal.end("closed")
        XCTAssertEqual(reloaded.reports().first?.outcome, "closed")
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
        XCTAssertEqual(try settings.readAPIKey(for: .ocr), "")
        let persisted = String(decoding: try XCTUnwrap(defaults.data(forKey: "ai.services.v1")), as: UTF8.self)
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

    func testKeychainRoundTripUpdateAndDeletionAreIsolatedByService() throws {
        let store = KeychainStore(service: "ScreenTranslate.tests." + UUID().uuidString)
        let first = APIKeySlot.service(UUID()), second = APIKeySlot.service(UUID())
        defer { try? store.save("", for: first); try? store.save("", for: second) }
        XCTAssertEqual(try store.read(first), "")
        try store.save("test-credential-one", for: first)
        try store.save("test-credential-two", for: second)
        try store.save("updated-test-credential", for: first)
        XCTAssertEqual(try store.read(first), "updated-test-credential")
        XCTAssertEqual(try store.read(second), "test-credential-two")
        try store.save("", for: first)
        XCTAssertEqual(try store.read(first), "")
        XCTAssertEqual(try store.read(second), "test-credential-two")
    }
}

@MainActor
private final class MemoryKeys: APIKeyStoring {
    var readCount = 0
    private var values: [APIKeySlot: String] = [:]
    func read(_ profile: APIKeySlot) throws -> String { readCount += 1; return values[profile] ?? "" }
    func save(_ key: String, for profile: APIKeySlot) throws { values[profile] = key }
}
