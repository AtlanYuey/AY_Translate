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

    func testSystemLanguageIsTheDefaultAndSelectionIsPersistent() {
        XCTAssertEqual(settings.interfaceLanguage, .system)
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

    func testLandscapeMenuKeepsTitleAndSmallBodyAtTheirOriginalRelativeSizes() {
        let imageSize = CGSize(width: 2048, height: 1152)
        let canvas = ImageViewport.fittedSize(image: imageSize, container: CGSize(width: 393, height: 852))
        let body = RecognizedBlock(id: UUID(), original: "YOGUR O FRUTA", translation: "酸奶或水果",
                                   boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 20 / 1152.0), confidence: 1)
        let title = RecognizedBlock(id: UUID(), original: "MENU SEMANA", translation: "每周菜单",
                                    boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 40 / 1152.0), confidence: 1)
        let bodyLayout = ScreenshotRendering.textLayout(for: body, canvasSize: canvas, textScale: 1)
        let titleLayout = ScreenshotRendering.textLayout(for: title, canvasSize: canvas, textScale: 1)
        XCTAssertLessThan(bodyLayout.fontSize, 6, "Zoomed-out photo text must not be inflated to a 12pt minimum")
        XCTAssertEqual(titleLayout.fontSize / bodyLayout.fontSize, 2, accuracy: 0.15)
        XCTAssertEqual(bodyLayout.sourceRect.height, 20 * canvas.width / imageSize.width, accuracy: 0.0001)
        let largerCanvas = CGSize(width: canvas.width * 2, height: canvas.height * 2)
        XCTAssertEqual(ScreenshotRendering.textLayout(for: body, canvasSize: largerCanvas, textScale: 1).fontSize,
                       bodyLayout.fontSize * 2, accuracy: 0.1)
    }

    func testLongTranslationFitsRelativeToSourceBeforeApplyingUserMultiplier() {
        var block = region()
        block.translation = String(repeating: "这段译文保留上下文。", count: 5)
        let canvas = CGSize(width: 390, height: 780)
        let short = ScreenshotRendering.textLayout(for: block, canvasSize: canvas, textScale: 1, text: "你好")
        let normal = ScreenshotRendering.textLayout(for: block, canvasSize: canvas, textScale: 1)
        let enlarged = ScreenshotRendering.textLayout(for: block, canvasSize: canvas, textScale: 1.6)
        let reduced = ScreenshotRendering.textLayout(for: block, canvasSize: canvas, textScale: 0.8)
        XCTAssertLessThan(normal.fontSize, short.fontSize)
        XCTAssertGreaterThanOrEqual(normal.fontSize, short.fontSize * 0.70)
        XCTAssertEqual(enlarged.fontSize, normal.fontSize * 1.6, accuracy: 0.0001)
        XCTAssertEqual(reduced.fontSize, normal.fontSize * 0.8, accuracy: 0.0001)
        XCTAssertEqual(enlarged.sourceRect, normal.sourceRect, "Font scaling must not enlarge the original cover region")
    }

    func testJoinedParagraphKeepsItsOriginalLineSizeInBothRenderers() {
        let first = RecognizedBlock(id: UUID(), original: "This is a sentence wrapping", translation: "内容",
                                    boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.7, height: 0.02), confidence: 1)
        let second = RecognizedBlock(id: UUID(), original: "onto the next line", translation: "内容",
                                     boundingBox: CGRect(x: 0.1, y: 0.775, width: 0.7, height: 0.02), confidence: 1)
        var paragraph = TranslationPlanner.paragraphs([first, second], preference: .quality)[0]
        paragraph.translation = "内容"
        let canvas = CGSize(width: 390, height: 844)
        let line = ScreenshotRendering.textLayout(for: first, canvasSize: canvas, textScale: 1)
        let joined = ScreenshotRendering.textLayout(for: paragraph, canvasSize: canvas, textScale: 1)
        XCTAssertEqual(joined.fontSize, line.fontSize, accuracy: 0.0001)
        XCTAssertGreaterThan(joined.sourceRect.height, line.sourceRect.height * 2)
    }

    func testRealVisionKeepsLargeTitleAndSmallBodySizesInALandscapePhoto() async throws {
        let size = CGSize(width: 2048, height: 1152)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            ("MENU SEMANA" as NSString).draw(at: CGPoint(x: 400, y: 140), withAttributes: [
                .font: UIFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: UIColor.black
            ])
            ("YOGUR O FRUTA" as NSString).draw(at: CGPoint(x: 200, y: 420), withAttributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: UIColor.black
            ])
        }
        let recognized = try await ScreenReader.recognize(in: image, source: .spanish)
        var title = try XCTUnwrap(recognized.first { $0.original.contains("MENU") })
        var body = try XCTUnwrap(recognized.first { $0.original.contains("YOGUR") })
        title.translation = "每周菜单"; body.translation = "酸奶水果"
        let canvas = ImageViewport.fittedSize(image: size, container: CGSize(width: 393, height: 852))
        let large = ScreenshotRendering.textLayout(for: title, canvasSize: canvas, textScale: 1)
        let small = ScreenshotRendering.textLayout(for: body, canvasSize: canvas, textScale: 1)
        XCTAssertGreaterThan(large.fontSize / small.fontSize, 1.7)
        XCTAssertLessThan(small.fontSize, 6)
        let document = TranslationDocument(id: UUID(), image: image, blocks: [title, body], source: .spanish, target: .chinese, createdAt: Date())
        for (name, screenshot) in [("横屏原图-44与22字号", image),
                                    ("横屏译图-保留标题正文比例", ScreenshotRendering.translatedImage(document, palette: [:], textScale: 1))] {
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testChineseFullScreenAndSettingsSnapshots() async throws {
        executionTimeAllowance = 120
        settings.interfaceLanguage = .simplifiedChinese
        settings.source = .english; settings.target = .chinese
        let fixture = snapshotFixture()
        let provider = service("本地测试替身")
        try settings.saveService(provider, keyReplacement: nil)
        try settings.selectService(provider.id, for: .translation)
        settings.grantConsent(for: .translation)
        var injected = services(fixture.blocks)
        injected.aiTranslation = { blocks, _, _, _, _, _ in
            Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, fixture.translations[$0.id]!) })
        }
        let state = AppState(settings: settings, history: HistoryStore(), services: injected)
        state.process(fixture.image)
        for _ in 0..<100 where state.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.document?.blocks.count, fixture.blocks.count)
        try settings.removeService(provider.id)
        await attach(TranslationResultView().environmentObject(state).environmentObject(settings).environmentObject(state.history), name: "中文-全屏结果-无导航栏与底栏")
        await attach(NavigationStack { SettingsView() }.environmentObject(settings).environmentObject(state.history).environment(\.locale, settings.interfaceLocale), name: "中文-设置")
        await attach(NavigationStack { SettingsView() }.environmentObject(settings).environmentObject(state.history).environment(\.locale, settings.interfaceLocale).preferredColorScheme(.dark), name: "中文-深色设置")
        let a = SavedAIService(name: "DeepSeek 日常翻译", preset: .deepSeek, configuration: .init(baseURL: AIProviderPreset.deepSeek.baseURL, model: "deepseek-chat"))
        let b = SavedAIService(name: "Gemini 图像识别", preset: .gemini, configuration: .init(baseURL: AIProviderPreset.gemini.baseURL, model: "gemini-2.5-flash"))
        try settings.saveService(a, keyReplacement: nil); try settings.saveService(b, keyReplacement: nil)
        await attach(NavigationStack { AIServicesView() }.environmentObject(settings).environment(\.locale, settings.interfaceLocale).preferredColorScheme(.dark), name: "中文-多服务管理")
        await attach(NavigationStack { AIServiceEditor(service: b) }.environmentObject(settings).environment(\.locale, settings.interfaceLocale).preferredColorScheme(.dark), name: "中文-自定义服务名称与接口")
        for language in [InterfaceLanguage.spanish, .japanese, .korean] {
            settings.interfaceLanguage = language
            await attach(NavigationStack { SettingsView() }.environmentObject(settings).environmentObject(state.history).environment(\.locale, settings.interfaceLocale), name: language.name + "-设置")
        }
        state.closeResult()
    }

    private func snapshotFixture() -> (image: UIImage, blocks: [RecognizedBlock], translations: [UUID: String]) {
        let lines: [(String, String, CGFloat, CGFloat)] = [
            ("A clearer view", "看见，即理解", 110, 30),
            ("Translate with context, keep the layout.", "理解上下文，保留原有布局。", 178, 16),
            ("On-device by default:", "默认在设备本地处理", 290, 23),
            ("Free. No account. No ads.", "免费使用，无需账号，没有广告。", 344, 16),
            ("Your providers, your choice:", "服务由你自由选择", 592, 24),
            ("Keep multiple AI services ready.", "保存多个 AI 服务，随点随用。", 650, 16)
        ]
        var blocks: [RecognizedBlock] = [], translations: [UUID: String] = [:]
        let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844)).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
            UIColor(red: 0.05, green: 0.12, blue: 0.22, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 480, width: 390, height: 364))
            for (original, translated, y, size) in lines {
                let rect = CGRect(x: 24, y: y, width: 342, height: size * 1.5)
                (original as NSString).draw(in: rect, withAttributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: .medium),
                    .foregroundColor: y < 480 ? UIColor.black : UIColor.white
                ])
                let block = RecognizedBlock(id: UUID(), original: original, translation: original,
                    boundingBox: CGRect(x: rect.minX / 390, y: 1 - rect.maxY / 844, width: rect.width / 390, height: rect.height / 844), confidence: 1)
                blocks.append(block); translations[block.id] = translated
            }
        }
        return (image, blocks, translations)
    }

    private func attach<Content: View>(_ content: Content, name: String) async {
        // Hosting in a real window also captures List/Form/NavigationStack, whose
        // UIKit-backed views aren't drawn by SwiftUI's ImageRenderer.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previousWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let window: UIWindow
        if let scene = previousWindow?.windowScene ?? scenes.first { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(250))
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        var drawn = false
        let image = renderer.image { _ in drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertTrue(drawn, "The native window must render successfully for interface review")
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
