import CoreImage
import CoreText
import SwiftUI
import UIKit

@MainActor
enum ScreenshotRendering {
    struct TextLayout {
        let sourceRect: CGRect
        let textRect: CGRect
        let fontSize: CGFloat
        let lineLimit: Int
        let coverPadding: CGFloat
    }

    /// Recover a font size from each OCR line's typographic height, not the
    /// paragraph union or a fixed viewport size. Include fallback-font leading.
    /// All distances scale with the image; there is no viewport-point minimum.
    static func textLayout(for block: RecognizedBlock, canvasSize: CGSize, textScale: Double, text: String? = nil) -> TextLayout {
        let text = text ?? block.translation
        let rect = CGRect(x: block.boundingBox.minX * canvasSize.width,
                          y: (1 - block.boundingBox.maxY) * canvasSize.height,
                          width: block.boundingBox.width * canvasSize.width,
                          height: block.boundingBox.height * canvasSize.height)
        let lineHeight = max(0.0001, block.originalLineHeight * canvasSize.height)
        let metrics = glyphMetrics(for: text)
        let preferred = lineHeight / metrics.lineHeightRatio
        let fitted = fittedFontSize(for: text, in: rect, preferred: preferred, metrics: metrics)
        // Fit at 100% first. Fitting again after this multiplication would undo
        // the user's enlargement whenever a translated region is already full.
        let scale = textScale.isFinite && textScale > 0 ? CGFloat(textScale) : 1
        let fontSize = fitted * scale
        let fontLineHeight = fontSize * metrics.lineHeightRatio
        let leading = max(0, fontLineHeight - fontSize * metrics.inkRatio)
        // Manual enlargement may exceed a single original line's ink box.
        // Keep a complete line visible while the background still covers only
        // the original region; clipping the enlarged glyph defeats the slider.
        let textHeight = max(rect.height, fontSize * metrics.inkRatio) + leading
        let textRect = CGRect(x: rect.minX, y: rect.midY - textHeight / 2, width: rect.width, height: textHeight)
        return TextLayout(sourceRect: rect, textRect: textRect, fontSize: fontSize,
                          lineLimit: max(1, Int((textRect.height + fontSize * 0.001) / fontLineHeight)),
                          coverPadding: lineHeight * 0.06)
    }

    private struct GlyphMetrics {
        let inkRatio: CGFloat
        let lineHeightRatio: CGFloat
    }

    private static func glyphMetrics(for text: String) -> GlyphMetrics {
        // CTLine includes actual fallback glyphs (e.g. Chinese/Japanese), unlike
        // capHeight alone. Bound measurement work on long model responses.
        let sample = String(text.prefix(256)).replacingOccurrences(of: "\n", with: " ")
        let referenceFont = UIFont.systemFont(ofSize: 100, weight: .medium)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample, attributes: [
            .font: referenceFont
        ]) as CFAttributedString)
        let height = CTLineGetImageBounds(line, nil).height
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let inkRatio = height.isFinite && height > 0 ? min(1.5, max(0.5, height / 100)) : 1
        // Fallback CJK/Arabic fonts can have different ascent and descent from
        // UIFont.systemFont. Measure the actual text, including those runs.
        // Text/NSString also reserve the primary font's line height when every
        // visible glyph comes from a fallback font. Use the larger of the two.
        let lineHeight = max(referenceFont.lineHeight, ascent + descent + leading) / 100
        return GlyphMetrics(inkRatio: inkRatio, lineHeightRatio: lineHeight.isFinite ? max(inkRatio, lineHeight) : 1.5)
    }

    private static func fittedFontSize(for text: String, in rect: CGRect, preferred: CGFloat, metrics: GlyphMetrics) -> CGFloat {
        func fits(_ size: CGFloat) -> Bool {
            let font = UIFont.systemFont(ofSize: size, weight: .medium)
            let leading = max(0, size * (metrics.lineHeightRatio - metrics.inkRatio))
            let bounds = (text as NSString).boundingRect(
                with: CGSize(width: max(0.0001, rect.width), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil)
            return bounds.height <= rect.height + leading + size * 0.001 && bounds.width <= rect.width + size * 0.001
        }
        if fits(preferred) { return preferred }
        // Long translations can shrink moderately relative to their own source,
        // never relative to a fixed global font. Tap still reveals the full text.
        var lower = preferred * 0.75, upper = preferred
        for _ in 0..<8 {
            let middle = (lower + upper) / 2
            if fits(middle) { lower = middle } else { upper = middle }
        }
        return lower
    }

    static func palette(for document: TranslationDocument) -> [UUID: SampledColor] {
        guard let image = uprightImage(for: document) else { return [:] }
        return sampledPalette(image: image, blocks: document.blocks)
    }

    static func paletteAsync(for document: TranslationDocument) async -> [UUID: SampledColor] {
        guard let image = uprightImage(for: document) else { return [:] }
        let blocks = document.blocks
        return await Task.detached(priority: .userInitiated) {
            sampledPalette(image: image, blocks: blocks)
        }.value
    }

    private static func uprightImage(for document: TranslationDocument) -> CGImage? {
        guard document.image.size.width > 0, document.image.size.height > 0 else { return nil }
        let factor = min(1, 640 / max(document.image.size.width, document.image.size.height))
        let size = CGSize(width: max(1, floor(document.image.size.width * factor)), height: max(1, floor(document.image.size.height * factor)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            document.image.draw(in: CGRect(origin: .zero, size: size))
        }
        return upright.cgImage
    }

    private nonisolated static func sampledPalette(image: CGImage, blocks: [RecognizedBlock]) -> [UUID: SampledColor] {
        // The bitmap is at most 640px on its longest edge. CPU rendering avoids
        // compiling a Metal pipeline on the extension's UI thread for this copy.
        let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(CIImage(cgImage: image), toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return Dictionary(uniqueKeysWithValues: blocks.filter { $0.placement == .overlay }.map {
            ($0.id, BackgroundSampling.sample(pixels: bytes, width: width, height: height, region: $0.boundingBox))
        })
    }

    /// Render an already processed document without repeating OCR or translation.
    static func translatedImage(_ document: TranslationDocument, palette: [UUID: SampledColor], textScale: Double) -> UIImage {
        let width: CGFloat = 390
        let size = CGSize(width: width, height: width * document.image.size.height / max(1, document.image.size.width))
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(3, 2560 / max(size.width, size.height))
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            document.image.draw(in: CGRect(origin: .zero, size: size))
            for block in document.blocks where block.placement == .overlay && block.translation != block.original {
                let layout = textLayout(for: block, canvasSize: size, textScale: textScale)
                let color = palette[block.id] ?? SampledColor(red: 1, green: 1, blue: 1)
                UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
                renderer.fill(layout.sourceRect.insetBy(dx: -layout.coverPadding, dy: -layout.coverPadding))
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = document.target.isRightToLeft ? .right : .left
                paragraph.lineBreakMode = .byTruncatingTail
                (block.translation as NSString).draw(in: layout.textRect, withAttributes: [
                    .font: UIFont.systemFont(ofSize: layout.fontSize, weight: .medium),
                    .foregroundColor: color.usesDarkText ? UIColor.black : UIColor.white,
                    .paragraphStyle: paragraph
                ])
            }
        }
    }
}
