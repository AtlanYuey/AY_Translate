#if canImport(Vision) && canImport(CoreGraphics)
import Foundation
import CoreGraphics
import CoreText
import XCTest
@testable import ScreenTranslationCore

/// A phone-sized page mixing text that commonly fails: a long vertical line
/// crossing both extension tile seams, a large title, 11–12 px print, a
/// handwriting-style font and slanted glyphs. Each recognition mode is
/// measured on the identical bitmap; every transcript is printed for review.
final class VisionScreenshotBenchmarkTests: XCTestCase {
    private let width = 1179, height = 2556

    private struct Sample {
        let name: String, text: String, font: String, x: CGFloat, y: CGFloat, size: CGFloat
        let vertical: Bool, slanted: Bool, body: Bool
        func bounds(_ width: Int, _ height: Int) -> CGRect {
            let w = vertical ? size * 1.8 : CGFloat(text.count) * size * (text.unicodeScalars.contains { $0.value > 0x2E80 } ? 1.1 : 0.62)
            let h = vertical ? CGFloat(text.count) * size * 1.3 : size * 1.8
            return CGRect(x: (x - 12) / CGFloat(width), y: 1 - (y + h + 12) / CGFloat(height),
                          width: (w + 24) / CGFloat(width), height: (h + 24) / CGFloat(height))
        }
    }

    private var samples: [Sample] {
        [
            Sample(name: "large-title", text: "大きな見出しの文字", font: "HiraginoSans-W6", x: 40, y: 120, size: 112, vertical: false, slanted: false, body: true),
            Sample(name: "english-body", text: "Translate every line on this screen.", font: "Helvetica", x: 40, y: 380, size: 40, vertical: false, slanted: false, body: true),
            Sample(name: "vertical-across-tile-seams", text: "この縦書きの台詞は二つの境目をまたぎます", font: "HiraginoSans-W3", x: 1040, y: 700, size: 40, vertical: true, slanted: false, body: true),
            Sample(name: "handwriting-vertical", text: "手書きの文字も読めますか", font: "Yomogi-Regular", x: 860, y: 900, size: 44, vertical: true, slanted: false, body: true),
            Sample(name: "handwriting-horizontal", text: "今日は雨が降っています", font: "Yomogi-Regular", x: 60, y: 1900, size: 42, vertical: false, slanted: false, body: true),
            Sample(name: "slanted-horizontal", text: "少し傾いた文字です", font: "HiraginoSans-W3", x: 60, y: 2100, size: 38, vertical: false, slanted: true, body: true),
            Sample(name: "tiny-english", text: "Version 2.4.1 terms apply", font: "Helvetica", x: 40, y: 2440, size: 11, vertical: false, slanted: false, body: false),
            Sample(name: "tiny-japanese", text: "利用規約に同意します", font: "HiraginoSans-W3", x: 40, y: 2480, size: 12, vertical: false, slanted: false, body: false)
        ]
    }

    func testPhoneScreenshotAcrossRecognitionModes() async throws {
        if let url = Bundle.module.url(forResource: "Yomogi-Regular", withExtension: "ttf", subdirectory: "Fixtures") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let image = try render()
        let modes: [(String, @Sendable () async -> OCRResourcePolicy)] = [
            ("app", { OCRResourcePolicy(memoryLimited: false) }),
            ("extension-headroom", { OCRResourcePolicy(memoryLimited: true, availableBytes: 220 * 1_024 * 1_024, footprintBytes: 60 * 1_024 * 1_024) }),
            ("extension-tight", { OCRResourcePolicy(memoryLimited: true, availableBytes: 120 * 1_024 * 1_024, footprintBytes: 100 * 1_024 * 1_024) })
        ]
        var report: [[String: Any]] = []
        for (mode, policy) in modes {
            let start = ContinuousClock.now
            let blocks = try await VisionTextRecognizer.recognize(image, language: nil, resourcePolicy: policy)
            let elapsed = start.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            print("BENCH mode=\(mode) seconds=\(String(format: "%.3f", seconds)) regions=\(blocks.count)")
            for sample in samples {
                let bounds = sample.bounds(width, height)
                let located = blocks.filter { $0.placement == .overlay && bounds.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }
                    .sorted { sample.vertical ? $0.boundingBox.maxY > $1.boundingBox.maxY : $0.boundingBox.minX < $1.boundingBox.minX }
                let actual = located.map(\.original).joined().filter { !$0.isWhitespace }
                let expected = sample.text.filter { !$0.isWhitespace }
                let errors = editDistance(Array(expected.lowercased()), Array(actual.lowercased()))
                print("BENCH mode=\(mode) sample=\(sample.name) exact=\(actual == expected) cer=\(String(format: "%.2f", Double(errors) / Double(expected.count))) actual=\(actual)")
                report.append(["mode": mode, "sample": sample.name, "expected": expected, "actual": actual, "exact": actual == expected,
                               "characterErrorRate": Double(errors) / Double(expected.count), "seconds": seconds])
                if sample.body { XCTAssertFalse(actual.isEmpty, "\(sample.name) missing in \(mode) mode") }
                // On the current document engine every mode, including the
                // app, must transcribe the whole page exactly (11–12 px too).
                if #available(macOS 26.0, iOS 26.0, *) {
                    XCTAssertEqual(actual, expected, "Transcript regression in \(sample.name), \(mode) mode")
                }
            }
            // Duplicate overlays of the same ink are a visible error ("too much").
            let overlays = blocks.filter { $0.placement == .overlay }
            for (i, a) in overlays.enumerated() { for b in overlays[(i + 1)...] where a.original == b.original && a.flow == b.flow {
                let overlap = a.boundingBox.intersection(b.boundingBox)
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < min(a.boundingBox.width * a.boundingBox.height, b.boundingBox.width * b.boundingBox.height) * 0.5,
                              "Duplicate overlay \(a.original) in \(mode) mode")
            } }
        }
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RUNNER_TEMP"] ?? NSTemporaryDirectory()).appendingPathComponent("vision-core")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("phone-screenshot-modes.json"))
    }

    private func render() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for sample in samples {
            if sample.vertical {
                for (index, glyph) in sample.text.enumerated() {
                    draw(String(glyph), x: sample.x, y: sample.y + CGFloat(index) * sample.size * 1.3, font: sample.font, size: sample.size, context: context)
                }
            } else if sample.slanted {
                var x = sample.x
                for (index, glyph) in sample.text.enumerated() {
                    context.saveGState()
                    let center = CGPoint(x: x + sample.size / 2, y: CGFloat(height) - sample.y - sample.size / 2)
                    context.translateBy(x: center.x, y: center.y)
                    context.rotate(by: CGFloat([8, -6, 5, -8][index % 4]) * .pi / 180)
                    context.translateBy(x: -center.x, y: -center.y + CGFloat(index % 3 - 1) * 3)
                    draw(String(glyph), x: x, y: sample.y, font: sample.font, size: sample.size, context: context)
                    context.restoreGState()
                    x += sample.size * 1.08
                }
            } else {
                draw(sample.text, x: sample.x, y: sample.y, font: sample.font, size: sample.size, context: context)
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func draw(_ text: String, x: CGFloat, y: CGFloat, font: String, size: CGFloat, context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]) as CFAttributedString)
        context.textPosition = CGPoint(x: x, y: CGFloat(height) - y - size)
        CTLineDraw(line, context)
    }

    private func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1]
            for (j, y) in b.enumerated() { row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (x == y ? 0 : 1))) }
            previous = row
        }
        return previous[b.count]
    }
}
#endif
