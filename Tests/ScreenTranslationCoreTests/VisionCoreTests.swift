#if canImport(Vision) && canImport(CoreGraphics)
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ScreenTranslationCore

final class VisionCoreTests: XCTestCase {
    func testRealVisionFindsTextBelowItsDefaultHeightThreshold() async throws {
        let context = try canvas()
        draw("Small text survives", x: 140, y: 220, font: "Helvetica", size: 22, context: context)
        let image = try XCTUnwrap(context.makeImage())
        try record(image, blocks: [], name: "small-text")
        let blocks = try await VisionTextRecognizer.recognize(image, language: nil)
        try record(image, blocks: blocks, name: "small-text")
        XCTAssertTrue(blocks.map(\.original).joined().lowercased().filter { !$0.isWhitespace }.contains("smalltextsurvives"))
        XCTAssertTrue(blocks.allSatisfy { $0.boundingBox.minX >= 0 && $0.boundingBox.maxX <= 1 && $0.boundingBox.minY >= 0 && $0.boundingBox.maxY <= 1 })
    }

    func testRealVisionReadsUprightJapaneseColumns() async throws {
        let context = try canvas()
        for (column, text) in ["このケーキは", "おいしいです", "一口食べますか"].enumerated() {
            for (row, glyph) in text.enumerated() {
                draw(String(glyph), x: CGFloat(640 - column * 44), y: CGFloat(180 + row * 34), font: "HiraginoSans-W3", size: 28, context: context)
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        try record(image, blocks: [], name: "japanese-vertical")
        let blocks = try await VisionTextRecognizer.recognize(image, language: nil)
        try record(image, blocks: blocks, name: "japanese-vertical")
        let text = blocks.map(\.original).joined()
        XCTAssertTrue(text.contains("ケーキ"), text)
        XCTAssertTrue(text.contains("おいしい"), text)
        XCTAssertTrue(blocks.contains { $0.flow == .vertical }, text)
    }

    func testRealVisionKeepsOrdinaryJapaneseRowsHorizontal() async throws {
        let context = try canvas()
        for (row, text) in ["この文章は横書きです。", "文字の向きを保ちます。", "画像を正しく翻訳します。"].enumerated() {
            draw(text, x: 120, y: CGFloat(200 + row * 44), font: "HiraginoSans-W3", size: 28, context: context)
        }
        let image = try XCTUnwrap(context.makeImage())
        try record(image, blocks: [], name: "japanese-horizontal")
        let blocks = try await VisionTextRecognizer.recognize(image, language: "ja")
        try record(image, blocks: blocks, name: "japanese-horizontal")
        XCTAssertFalse(blocks.isEmpty)
        XCTAssertFalse(blocks.contains { $0.flow == .vertical }, blocks.map(\.original).joined(separator: "\n"))
    }

    func testNativeDocumentRecognitionReadsCompleteVerticalTextAndRecordsLatency() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw XCTSkip("The new native document engine requires macOS/iOS 26; legacy Vision is covered separately") }
        let context = try canvas()
        for (column, text) in ["これは何ですか", "一口だけ食べて", "とても甘いです"].enumerated() {
            for (row, glyph) in text.enumerated() {
                draw(String(glyph), x: CGFloat(640 - column * 44), y: CGFloat(180 + row * 34), font: "HiraginoSans-W3", size: 28, context: context)
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let start = ContinuousClock.now
        let native = try await VisionTextRecognizer.readDocument(image, language: "ja")
        let nativeTime = start.duration(to: .now)
        let oldStart = ContinuousClock.now
        let legacy = try await VisionTextRecognizer.recognizeLegacy(image, language: "ja")
        let legacyTime = oldStart.duration(to: .now)
        let text = native.map(\.original).joined().filter { !$0.isWhitespace }
        for expected in ["これは何ですか", "一口だけ食べて", "とても甘いです"] { XCTAssertTrue(text.contains(expected), text) }
        let warmStart = ContinuousClock.now
        let warm = try await VisionTextRecognizer.readDocument(image, language: "ja", preferCPU: true)
        let warmTime = warmStart.duration(to: .now)
        XCTAssertEqual(warm.map(\.original), native.map(\.original))
        XCTAssertTrue(native.contains { $0.flow == .vertical })
        XCTAssertTrue(native.contains { !($0.sourceGlyphBoxes ?? []).isEmpty })
        try record(image, blocks: native, name: "native-document-vertical")
        print("Synthetic OCR comparison, native: \(nativeTime), legacy: \(legacyTime), native regions: \(native.count), legacy regions: \(legacy.count), native warm: \(warmTime)")
    }

    func testSupplementalCheckRecoversAMissingLowerLeftColumnWithoutDuplicatingTheRest() async throws {
        let context = try canvas()
        for (row, glyph) in "一口食べますか".enumerated() {
            draw(String(glyph), x: 120, y: CGFloat(1000 + row * 34), font: "HiraginoSans-W6", size: 28, context: context)
        }
        let image = try XCTUnwrap(context.makeImage())
        let recovered = try await VisionTextRecognizer.supplementVerticalGaps(image, blocks: [], language: "ja")
        XCTAssertTrue(recovered.map(\.original).joined().contains("食べ"), recovered.map(\.original).joined())
        let repeated = try await VisionTextRecognizer.supplementVerticalGaps(image, blocks: recovered, language: "ja")
        XCTAssertEqual(repeated.map(\.id), recovered.map(\.id))
        try record(image, blocks: recovered, name: "supplemental-lower-left")
    }

    func testSupplementalGeometryCanReadTextOnAGrayBubble() async throws {
        let context = try canvas()
        context.setFillColor(CGColor(gray: 0.70, alpha: 1))
        context.fill(CGRect(x: 80, y: 280, width: 150, height: 360))
        for (row, glyph) in "実はそうですね".enumerated() {
            draw(String(glyph), x: 120, y: CGFloat(1000 + row * 34), font: "HiraginoSans-W6", size: 28, context: context)
        }
        let image = try XCTUnwrap(context.makeImage())
        let recovered = try await VisionTextRecognizer.supplementVerticalGaps(image, blocks: [], language: "ja")
        try record(image, blocks: recovered, name: "gray-bubble-supplement")
        XCTAssertTrue(recovered.map(\.original).joined().contains("そうです"), recovered.map(\.original).joined())
    }

    func testBatchedSupplementCoversMoreThanSixIndependentBubbles() async throws {
        let context = try canvas()
        for column in 0..<8 {
            for (row, glyph) in "これは何ですか".enumerated() {
                draw(String(glyph), x: CGFloat(45 + column * 100), y: CGFloat(900 + row * 34), font: "HiraginoSans-W6", size: 28, context: context)
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let blocks = try await VisionTextRecognizer.supplementVerticalGaps(image, blocks: [], language: "ja")
        try record(image, blocks: blocks, name: "eight-bubble-supplement")
        XCTAssertEqual(blocks.count, 8)
        XCTAssertTrue(blocks.allSatisfy { $0.original.contains("何ですか") }, blocks.map(\.original).joined(separator: " | "))
        let repeated = try await VisionTextRecognizer.supplementVerticalGaps(image, blocks: blocks, language: "ja")
        XCTAssertEqual(repeated.map(\.id), blocks.map(\.id))
    }

    func testExtensionWorkingImagePreservesVerticalTextAndSmallPrint() async throws {
        let context = try canvas()
        for (column, text) in ["これは何ですか", "一口だけ食べて", "とても甘いです"].enumerated() {
            for (row, glyph) in text.enumerated() {
                draw(String(glyph), x: CGFloat(640 - column * 44), y: CGFloat(180 + row * 34), font: "HiraginoSans-W3", size: 28, context: context)
            }
        }
        draw("Small text survives", x: 120, y: 1200, font: "Helvetica", size: 22, context: context)
        let source = try XCTUnwrap(context.makeImage())
        let large = try XCTUnwrap(CGContext(data: nil, width: 1800, height: 3200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        large.interpolationQuality = .high
        large.draw(source, in: CGRect(x: 0, y: 0, width: 1800, height: 3200))
        let image = try XCTUnwrap(large.makeImage())
        for pressure in [false, true] {
            let blocks = try await VisionTextRecognizer.recognize(image, language: nil, memoryLimited: true, underPressure: pressure)
            let text = blocks.map(\.original).joined().filter { !$0.isWhitespace }
            for expected in ["これは何ですか", "一口だけ食べて", "とても甘いです"] { XCTAssertTrue(text.contains(expected), text) }
            XCTAssertTrue(text.lowercased().contains("smalltextsurvives"), text)
            try record(image, blocks: blocks, name: pressure ? "extension-pressure" : "extension-normal")
        }
    }

    func testDenseVerticalBubblesWithRubyAreReadAcrossAllTiles() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw XCTSkip("Native document tiles require version 26") }
        let context = try canvas()
        for group in 0..<3 {
            for column in 0..<5 {
                for (row, glyph) in "これは何ですか".enumerated() {
                    draw(String(glyph), x: CGFloat(75 + column * 165), y: CGFloat(120 + group * 450 + row * 34),
                         font: "HiraginoSans-W6", size: 28, context: context)
                }
                // Ruby is smaller than the primary column and must not cause
                // its whole bubble, or a later bubble, to be omitted.
                draw("な", x: CGFloat(101 + column * 165), y: CGFloat(220 + group * 450), font: "HiraginoSans-W3", size: 9, context: context)
                draw("に", x: CGFloat(101 + column * 165), y: CGFloat(230 + group * 450), font: "HiraginoSans-W3", size: 9, context: context)
            }
        }
        let source = try XCTUnwrap(context.makeImage())
        let large = try XCTUnwrap(CGContext(data: nil, width: 1800, height: 3200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        large.draw(source, in: CGRect(x: 0, y: 0, width: 1800, height: 3200))
        let image = try XCTUnwrap(large.makeImage())
        for pressure in [false, true] {
            let blocks = try await VisionTextRecognizer.recognize(image, language: "ja", memoryLimited: true, underPressure: pressure)
            try record(image, blocks: blocks, name: pressure ? "dense-ruby-pressure" : "dense-ruby-normal")
            for group in 0..<3 {
                for column in 0..<5 {
                    let x = CGFloat(89 + column * 165) / 900
                    let y = 1 - CGFloat(236 + group * 450) / 1600
                    let matches = blocks.filter { abs($0.boundingBox.midX - x) < 0.035 && abs($0.boundingBox.midY - y) < 0.10 }
                    let text = matches.map(\.original).joined().filter { !$0.isWhitespace }
                    XCTAssertTrue(text.contains("これは何ですか"), "Bubble \(group),\(column): \(text)")
                }
            }
        }
    }

    private func canvas() throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: 900, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 1600))
        return context
    }

    private func draw(_ text: String, x: CGFloat, y: CGFloat, font: String, size: CGFloat, context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]) as CFAttributedString)
        context.textPosition = CGPoint(x: x, y: 1600 - y - size)
        CTLineDraw(line, context)
    }

    private func record(_ image: CGImage, blocks: [RecognizedBlock], name: String) throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNNER_TEMP"] ?? NSTemporaryDirectory()).appendingPathComponent("vision-core")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(folder.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let regions: [[String: Any]] = blocks.map {
            ["text": $0.original, "box": OCRAlignment.topLeftBox($0.boundingBox), "flow": $0.flow == .vertical ? "vertical" : "horizontal", "confidence": $0.confidence,
             "glyphs": ($0.sourceGlyphBoxes ?? []).map(OCRAlignment.topLeftBox)]
        }
        try JSONSerialization.data(withJSONObject: regions, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent(name + ".json"))
    }
}
#endif
