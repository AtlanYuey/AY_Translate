import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import ScreenTranslationCore

final class RestorationAndSyncTests: XCTestCase {
    func testSigningProfileDiagnosticDistinguishesMissingPermissionFromUnknownProfile() throws {
        for allowed in [false, true] {
            let entitlements: [String: Any] = allowed ? ["com.apple.developer.ubiquity-kvstore-identifier": "TEAM.example.app"] : [:]
            let plist = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": entitlements], format: .xml, options: 0)
            let cmsLike = Data([0x30, 0x82, 0xff]) + plist + Data([0, 0])
            XCTAssertEqual(SigningCapabilities.permitsCloudSettings(profile: cmsLike), allowed)
        }
        XCTAssertNil(SigningCapabilities.permitsCloudSettings(profile: Data("unknown".utf8)))
        XCTAssertNil(try CloudSettingsRecord(value: "automatic", timestamp: 10, device: "test").decodedValue(for: "defaultTargetLanguage"))
    }
    func testResizingARepairDoesNotRevealSourceInkThroughTransparentEdges() {
        for background: UInt8 in [255, 30] {
            var source = [UInt8](repeating: background, count: 9 * 9 * 4)
            for i in stride(from: 3, to: source.count, by: 4) { source[i] = 255 }
            let ink = (4 * 9 + 4) * 4, cleanNeighbor = ink + 4, otherInk = ink + 8
            for c in 0..<3 { source[ink + c] = 255 - background; source[otherInk + c] = 255 - background }
            var repaired = source
            for c in 0..<3 { repaired[ink + c] = background }
            let patch = TextInkRestoration.Patch(pixels: repaired, width: 9, height: 9, changedPixels: 1)
            let overlay = TextInkRestoration.compositingPixels(original: source, patch: patch)
            // Linear resampling between repaired ink and clean background,
            // followed by premultiplied-alpha compositing over resized source.
            let sourceSample = (Double(source[ink]) + Double(source[cleanNeighbor])) / 2
            let overlaySample = (Double(overlay[ink]) + Double(overlay[cleanNeighbor])) / 2
            let alpha = (Double(overlay[ink + 3]) + Double(overlay[cleanNeighbor + 3])) / 510
            XCTAssertEqual(overlaySample + sourceSample * (1 - alpha), Double(background), accuracy: 0.01)
            XCTAssertEqual(overlay[otherInk + 3], 0, "Do not repaint another region's original ink")
            XCTAssertEqual(overlay[3], 0, "Do not make the whole sampling rectangle opaque")
        }
    }

    func testRestoresInkWithoutFlatteningUnderlyingGradientOrUntouchedArtwork() {
        let w = 80, h = 60
        var source = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            for c in 0..<3 { source[(y * w + x) * 4 + c] = UInt8(170 + x / 2) }
        } }
        let original = source
        for y in 15..<40 { for x in 34..<37 { for c in 0..<3 { source[(y * w + x) * 4 + c] = 10 } } }
        let patch = TextInkRestoration.restore(pixels: source, width: w, height: h,
            glyphs: [CGRect(x: 30, y: 10, width: 14, height: 35)], glyphSize: 16)
        XCTAssertGreaterThan(patch.changedPixels, 60)
        XCTAssertGreaterThan(patch.pixels[(24 * w + 35) * 4], 140)
        for y in 0..<h { for x in 0..<w where x < 30 || x > 44 || y < 10 || y > 45 {
            XCTAssertEqual(patch.pixels[(y * w + x) * 4], original[(y * w + x) * 4])
        } }
        XCTAssertNotEqual(patch.pixels[(24 * w + 31) * 4], patch.pixels[(24 * w + 43) * 4], "Preserve background gradient rather than one flat fill")
    }

    func testRestoresWhiteInkOnDarkBackgroundWithoutBlackRectangle() {
        let w = 60, h = 60
        var source = [UInt8](repeating: 30, count: w * h * 4)
        for i in stride(from: 3, to: source.count, by: 4) { source[i] = 255 }
        for y in 18..<40 { for x in 28..<31 { for c in 0..<3 { source[(y * w + x) * 4 + c] = 250 } } }
        let patch = TextInkRestoration.restore(pixels: source, width: w, height: h, glyphs: [CGRect(x: 24, y: 12, width: 14, height: 32)], glyphSize: 14)
        XCTAssertLessThan(patch.pixels[(25 * w + 29) * 4], 70)
        XCTAssertEqual(patch.pixels[(10 * w + 10) * 4], 30)
    }

    func testCloudRecordsExcludeCredentialsConsentAndHistoryAndResolveConflicts() throws {
        let old = try CloudSettingsRecord(value: "ja", timestamp: 100, device: "a")
        let new = try CloudSettingsRecord(value: "es", timestamp: 101, device: "b")
        XCTAssertTrue(new.isNewer(than: old))
        XCTAssertFalse(old.isNewer(than: new))
        XCTAssertEqual(new.decodedValue(for: "defaultSourceLanguage") as? String, "es")
        for key in ["APIKey", "cloudConsent.translation", "saveTranslationHistory", "translation-history.json", "iCloudSyncEnabled"] {
            XCTAssertNil(new.decodedValue(for: key))
        }
        let invalidCatalog = try CloudSettingsRecord(value: Data("bad json".utf8), timestamp: 101, device: "b")
        XCTAssertNil(invalidCatalog.decodedValue(for: "ai.services.v1"))
    }

    func testShortVerticalTranslationUsesBalancedColumnsAndCentersInOccupiedArea() {
        let layout = VerticalTextLayout(text: "有趣的形状。要尝一口吗？", size: CGSize(width: 62, height: 180), preferred: 20, scale: 1)
        XCTAssertTrue(layout.fits)
        XCTAssertGreaterThan(layout.glyphs.first!.center.y, 20)
        let columns = Dictionary(grouping: layout.glyphs, by: { $0.center.x })
        XCTAssertGreaterThan(columns.count, 1)
        XCTAssertLessThanOrEqual((columns.values.map(\.count).max() ?? 0) - (columns.values.map(\.count).min() ?? 0), 1)
    }
}
