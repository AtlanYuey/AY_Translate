import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import ScreenTranslationCore

final class ServiceAndAppearanceTests: XCTestCase {
    private func service(_ name: String, vision: Bool = true) -> SavedAIService {
        SavedAIService(name: name, configuration: .init(baseURL: "https://example.test/v1", model: "model"), supportsVision: vision)
    }

    func testMultipleNamedServicesAndIndependentSelectionsSurviveSerialization() throws {
        let a = service("日常翻译"), b = service("图像识别")
        var catalog = AIServiceCatalog()
        try catalog.upsert(a); try catalog.upsert(b)
        try catalog.select(a.id, for: .translation); try catalog.select(b.id, for: .ocr)
        let restored = try JSONDecoder().decode(AIServiceCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(restored.services.map(\.name), [a.name, b.name])
        XCTAssertEqual(restored.selected(for: .translation)?.id, a.id)
        XCTAssertEqual(restored.selected(for: .ocr)?.id, b.id)
    }

    func testSwitchingServiceDoesNotReplaceOtherSavedConfigurations() throws {
        let a = service("A"), b = service("B")
        var catalog = AIServiceCatalog()
        try catalog.upsert(a); try catalog.upsert(b)
        try catalog.select(a.id, for: .translation)
        try catalog.select(b.id, for: .translation)
        XCTAssertEqual(catalog.services, [a, b])
        try catalog.select(a.id, for: .translation)
        XCTAssertEqual(catalog.selected(for: .translation), a)
    }

    func testRemovingActiveServiceClearsOnlyItsSelections() throws {
        let a = service("A"), b = service("B")
        var catalog = AIServiceCatalog()
        try catalog.upsert(a); try catalog.upsert(b)
        try catalog.select(a.id, for: .ocr); try catalog.select(b.id, for: .translation)
        catalog.remove(a.id)
        XCTAssertNil(catalog.selected(for: .ocr))
        XCTAssertEqual(catalog.selected(for: .translation), b)
    }

    func testTextOnlyServicesCannotBeChosenForOCR() throws {
        let a = service("Text", vision: false)
        var catalog = AIServiceCatalog(); try catalog.upsert(a)
        XCTAssertThrowsError(try catalog.select(a.id, for: .ocr))
        XCTAssertNoThrow(try catalog.select(a.id, for: .translation))
    }

    func testDisablingVisionOnActiveOCRServiceClearsOCRSelection() throws {
        var a = service("Vision")
        var catalog = AIServiceCatalog(); try catalog.upsert(a); try catalog.select(a.id, for: .ocr)
        a.supportsVision = false
        try catalog.upsert(a)
        XCTAssertNil(catalog.selected(for: .ocr))
        XCTAssertEqual(catalog.services.count, 1)
    }

    func testUnknownAndInvalidServicesAreRejectedWithoutChangingCatalog() throws {
        var catalog = AIServiceCatalog()
        XCTAssertThrowsError(try catalog.select(UUID(), for: .translation))
        XCTAssertThrowsError(try catalog.upsert(service("  ")))
        XCTAssertTrue(catalog.services.isEmpty)
    }

    func testPresetsEndWithCustomFallbackAndUseCompatibleHTTPSPaths() throws {
        XCTAssertEqual(AIProviderPreset.allCases.last, .other)
        XCTAssertFalse(AIProviderPreset.deepSeek.supportsVision)
        for preset in AIProviderPreset.allCases {
            XCTAssertEqual(try AIServiceConfiguration(baseURL: preset.baseURL, model: "m").endpoint().scheme, "https")
            XCTAssertTrue(try AIServiceConfiguration(baseURL: preset.baseURL, model: "m").endpoint().path.hasSuffix("/chat/completions"))
        }
        XCTAssertEqual(AIProviderPreset.gemini.baseURL, "https://generativelanguage.googleapis.com/v1beta/openai")
    }

    func testCredentialAccountsAndConsentIdentitiesAreServiceSpecific() {
        let a = service("A"), b = service("B")
        XCTAssertNotEqual(APIKeySlot.service(a.id).account, APIKeySlot.service(b.id).account)
        XCTAssertNotEqual(a.consentID, b.consentID)
        var renamed = a; renamed.name = "Renamed"
        XCTAssertEqual(a.consentID, renamed.consentID)
        renamed.configuration.model = "new-model"
        XCTAssertNotEqual(a.consentID, renamed.consentID)
    }

    func testServiceMetadataHasNoCredentialField() throws {
        let data = try JSONEncoder().encode(service("Saved"))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(metadata["apiKey"])
        XCTAssertNil(metadata["key"])
    }

    func testExplicitInterfaceLanguageOverridesTheSystem() {
        XCTAssertEqual(InterfaceLanguage.simplifiedChinese.resolvedIdentifier(preferredLanguages: ["en-US"]), "zh-Hans")
        XCTAssertEqual(InterfaceLanguage.english.resolvedIdentifier(preferredLanguages: ["zh-CN"]), "en")
    }

    func testSystemLanguageMatchesChineseScriptsAndSupportedFallbacks() {
        for identifier in ["zh-TW", "zh-HK", "zh-Hant-CN", "zh_MO"] {
            XCTAssertEqual(InterfaceLanguage.system.resolvedIdentifier(preferredLanguages: [identifier]), "zh-Hant")
        }
        XCTAssertEqual(InterfaceLanguage.system.resolvedIdentifier(preferredLanguages: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(InterfaceLanguage.system.resolvedIdentifier(preferredLanguages: ["en-GB"]), "en")
        XCTAssertEqual(InterfaceLanguage.system.resolvedIdentifier(preferredLanguages: ["ja-JP"]), "ja")
        XCTAssertEqual(InterfaceLanguage.system.resolvedIdentifier(preferredLanguages: ["es-ES"]), "es")
        XCTAssertEqual(InterfaceLanguage.system.resolvedIdentifier(preferredLanguages: ["ko-KR"]), "ko")
        XCTAssertEqual(InterfaceLanguage.system.resolvedIdentifier(preferredLanguages: ["pl-PL"]), "en")
    }

    func testBackgroundSamplerUsesSurroundingsInsteadOfDarkGlyphPixels() {
        let width = 40, height = 40
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 15..<25 { for x in 10..<30 { let i = (y * width + x) * 4; pixels[i] = 0; pixels[i+1] = 0; pixels[i+2] = 0 } }
        let color = BackgroundSampling.sample(pixels: pixels, width: width, height: height, region: CGRect(x: 0.25, y: 0.375, width: 0.5, height: 0.25))
        XCTAssertEqual(color, SampledColor(red: 1, green: 1, blue: 1))
        XCTAssertTrue(color.usesDarkText)
    }

    func testDarkColoredBackgroundKeepsItsColorAndChoosesLightText() {
        let sample: [UInt8] = [12, 28, 55, 255]
        let pixels = Array(repeating: sample, count: 1600).flatMap { $0 }
        let color = BackgroundSampling.sample(pixels: pixels, width: 40, height: 40, region: CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.2))
        XCTAssertEqual(color.blue, 55.0 / 255, accuracy: 0.0001)
        XCTAssertFalse(color.usesDarkText)
    }

    func testSamplerClampsImageEdgesAndHandlesMissingBuffers() {
        let color = BackgroundSampling.sample(pixels: [], width: 0, height: 0, region: .zero)
        XCTAssertEqual(color, SampledColor(red: 1, green: 1, blue: 1))
        let edge = BackgroundSampling.sample(pixels: [UInt8](repeating: 255, count: 100 * 4), width: 10, height: 10, region: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        XCTAssertTrue(edge.usesDarkText)
    }

    func testVisionBottomLeftRegionsMapToTopDownBitmapRows() {
        let white: [UInt8] = [255, 255, 255, 255], blue: [UInt8] = [12, 28, 55, 255]
        let pixels = (0..<40).flatMap { row in Array(repeating: row < 20 ? white : blue, count: 40).flatMap { $0 } }
        let top = BackgroundSampling.sample(pixels: pixels, width: 40, height: 40, region: CGRect(x: 0.2, y: 0.7, width: 0.5, height: 0.1))
        let bottom = BackgroundSampling.sample(pixels: pixels, width: 40, height: 40, region: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.1))
        XCTAssertEqual(top, SampledColor(red: 1, green: 1, blue: 1))
        XCTAssertFalse(bottom.usesDarkText)
        XCTAssertEqual(bottom.blue, 55.0 / 255, accuracy: 0.0001)
    }
}
