#if canImport(Vision) && canImport(CoreGraphics)
import Foundation
import CoreGraphics
import CoreText
import XCTest
@testable import ScreenTranslationCore

/// Neutral, synthetic manga lettering: dialogue bubbles with very short
/// replies, small kana, rotated long vowels and ellipses, ruby, and a
/// hand-lettered page where two speakers use different ink colours.
/// Every transcript and grouping is printed for review in CI.
final class MangaLetteringBenchmarkTests: XCTestCase {
    private let width = 1179, height = 2556

    private func canvas() throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// Ellipse bubble centred at a top-left coordinate.
    private func bubble(_ context: CGContext, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) {
        let rect = CGRect(x: cx - rx, y: CGFloat(height) - cy - ry, width: rx * 2, height: ry * 2)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillEllipse(in: rect)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1)); context.setLineWidth(4); context.strokeEllipse(in: rect)
    }

    private func glyph(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, font: String, color: CGColor, rotate: Bool, context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]) as CFAttributedString)
        context.saveGState()
        if rotate {
            // Vertical writing turns ー a quarter turn.
            let center = CGPoint(x: x + size / 2, y: CGFloat(height) - y - size / 2)
            context.translateBy(x: center.x, y: center.y); context.rotate(by: -.pi / 2); context.translateBy(x: -center.x, y: -center.y)
        }
        context.textPosition = CGPoint(x: x, y: CGFloat(height) - y - size * 0.88)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// One vertical column, top to bottom, starting at a top-left point.
    private func column(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, font: String = "HiraginoSans-W6",
                        color: CGColor = CGColor(gray: 0, alpha: 1), context: CGContext) {
        var offset: CGFloat = 0
        for character in text {
            let small = "っゃゅょぁぃぅぇぉ".contains(character)
            let drawn = small ? size * 0.62 : size
            glyph(String(character), x: x + (small ? size * 0.28 : 0), y: y + offset + (small ? size * 0.12 : 0), size: drawn,
                  font: font, color: color, rotate: character == "ー", context: context)
            offset += size * 1.12
        }
    }

    private func normalized(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.replacingOccurrences(of: "︙", with: "…").replacingOccurrences(of: "...", with: "…")
    }

    func testDialogueBubblesShortRepliesRubyAndGrouping() async throws {
        let context = try canvas()
        // 1: three columns in one bubble.
        bubble(context, cx: 880, cy: 420, rx: 150, ry: 230)
        column("無理は", x: 930, y: 270, size: 44, context: context)
        column("しなくて", x: 860, y: 270, size: 44, context: context)
        column("︙だから", x: 790, y: 270, size: 44, context: context)
        // 2: a two-character reply with a small っ.
        bubble(context, cx: 300, cy: 380, rx: 70, ry: 110)
        column("わっ", x: 278, y: 330, size: 44, context: context)
        // 3: long vowel and exclamation.
        bubble(context, cx: 560, cy: 420, rx: 80, ry: 170)
        column("ぱぱー！", x: 538, y: 300, size: 44, context: context)
        // 4: two short lines in one bubble.
        bubble(context, cx: 860, cy: 1120, rx: 130, ry: 220)
        column("こちらこそ", x: 890, y: 960, size: 44, context: context)
        column("えと︙", x: 820, y: 960, size: 44, context: context)
        // 5: kanji with ruby beside it, and a second column.
        bubble(context, cx: 360, cy: 1150, rx: 130, ry: 230)
        column("図書館に", x: 390, y: 990, size: 44, context: context)
        for (index, kana) in "としょかん".enumerated() {
            glyph(String(kana), x: 440, y: 994 + CGFloat(index) * 26, size: 14, font: "HiraginoSans-W3", color: CGColor(gray: 0, alpha: 1), rotate: false, context: context)
        }
        column("行きます", x: 320, y: 990, size: 44, context: context)
        // 6: punctuation only.
        bubble(context, cx: 600, cy: 1700, rx: 45, ry: 100)
        column("︙︙", x: 578, y: 1640, size: 44, context: context)
        let image = try XCTUnwrap(context.makeImage())

        let start = ContinuousClock.now
        let blocks = try await VisionTextRecognizer.recognize(image, language: "ja")
        let elapsed = start.duration(to: .now)
        let planned = TranslationPlanner.paragraphs(blocks)
        print("BENCH bubbles seconds=\(elapsed) regions=\(blocks.count)")
        for block in planned {
            print("BENCH bubbles block placement=\(block.placement == .overlay ? "overlay" : "textOnly") container=\(block.container != nil) text=\(block.original)")
        }
        func inBubble(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> [RecognizedBlock] {
            let box = CGRect(x: (cx - rx) / CGFloat(width), y: 1 - (cy + ry) / CGFloat(height), width: rx * 2 / CGFloat(width), height: ry * 2 / CGFloat(height))
            return planned.filter { $0.placement == .overlay && box.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }
        }
        let first = inBubble(880, 420, 150, 230)
        XCTAssertEqual(first.count, 1, "One utterance per bubble: \(first.map(\.original))")
        XCTAssertTrue(normalized(first.first?.original ?? "").contains("無理は"), first.map(\.original).joined())
        XCTAssertTrue(normalized(first.first?.original ?? "").contains("だから"), first.map(\.original).joined())
        XCTAssertNotNil(first.first?.container)
        let fourth = inBubble(860, 1120, 130, 220)
        XCTAssertEqual(fourth.count, 1, fourth.map(\.original).joined(separator: " | "))
        XCTAssertTrue(normalized(fourth.first?.original ?? "").contains("こちらこそ"), fourth.map(\.original).joined())
        let fifth = inBubble(360, 1150, 130, 230)
        XCTAssertFalse(fifth.contains { $0.original.contains("としょかん") }, "Ruby must not join the dialogue")
        XCTAssertTrue(inBubble(600, 1700, 45, 100).allSatisfy { $0.original.unicodeScalars.allSatisfy { !CharacterSet.letters.contains($0) } })
        // Short replies are a measured target: printed, counted, not hidden.
        for (name, cx, cy, rx, ry, expected) in [("wa", 300.0, 380.0, 70.0, 110.0, "わ"), ("papa", 560, 420, 80, 170, "ぱぱ"), ("eto", 860, 1120, 130, 220, "えと")] {
            let found = inBubble(cx, cy, rx, ry).contains { normalized($0.original).contains(expected) }
            print("BENCH bubbles short=\(name) found=\(found) texts=\(inBubble(cx, cy, rx, ry).map(\.original))")
        }
        XCTAssertTrue(inBubble(300, 380, 70, 110).contains { $0.original.contains("わ") }, "The two-character reply must be read")
    }

    func testHandLetteredSpeakersStayApartByInkColour() async throws {
        if let url = Bundle.module.url(forResource: "Yomogi-Regular", withExtension: "ttf", subdirectory: "Fixtures") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let context = try canvas()
        let brown = CGColor(red: 0.62, green: 0.28, blue: 0.24, alpha: 1), blue = CGColor(red: 0.22, green: 0.28, blue: 0.68, alpha: 1)
        // Two speakers' columns side by side, as on hand-lettered pages.
        column("今日はとても", x: 1000, y: 300, size: 40, font: "Yomogi-Regular", color: brown, context: context)
        column("楽しかったです", x: 945, y: 300, size: 40, font: "Yomogi-Regular", color: brown, context: context)
        column("そうですね", x: 880, y: 330, size: 40, font: "Yomogi-Regular", color: blue, context: context)
        column("また来ましょう", x: 825, y: 330, size: 40, font: "Yomogi-Regular", color: blue, context: context)
        column("えっ", x: 200, y: 1500, size: 38, font: "Yomogi-Regular", color: blue, context: context)
        column("はぁ︙", x: 320, y: 1500, size: 38, font: "Yomogi-Regular", color: brown, context: context)
        let image = try XCTUnwrap(context.makeImage())
        let blocks = try await VisionTextRecognizer.recognize(image, language: "ja")
        let planned = TranslationPlanner.paragraphs(blocks)
        for block in planned {
            print("BENCH lettering block ink=\(block.inkColor.map { $0.map { String(format: "%.2f", $0) }.joined(separator: ",") } ?? "none") text=\(block.original)")
        }
        let all = planned.map { normalized($0.original) }.joined()
        print("BENCH lettering found brown=\(all.contains("楽しかった")) blue=\(all.contains("そうですね")) eh=\(all.contains("えっ")) haa=\(all.contains("はぁ"))")
        XCTAssertFalse(planned.contains { $0.original.contains("楽しかった") && $0.original.contains("そうですね") },
                       "Different speakers' colours must not be merged into one utterance")
        XCTAssertTrue(all.contains("そうですね"), all)
        XCTAssertFalse(planned.contains { $0.placement == .overlay && $0.original == "あ" }, "The small ぁ of はぁ… must not become a second overlay")
    }
}
#endif
