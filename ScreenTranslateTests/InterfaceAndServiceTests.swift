import XCTest
import SwiftUI
import UIKit
@testable import ScreenTranslate

@MainActor
final class InterfaceAndServiceTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var keys: ServiceTestKeys!
    private var settings: AppSettings!

    override func setUp() async throws {
        suite = "ScreenTranslate.interface." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        keys = ServiceTestKeys()
        settings = AppSettings(defaults: defaults, keyStore: keys)
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func service(_ name: String, url: String = "https://example.test/v1") -> SavedAIService {
        SavedAIService(name: name, configuration: .init(baseURL: url, model: "test-model"))
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 390, height: 780)).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 390, height: 390))
            UIColor(red: 0.05, green: 0.12, blue: 0.22, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 390, width: 390, height: 390))
        }
    }

    private func region() -> RecognizedBlock {
        RecognizedBlock(id: UUID(), original: "Hello World", translation: "你好，世界", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.7, height: 0.04), confidence: 1)
    }

    private func services(_ regions: [RecognizedBlock]) -> ProcessingServices {
        ProcessingServices(vision: { _, _ in regions }, aiOCR: { _, _, _, _ in XCTFail("Unexpected cloud OCR"); throw AIServiceError.transport }, aiTranslation: { _, _, _, _, _, _ in XCTFail("Unexpected cloud translation"); throw AIServiceError.transport })
    }

    func testChineseIsTheDefaultAndInterfaceLanguageIsPersistent() {
        XCTAssertEqual(settings.interfaceLanguage, .simplifiedChinese)
        settings.interfaceLanguage = .english
        XCTAssertEqual(AppSettings(defaults: defaults, keyStore: keys).interfaceLanguage, .english)
        settings.interfaceLanguage = .system
        XCTAssertEqual(AppSettings(defaults: defaults, keyStore: keys).interfaceLanguage, .system)
    }

    func testBundledInterfaceResourcesHaveRealChineseAndEnglishValues() {
        XCTAssertEqual(AppLocalization.text("Settings", language: .simplifiedChinese), "设置")
        XCTAssertEqual(AppLocalization.text("Chinese", language: .simplifiedChinese), "中文（简体）")
        XCTAssertEqual(AppLocalization.text("Show Original", language: .simplifiedChinese), "显示原图")
        XCTAssertEqual(AppLocalization.text("Settings", language: .traditionalChinese), "設定")
        XCTAssertEqual(AppLocalization.text("Settings", language: .english), "Settings")
    }

    func testSwitchingNamedProvidersRetainsTheirIndependentKeysAndConsent() throws {
        let a = service("日常"), b = service("高质量")
        try settings.saveService(a, keyReplacement: "test-key-A")
        try settings.saveService(b, keyReplacement: "test-key-B")
        try settings.selectService(a.id, for: .translation)
        settings.grantConsent(for: .translation)
        try settings.selectService(b.id, for: .translation)
        XCTAssertEqual(try settings.readAPIKey(for: .translation), "test-key-B")
        XCTAssertFalse(settings.hasConsent(for: .translation))
        try settings.selectService(a.id, for: .translation)
        XCTAssertEqual(try settings.readAPIKey(for: .translation), "test-key-A")
        XCTAssertTrue(settings.hasConsent(for: .translation))
        let restored = AppSettings(defaults: defaults, keyStore: keys)
        XCTAssertEqual(restored.serviceCatalog.services.count, 2)
        XCTAssertEqual(try restored.readAPIKey(for: .translation), "test-key-A")
    }

    func testDeletingOneServiceDoesNotRemoveAnotherCredential() throws {
        let a = service("A"), b = service("B")
        try settings.saveService(a, keyReplacement: "test-A"); try settings.saveService(b, keyReplacement: "test-B")
        try settings.selectService(a.id, for: .ocr); try settings.selectService(b.id, for: .translation)
        try settings.removeService(a.id)
        XCTAssertEqual(settings.ocrEngine, .appleVision)
        XCTAssertEqual(try keys.read(.service(a.id)), "")
        XCTAssertEqual(try settings.readAPIKey(for: .translation), "test-B")
    }

    func testEndpointChangeClearsOnlyTheEditedServicesCredential() throws {
        var a = service("A"); let b = service("B")
        try settings.saveService(a, keyReplacement: "test-A"); try settings.saveService(b, keyReplacement: "test-B")
        a.configuration.baseURL = "https://other.test/v1"
        try settings.saveService(a, keyReplacement: nil)
        XCTAssertEqual(try keys.read(.service(a.id)), "")
        XCTAssertEqual(try keys.read(.service(b.id)), "test-B")
    }

    func testLegacyProfilesMigrateWithoutLosingKeysOrConfigurations() throws {
        defaults.removeObject(forKey: "ai.catalog.initialized")
        defaults.removeObject(forKey: "ai.services.v1")
        let config = AIServiceConfiguration(baseURL: "https://legacy.test/v1", model: "legacy-model")
        defaults.set(try JSONEncoder().encode(config), forKey: "ai.ocr")
        defaults.set(try JSONEncoder().encode(config), forKey: "ai.translation")
        try keys.save("legacy-ocr-test", for: .ocr)
        try keys.save("legacy-translation-test", for: .translation)
        let migrated = AppSettings(defaults: defaults, keyStore: keys)
        XCTAssertEqual(migrated.serviceCatalog.services.count, 2)
        XCTAssertEqual(migrated.configuration(for: .ocr), config)
        XCTAssertEqual(try migrated.readAPIKey(for: .ocr), "legacy-ocr-test")
        XCTAssertEqual(try migrated.readAPIKey(for: .translation), "legacy-translation-test")
        XCTAssertEqual(try keys.read(.ocr), "")
        let data = try XCTUnwrap(defaults.data(forKey: "ai.services.v1"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("legacy-ocr-test"))
        XCTAssertEqual(AppSettings(defaults: defaults, keyStore: keys).serviceCatalog.services.count, 2)
    }

    func testLockedKeychainMigrationCanResumeWithoutErasingLegacyKey() throws {
        defaults.removeObject(forKey: "ai.catalog.initialized")
        defaults.removeObject(forKey: "ai.services.v1")
        defaults.set(try JSONEncoder().encode(AIServiceConfiguration(baseURL: "https://legacy.test/v1", model: "m")), forKey: "ai.ocr")
        try keys.save("protected-test-key", for: .ocr)
        keys.failServiceWrites = true
        let migrated = AppSettings(defaults: defaults, keyStore: keys)
        XCTAssertNotNil(migrated.serviceMigrationError)
        XCTAssertEqual(try keys.read(.ocr), "protected-test-key")
        keys.failServiceWrites = false
        XCTAssertEqual(try migrated.readAPIKey(for: .ocr), "protected-test-key")
        XCTAssertEqual(try keys.read(.ocr), "")
    }

    func testPaletteMatchesTopAndBottomImageCoordinatesWithoutGrayMaterial() throws {
        let top = region()
        let bottom = RecognizedBlock(id: UUID(), original: "Bottom", translation: "底部", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.04), confidence: 1)
        let document = TranslationDocument(id: UUID(), image: image(), blocks: [top, bottom], source: .english, target: .chinese, createdAt: Date())
        let colors = ScreenshotRendering.palette(for: document)
        XCTAssertTrue(try XCTUnwrap(colors[top.id]).usesDarkText)
        XCTAssertFalse(try XCTUnwrap(colors[bottom.id]).usesDarkText)
        XCTAssertEqual(try XCTUnwrap(colors[top.id]).red, 1, accuracy: 0.02)
        let rendered = ScreenshotRendering.translatedImage(document, palette: colors, textScale: 1)
        XCTAssertEqual(rendered.size.width, 390)
    }

    func testLightweightPreviewUsesInstalledRouteWithoutForegroundOrRepeatedOCR() async throws {
        let region = region()
        var reads = 0, translations = 0
        var injected = services([region])
        injected.vision = { _, _ in reads += 1; return [region] }
        let store = ShortcutSessionStore(settings: settings, services: injected, installedTranslator: { state in
            translations += 1
            state.completeIdentityTranslation(processID: try XCTUnwrap(state.appleRequestID))
            return true
        })
        let id = try await store.start(image())
        let session = try XCTUnwrap(store.session(id: id))
        XCTAssertEqual(session.state.phase, .ready)
        XCTAssertNotNil(session.renderedImage)
        XCTAssertNil(store.takeForegroundRequest())
        try await store.advance(id: id)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(translations, 1)
        store.clear(id: id)
        XCTAssertNil(store.session(id: id))
        XCTAssertNil(session.state.document)
        XCTAssertNil(session.renderedImage)
    }

    func testMissingLanguageModelsOffersAppContinuationWithoutDiscardingScreenshot() async throws {
        let store = ShortcutSessionStore(settings: settings, services: services([region()]), installedTranslator: { _ in false })
        let id = try await store.start(image())
        let session = try XCTUnwrap(store.session(id: id))
        XCTAssertEqual(session.continuation, .languageModels)
        XCTAssertTrue(session.state.hasSourceImage)
        store.requestForeground(id: id)
        XCTAssertTrue(store.takeForegroundRequest() === session)
        store.clear(id: id)
    }

    func testOldSnippetCannotCloseOrExposeANewerScreenshot() async throws {
        settings.source = .english; settings.target = .english
        let store = ShortcutSessionStore(settings: settings, services: services([region()]))
        let first = try await store.start(image())
        let second = try await store.start(image())
        XCTAssertNil(store.session(id: first))
        store.clear(id: first)
        XCTAssertNotNil(store.session(id: second))
        store.clear(id: second)
    }

    func testChineseFullScreenAndSettingsSnapshots() async throws {
        settings.source = .english; settings.target = .english
        let state = AppState(settings: settings, history: HistoryStore(), services: services([region()]))
        state.process(image())
        for _ in 0..<100 where state.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(state.phase, .ready)
        attach(TranslationResultView().environmentObject(state).environmentObject(settings).environmentObject(state.history), name: "中文-全屏结果-无导航栏与底栏")
        attach(NavigationStack { SettingsView() }.environmentObject(settings).environmentObject(state.history).environment(\.locale, settings.interfaceLocale), name: "中文-设置")
        let a = service("DeepSeek 日常翻译"), b = service("Gemini 图像识别")
        try settings.saveService(a, keyReplacement: nil); try settings.saveService(b, keyReplacement: nil)
        attach(NavigationStack { AIServicesView() }.environmentObject(settings).environment(\.locale, settings.interfaceLocale), name: "中文-多服务管理")
        state.closeResult()
    }

    private func attach<Content: View>(_ content: Content, name: String) {
        let renderer = ImageRenderer(content: content.frame(width: 390, height: 844))
        renderer.scale = 2
        guard let image = renderer.uiImage else { XCTFail("Snapshot rendering failed"); return }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class ServiceTestKeys: APIKeyStoring {
    private var values: [APIKeySlot: String] = [:]
    var failServiceWrites = false
    func read(_ slot: APIKeySlot) throws -> String { values[slot] ?? "" }
    func save(_ key: String, for slot: APIKeySlot) throws {
        if case .service = slot, failServiceWrites { throw KeychainError(status: -25308) }
        values[slot] = key
    }
}
