import XCTest
@testable import ScreenTranslationCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class OCRNoiseTests: XCTestCase {
    private func block(_ text: String, x: CGFloat = 0.1, y: CGFloat = 0.5, confidence: Float = 0.9, vertical: Bool = false,
                       container: CGRect? = nil) -> RecognizedBlock {
        RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: CGRect(x: x, y: y, width: 0.05, height: 0.2),
                        confidence: confidence, flow: vertical ? .vertical : .horizontal, sourceColumnWidth: vertical ? 0.03 : nil, container: container)
    }

    private func comicPage() -> [RecognizedBlock] {
        let first = CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.3), second = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)
        return [block("今回の女の子はどんな子だろう", x: 0.65, y: 0.65, vertical: true, container: first),
                block("使い始めて何人か会ってみた", x: 0.15, y: 0.15, vertical: true, container: second)]
    }

    func testNumbersAndSymbolsAloneAreNeverOverlaid() {
        let result = OCRNoise.suppress([block("13:21"), block("10 10"), block("…!?"), block("¥1,200"), block("3時"), block("Lv 5")])
        XCTAssertEqual(result.map(\.placement), [.textOnly, .textOnly, .textOnly, .textOnly, .overlay, .overlay])
    }

    func testAnotherAlphabetOnAJapanesePageIsArtworkNotText() {
        let page = comicPage() + [block("70كم"), block("ДД"), block("え？Σ(ﾟДﾟ)"), block("マッチング")]
        let result = OCRNoise.suppress(page)
        XCTAssertEqual(result.map(\.placement), [.overlay, .overlay, .textOnly, .textOnly, .overlay, .overlay])
    }

    func testLatinOutsideBubblesIsLeftAloneOnAComicPage() {
        let bubble = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let page = comicPage() + [block("TEND S"), block("©2024 Studio Name"), block("OK", container: bubble), block("ズコー", vertical: true)]
        let result = OCRNoise.suppress(page)
        XCTAssertEqual(result.map(\.placement), [.overlay, .overlay, .textOnly, .textOnly, .overlay, .overlay])
    }

    func testEnglishInAJapaneseAppOrGameScreenIsStillTranslated() {
        // No vertical dialogue bubbles: an interface, not a comic page.
        let page = [block("設定を開いてください"), block("アカウント情報の確認"), block("通知とプライバシーの設定を変更できます"),
                    block("ログインして続けるにはここをタップ"), block("Settings"), block("Sign in with Apple"), block("HP")]
        XCTAssertTrue(OCRNoise.suppress(page).allSatisfy { $0.placement == .overlay })
        // …but a few hesitant Latin letters there are a misread.
        let noisy = page + [block("lI", confidence: 0.32)]
        XCTAssertEqual(OCRNoise.suppress(noisy).last?.placement, .textOnly)
    }

    func testPagesInOtherLanguagesAreUntouched() {
        let english = [block("The quick brown fox"), block("Привет, мир"), block("jumps over the lazy dog")]
        XCTAssertTrue(OCRNoise.suppress(english).allSatisfy { $0.placement == .overlay })
        let arabic = [block("مرحبا بالعالم"), block("هذا نص عربي طويل"), block("日本")]
        XCTAssertTrue(OCRNoise.suppress(arabic).allSatisfy { $0.placement == .overlay })
    }

    func testSkinTonedInteriorIsNotPaper() {
        func fill(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
            var pixels = [UInt8](repeating: 255, count: 40 * 40 * 4)
            for i in 0..<(40 * 40) { pixels[i * 4] = r; pixels[i * 4 + 1] = g; pixels[i * 4 + 2] = b }
            // A few dark marks (eyes or glyphs) must not change the verdict.
            for i in stride(from: 410, to: 440, by: 1) { pixels[i * 4] = 20; pixels[i * 4 + 1] = 20; pixels[i * 4 + 2] = 20 }
            return pixels
        }
        let all = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertTrue(BackgroundSampling.isSkinTone(pixels: fill(255, 226, 205), width: 40, height: 40, region: all))
        XCTAssertTrue(BackgroundSampling.isSkinTone(pixels: fill(246, 214, 190), width: 40, height: 40, region: all))
        XCTAssertFalse(BackgroundSampling.isSkinTone(pixels: fill(255, 255, 255), width: 40, height: 40, region: all))
        XCTAssertFalse(BackgroundSampling.isSkinTone(pixels: fill(244, 244, 240), width: 40, height: 40, region: all))
        // Flat tints used for emphasis bubbles: yellow, pink, blue.
        XCTAssertFalse(BackgroundSampling.isSkinTone(pixels: fill(255, 252, 215), width: 40, height: 40, region: all))
        XCTAssertFalse(BackgroundSampling.isSkinTone(pixels: fill(255, 225, 232), width: 40, height: 40, region: all))
        XCTAssertFalse(BackgroundSampling.isSkinTone(pixels: fill(220, 236, 255), width: 40, height: 40, region: all))
    }
}

final class OCRAssistTests: XCTestCase {
    private func line(_ text: String, y: CGFloat, confidence: Float = 1) -> RecognizedBlock {
        RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: CGRect(x: 0.1, y: y, width: 0.6, height: 0.04), confidence: confidence)
    }

    func testCloudHelpIsAskedForOnlyWhenLocalReadingLooksUnreliable() {
        let size = CGSize(width: 1000, height: 2000)
        let clean = [line("設定を開いてください", y: 0.8), line("アカウント情報の確認", y: 0.7), line("通知の設定を変更できます", y: 0.6)]
        XCTAssertFalse(OCRAssist.isNeeded(blocks: clean, bubbles: [], imageSize: size), "A cleanly read screen costs nothing")
        XCTAssertTrue(OCRAssist.isNeeded(blocks: [], bubbles: [], imageSize: size), "Nothing could be read")
        // Two hesitant lines making up a good share of the text (handwriting).
        let hesitant = clean + [line("もう26だし", y: 0.5, confidence: 0.3), line("そう簡単に", y: 0.4, confidence: 0.3)]
        XCTAssertTrue(OCRAssist.isNeeded(blocks: hesitant, bubbles: [], imageSize: size))
        XCTAssertFalse(OCRAssist.isNeeded(blocks: clean + [line("OK", y: 0.5, confidence: 0.3)], bubbles: [], imageSize: size), "One unsure label is not a reason")
        // Lettering misread as another alphabet.
        let misread = OCRNoise.suppress(clean + [line("70كم", y: 0.3)])
        XCTAssertTrue(OCRAssist.isNeeded(blocks: misread, bubbles: [], imageSize: size))
    }
}

final class BubbleParagraphDirectionTests: XCTestCase {
    func testAStrayVerticalFragmentDoesNotTurnAHorizontalTitleOnItsSide() {
        let area = CGRect(x: 0.6, y: 0.7, width: 0.3, height: 0.1)
        func line(_ text: String, _ box: CGRect, vertical: Bool = false) -> RecognizedBlock {
            RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: box, confidence: 0.8, sourceLineHeight: vertical ? nil : box.height,
                            flow: vertical ? .vertical : .horizontal, sourceColumnWidth: vertical ? box.width : nil, container: area)
        }
        let top = line("元セフレと", CGRect(x: 0.70, y: 0.770, width: 0.10, height: 0.016))
        let middle = line("マッチング", CGRect(x: 0.69, y: 0.742, width: 0.22, height: 0.028))
        let bottom = line("しました。", CGRect(x: 0.74, y: 0.722, width: 0.13, height: 0.018))
        // Two stacked glyphs read as a vertical column across the two rows.
        let stray = line("グた", CGRect(x: 0.80, y: 0.724, width: 0.03, height: 0.044), vertical: true)
        let merged = TranslationPlanner.bubbleParagraphs([stray, bottom, top, middle])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].flow, .horizontal)
        XCTAssertEqual(merged[0].original, "元セフレとマッチングしました。")
    }

    func testVerticalDialogueStaysVertical() {
        let area = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.4)
        func column(_ text: String, x: CGFloat) -> RecognizedBlock {
            RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: CGRect(x: x, y: 0.2, width: 0.03, height: 0.2), confidence: 0.8,
                            flow: .vertical, sourceColumnWidth: 0.03, container: area)
        }
        let merged = TranslationPlanner.bubbleParagraphs([column("どんな子だろう…", x: 0.2), column("今回の女の子は", x: 0.25)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].flow, .vertical)
        XCTAssertEqual(merged[0].original, "今回の女の子はどんな子だろう…")
    }
}

final class VerticalColumnBalanceTests: XCTestCase {
    private func columns(_ layout: VerticalTextLayout) -> [[String]] {
        var result: [(x: CGFloat, glyphs: [VerticalGlyph])] = []
        for glyph in layout.glyphs {
            if let index = result.firstIndex(where: { abs($0.x - glyph.center.x) < 0.01 }) { result[index].glyphs.append(glyph) }
            else { result.append((glyph.center.x, [glyph])) }
        }
        return result.sorted { $0.x > $1.x }.map { $0.glyphs.sorted { $0.center.y < $1.center.y }.map(\.text) }
    }

    func testAOneColumnCaptionStaysOneColumnInItsBox() {
        // Source: nine characters in one column; the box is two glyphs wide.
        let layout = VerticalTextLayout(text: "交友软件……", size: CGSize(width: 52, height: 200), preferred: 26, scale: 1, compact: true)
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(layout.columnCount, 1)
        XCTAssertEqual(columns(layout).map(\.count), [6])
    }

    func testColumnsAreFilledEvenlyWithoutAnOrphan() {
        // Seventeen characters, seven rows per column: 6/6/5, not 7/7/3.
        let layout = VerticalTextLayout(text: "不知道这次的女孩是个什么样的人……", size: CGSize(width: 90, height: 200), preferred: 27, scale: 1, compact: true)
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(columns(layout).map(\.count), [6, 6, 5])
        for glyph in layout.glyphs { XCTAssertTrue(CGRect(x: 0, y: 0, width: 90, height: 200).contains(glyph.center)) }
    }

    func testClosingPunctuationNeverStartsAColumn() {
        // Evenly 5/5/5/4 would begin the last column with the ellipsis.
        let text = "看朋友交了女朋友，有点着急才注册……"
        let layout = VerticalTextLayout(text: text, size: CGSize(width: 130, height: 180), preferred: 28, scale: 1, compact: true)
        XCTAssertTrue(layout.fits)
        XCTAssertEqual(layout.glyphs.count, text.count)
        let closing: Set<String> = ["︙", "︐", "︒", "︑", "！", "？"]
        for column in columns(layout) { XCTAssertFalse(closing.contains(column[0]), "column begins with \(column[0])") }
        XCTAssertGreaterThanOrEqual(columns(layout).map(\.count).min() ?? 0, 3)
    }

    func testDistributionKeepsEveryCharacterAndRespectsTheRowLimit() {
        for text in ["啊，不好意思，请问是室先生……吗？", "嗯。", "好！！", "……", "一二三四五六七八九十，一二三四五六七八九十。"] {
            let chars = Array(text)
            for limit in 1...9 {
                let needed = Int((Double(chars.count) / Double(limit)).rounded(.up))
                let sizes = VerticalTextLayout.distribution(chars, columns: needed, maximumRows: limit)
                XCTAssertEqual(sizes.reduce(0, +), chars.count)
                XCTAssertTrue(sizes.allSatisfy { $0 >= 1 && $0 <= limit }, "\(text) \(limit) \(sizes)")
            }
        }
    }

    func testSourceColumnCountFollowsGlyphCentres() {
        let boxes = [CGRect(x: 0.50, y: 0.5, width: 0.03, height: 0.03), CGRect(x: 0.501, y: 0.45, width: 0.03, height: 0.03),
                     CGRect(x: 0.45, y: 0.5, width: 0.03, height: 0.03), CGRect(x: 0.40, y: 0.5, width: 0.028, height: 0.03)]
        XCTAssertEqual(VerticalTextLayout.columnCount(of: boxes, columnWidth: 0.03), 3)
        XCTAssertEqual(VerticalTextLayout.columnCount(of: [], columnWidth: 0.03), 1)
    }
}
