import XCTest
import UIKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
@testable import ScreenTranslate

@MainActor
final class ShareAndLanguageTests: XCTestCase {
    func testConsumingShareInputReleasesProviderFromRetainedExtensionItem() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80)).image { _ in }
        let item = NSExtensionItem()
        var provider: NSItemProvider? = NSItemProvider(item: try XCTUnwrap(image.pngData()) as NSData, typeIdentifier: UTType.png.identifier)
        weak var retainedProvider = provider
        item.attachments = [provider!]; provider = nil
        let loaded = try await SharedImageLoader.load(from: [item], consumesInput: true)
        XCTAssertNotNil(loaded.cgImage)
        XCTAssertNil(item.attachments, "A retained extension context must not retain the provider's original bitmap")
        for _ in 0..<100 where retainedProvider != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(retainedProvider)
    }

    func testHighBitDepthFileIsConvertedBeforePublishingImportedImage() throws {
        let width = 32, height = 64
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 255, count: width * height * 8) as CFData))
        let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: width * 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder16Big),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let imported = try ScreenshotInput.decode(file: url)
        XCTAssertLessThanOrEqual(try XCTUnwrap(imported.cgImage).bitsPerComponent, 8)
        XCTAssertFalse(try XCTUnwrap(imported.cgImage).bitmapInfo.contains(.floatComponents))
        XCTAssertEqual(imported.size, CGSize(width: width, height: height))
    }

    func testFileDecodeBoundsPixelsWithoutReadingEncodedDataIntoMemory() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try autoreleasepool {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 2400), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4000, height: 2400))
            }
            try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(to: url)
        }
        let image = try ScreenshotInput.decode(file: url, maximumDimension: 2560)
        XCTAssertEqual(image.cgImage?.width, 2560)
        XCTAssertEqual(image.cgImage?.height, 1536)
        XCTAssertEqual(image.imageOrientation, .up)
        XCTAssertTrue(try ScreenshotInput.bounded(image, maximumDimension: 2560) === image)
    }

    func testFinishedHostDetachesAndReleasesItsImageAcrossRepeatedInvocations() async throws {
        let parent = UIViewController()
        for _ in 0..<4 {
            weak var releasedImage: UIImage?
            var host: ResultHostingController?
            autoreleasepool {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 400)).image { _ in }
                releasedImage = image
                host = ResultHostingController(rootView: AnyView(Image(uiImage: image)))
                parent.addChild(host!)
                parent.view.addSubview(host!.view)
                host!.didMove(toParent: parent)
                host!.view.layoutIfNeeded()
                host!.releaseResult()
            }
            XCTAssertTrue(parent.children.isEmpty)
            XCTAssertNil(host?.view.superview)
            host = nil
            for _ in 0..<100 where releasedImage != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(releasedImage, "The previous screenshot must not survive into the next share")
        }
    }

    func testTargetFallbackNeverUsesAutomaticOrLosesChineseRegionalLanguage() {
        XCTAssertEqual(AppLanguage.targetLanguage(saved: "zh-Hans", preferred: "en-US"), .chinese)
        XCTAssertEqual(AppLanguage.targetLanguage(saved: "automatic", preferred: "zh-Hant-TW"), .chinese)
        XCTAssertEqual(AppLanguage.targetLanguage(saved: nil, preferred: "ja-JP"), .japanese)
    }

    func testLargeEncodedImagesAreDownsampledBeforeOCRAndKeepOrientation() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let original = UIGraphicsImageRenderer(size: CGSize(width: 3600, height: 1800), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3600, height: 1800))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 900))
        }
        let rotated = UIImage(cgImage: try XCTUnwrap(original.cgImage), scale: 1, orientation: .right)
        let decoded = try ScreenshotInput.bounded(rotated)
        XCTAssertEqual(decoded.imageOrientation, .up)
        XCTAssertGreaterThan(decoded.size.height, decoded.size.width)
        XCTAssertLessThanOrEqual(max(try XCTUnwrap(decoded.cgImage).width, try XCTUnwrap(decoded.cgImage).height), 3072)
        let fromData = try ScreenshotInput.decode(XCTUnwrap(original.jpegData(compressionQuality: 0.8)))
        XCTAssertEqual(fromData.cgImage?.width, 3072)
        XCTAssertEqual(fromData.cgImage?.height, 1536)
        XCTAssertEqual(fromData.cgImage?.bitsPerComponent, 8)
        XCTAssertTrue(try ScreenshotInput.bounded(fromData) === fromData, "Upright screenshot pixels must be reused")
    }
    func testLanguageChoicesUseTheirOwnNamesAndFollowSystemByDefault() {
        let suite = "ShareLanguages." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppSettings(defaults: defaults).interfaceLanguage, .system)
        XCTAssertEqual(InterfaceLanguage.spanish.name, "Español")
        XCTAssertEqual(InterfaceLanguage.japanese.name, "日本語")
        XCTAssertEqual(InterfaceLanguage.korean.name, "한국어")
        XCTAssertEqual(InterfaceLanguage.english.name, "English")
        XCTAssertEqual(InterfaceLanguage.arabic.name, "العربية")
    }

    func testAllLanguageChoicesContainBundledInterfaceResources() throws {
        for language in InterfaceLanguage.allCases where language != .system {
            XCTAssertNotNil(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"), language.rawValue)
            let title = AppLocalization.text("Settings", language: language)
            XCTAssertFalse(title.isEmpty)
            if language != .english { XCTAssertNotEqual(title, "Settings", language.rawValue) }
        }
    }

    func testRealImageItemProviderLoadsSharedScreenshot() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }
        let provider = NSItemProvider(item: try XCTUnwrap(image.pngData()) as NSData, typeIdentifier: UTType.png.identifier)
        let item = NSExtensionItem(); item.attachments = [provider]
        let loaded = try await SharedImageLoader.load(from: [item])
        XCTAssertEqual(loaded.cgImage?.width, image.cgImage?.width)
        XCTAssertEqual(loaded.cgImage?.height, image.cgImage?.height)
    }

    func testMissingImageAndInvalidDataFailWithoutLaunchingTranslator() async {
        do { _ = try await SharedImageLoader.load(from: []); XCTFail("Expected no-image error") }
        catch { XCTAssertEqual(error as? SharedImageError, .noImage) }
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(item: Data("invalid".utf8) as NSData, typeIdentifier: UTType.png.identifier)]
        do { _ = try await SharedImageLoader.load(from: [item]); XCTFail("Expected invalid-image error") }
        catch { XCTAssertEqual(error as? SharedImageError, .noImage) }
    }

    func testRealUIImageObjectProviderLoadsWithoutRequiringEncodedData() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }
        let item = NSExtensionItem(); item.attachments = [NSItemProvider(object: image)]
        let loaded = try await SharedImageLoader.load(from: [item])
        XCTAssertEqual(loaded.cgImage?.width, image.cgImage?.width)
        XCTAssertEqual(loaded.cgImage?.height, image.cgImage?.height)
    }

    func testSharedFileURLLoadsAnImageFromItsProvider() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try XCTUnwrap(image.pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(item: url as NSURL, typeIdentifier: UTType.png.identifier)]
        let loaded = try await SharedImageLoader.load(from: [item])
        XCTAssertEqual(loaded.cgImage?.width, image.cgImage?.width)
        XCTAssertEqual(loaded.cgImage?.height, image.cgImage?.height)
    }

    func testIPAEmbedsAShortcutsDiscoverableShareExtensionAndRequestsFullScreen() throws {
        let path = Bundle.main.bundleURL.appendingPathComponent("PlugIns/ScreenTranslateShare.appex/Info.plist")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: Any])
        let settings = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
        // UIActivityViewController also lists Action extensions. That alone
        // cannot verify compatibility with Shortcuts' “Share with App” action.
        XCTAssertEqual(settings["NSExtensionPointIdentifier"] as? String, "com.apple.share-services")
        XCTAssertEqual(settings["NSExtensionActionWantsFullScreenPresentation"] as? Bool, true)
        let attributes = try XCTUnwrap(settings["NSExtensionAttributes"] as? [String: Any])
        let activation = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? [String: Any])
        XCTAssertEqual(activation["NSExtensionActivationSupportsImageWithMaxCount"] as? Int, 1)
        let identifier = try XCTUnwrap(plist["CFBundleIdentifier"] as? String)
        XCTAssertTrue(identifier.hasPrefix(try XCTUnwrap(Bundle.main.bundleIdentifier) + "."))
        XCTAssertEqual(plist["ContainingAppBundleIdentifier"] as? String, Bundle.main.bundleIdentifier)
        XCTAssertEqual(plist["SharedAppGroup"] as? String, Bundle.main.object(forInfoDictionaryKey: "SharedAppGroup") as? String)
        XCTAssertEqual(plist["SharedKeychainGroup"] as? String, Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String)
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let shortcut = try XCTUnwrap(ShortcutInstaller.bundledFile)
        XCTAssertEqual(try Data(contentsOf: shortcut).prefix(4), Data("AEA1".utf8))
    }

    func testPreferenceMigrationDoesNotCopyUnrelatedSystemData() {
        XCTAssertTrue(SharedAppContainer.isPreferenceKey("ai.services.v1"))
        XCTAssertTrue(SharedAppContainer.isPreferenceKey("cloudConsent.translation.example"))
        XCTAssertTrue(SharedAppContainer.isPreferenceKey("interfaceLanguage"))
        XCTAssertFalse(SharedAppContainer.isPreferenceKey("AppleLanguages"))
        XCTAssertFalse(SharedAppContainer.isPreferenceKey("unrelated.private.data"))
    }

    func testApplicationContainsAnActualIcon() throws {
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertFalse((primary["CFBundleIconFiles"] as? [String] ?? []).isEmpty)
    }

    func testSpanishJapaneseAndKoreanProductTerminologyIsCorrect() {
        let terms: [(InterfaceLanguage, [String])] = [
            (.spanish, ["Ajustes", "Historial", "Guardar", "Cerrar"]),
            (.japanese, ["設定", "履歴", "保存", "閉じる"]),
            (.korean, ["설정", "기록", "저장", "닫기"])
        ]
        for (language, expected) in terms {
            XCTAssertEqual(["Settings", "History", "Save", "Close"].map { AppLocalization.text($0, language: language) }, expected)
        }
    }
}
