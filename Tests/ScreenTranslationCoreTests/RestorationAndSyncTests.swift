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

final class IslandRemovalTests: XCTestCase {
    private let width = 160, height = 200

    /// Gray page with a white ellipse bubble (dark outline) and bold strokes.
    private func bubblePage(paper: UInt8 = 250, outside: UInt8 = 150) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        func set(_ x: Int, _ y: Int, _ value: UInt8) { let i = (y * width + x) * 4; pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value }
        for y in 0..<height { for x in 0..<width {
            let dx = Double(x - 80) / 46, dy = Double(y - 100) / 76
            let r = (dx * dx + dy * dy).squareRoot()
            set(x, y, r < 1 ? paper : (r < 1.07 ? 15 : outside))
        } }
        // Two bold "glyphs" with an antialiased fringe.
        for (gx, gy) in [(66, 60), (66, 104)] {
            for y in (gy - 1)...(gy + 30) { for x in (gx - 1)...(gx + 28) {
                let edge = x < gx || y < gy || x > gx + 27 || y > gy + 29
                let stroke = (x - gx) % 12 < 7 || (y - gy) % 14 < 6
                if edge { if stroke { set(x, y, 215) } } else if stroke { set(x, y, 10) }
            } }
        }
        return pixels
    }
    private let textBox = CGRect(x: 64, y: 58, width: 33, height: 80)

    func testBubbleLetteringIsClearedToCleanPaperAndTheOutlineSurvives() {
        let source = bubblePage()
        let patch = TextInkRestoration.removingIslands(pixels: source, width: width, height: height, source: textBox, glyphSize: 28, slack: 0.8)
        XCTAssertGreaterThan(patch.changedPixels, 800)
        for y in 0..<height { for x in 0..<width {
            let dx = Double(x - 80) / 46, dy = Double(y - 100) / 76
            let r = (dx * dx + dy * dy).squareRoot(), value = patch.pixels[(y * width + x) * 4]
            if r < 0.97 { XCTAssertGreaterThanOrEqual(value, 245, "Paper at \(x),\(y) must be clean, including the stroke fringe") }
            else { XCTAssertEqual(value, source[(y * width + x) * 4], "Outline and artwork at \(x),\(y) are untouched") }
        } }
    }

    func testOutlinedLetteringOnShadedBackgroundIsFilledWithTheLocalTone() {
        // Black strokes with a white outline on a left-to-right gradient.
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        func set(_ x: Int, _ y: Int, _ value: UInt8) { let i = (y * width + x) * 4; pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value }
        for y in 0..<height { for x in 0..<width { set(x, y, UInt8(120 + x / 8)) } }
        for y in 70..<130 { for x in 50..<110 where (x - 50) % 20 < 14 { set(x, y, (x - 50) % 20 < 3 || (x - 50) % 20 > 10 || y < 73 || y > 126 ? 255 : 5) } }
        let patch = TextInkRestoration.removingIslands(pixels: pixels, width: width, height: height, source: CGRect(x: 48, y: 68, width: 64, height: 64), glyphSize: 30)
        XCTAssertGreaterThan(patch.changedPixels, 2000)
        for y in 70..<130 { for x in 50..<110 {
            XCTAssertEqual(Int(patch.pixels[(y * width + x) * 4]), 120 + x / 8, accuracy: 6, "Fill follows the shading at \(x),\(y)")
        } }
    }

    func testCrossingLinesNeighboursAndTexturedArtAreLeftAlone() {
        // A table rule through the box and an icon beside it survive.
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        func set(_ x: Int, _ y: Int, _ value: UInt8) { let i = (y * width + x) * 4; pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value }
        for x in 0..<width { set(x, 100, 20); set(x, 101, 20) }
        for y in 84..<96 { for x in 60..<100 where x % 8 < 5 { set(x, y, 10) } }
        for y in 80..<96 { for x in 112..<128 { set(x, y, 30) } }
        let box = CGRect(x: 58, y: 82, width: 44, height: 16)
        let patch = TextInkRestoration.removingIslands(pixels: pixels, width: width, height: height, source: box, glyphSize: 14)
        XCTAssertGreaterThan(patch.pixels[(90 * width + 62) * 4], 245, "Lettering is cleared")
        XCTAssertEqual(patch.pixels[(100 * width + 80) * 4], 20, "A rule crossing the window is not lettering")
        XCTAssertEqual(patch.pixels[(88 * width + 120) * 4], 30, "A neighbouring icon outside the text box stays")
        // Noise without a dominant tone: nothing is changed.
        var noise = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 7
        for i in 0..<(width * height) { seed = seed &* 1_664_525 &+ 1_013_904_223; let v = UInt8(seed >> 24); noise[i * 4] = v; noise[i * 4 + 1] = v; noise[i * 4 + 2] = v }
        XCTAssertEqual(TextInkRestoration.removingIslands(pixels: noise, width: width, height: height, source: box, glyphSize: 14).changedPixels, 0)
    }

    func testAWholeBubbleIsNeverTreatedAsOneIsland() {
        // The box is judged from inside: paper is the background even when
        // the bubble is smaller than the search window around the text.
        let source = bubblePage()
        let patch = TextInkRestoration.removingIslands(pixels: source, width: width, height: height, source: CGRect(x: 40, y: 30, width: 80, height: 140), glyphSize: 28)
        XCTAssertGreaterThan(patch.pixels[(100 * width + 60) * 4], 240, "The bubble's paper is not painted with the outside tone")
    }
}
