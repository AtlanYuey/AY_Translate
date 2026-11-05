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
        let vertical: VerticalTextLayout?
        let canRender: Bool
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
        let scale = textScale.isFinite && textScale > 0 ? CGFloat(textScale) : 1
        if block.flow == .vertical && VerticalTextLayout.supports(text) {
            let preferred = max(0.001, block.originalColumnWidth * canvasSize.width * 0.94)
            let base = VerticalTextLayout(text: text, size: rect.size, preferred: preferred, scale: min(1, scale))
            let layout = scale > 1 ? VerticalTextLayout(scaling: base, by: scale) : base
            // Manual enlargement must not silently turn a complete vertical
            // translation back into the original. Grow its text area around
            // the same anchor; the background still covers only the source.
            let textRect = scale > 1 ? CGRect(x: rect.midX - rect.width * scale / 2, y: rect.midY - rect.height * scale / 2,
                width: rect.width * scale, height: rect.height * scale) : rect
            return TextLayout(sourceRect: rect, textRect: textRect, fontSize: layout.fontSize, lineLimit: 1,
                              coverPadding: layout.fontSize * 0.06, vertical: layout, canRender: layout.fits)
        }
        let metrics = glyphMetrics(for: text)
        let preferred = block.flow == .vertical ? block.originalColumnWidth * canvasSize.width * 0.94 : lineHeight / metrics.lineHeightRatio
        let fitted = fittedFontSize(for: text, in: rect, preferred: preferred, metrics: metrics)
        // Fit at 100% first. Fitting again after this multiplication would undo
        // the user's enlargement whenever a translated region is already full.
        let fontSize = fitted * scale
        let fontLineHeight = fontSize * metrics.lineHeightRatio
        let leading = max(0, fontLineHeight - fontSize * metrics.inkRatio)
        // Manual enlargement may exceed a single original line's ink box.
        // Keep a complete line visible while the background still covers only
        // the original region; clipping the enlarged glyph defeats the slider.
        let textHeight = max(rect.height, fontSize * metrics.inkRatio) + leading
        let textRect = CGRect(x: rect.minX, y: rect.midY - textHeight / 2, width: rect.width, height: textHeight)
        let bounds = (text as NSString).boundingRect(with: CGSize(width: max(0.0001, textRect.width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: .semibold)], context: nil)
        return TextLayout(sourceRect: rect, textRect: textRect, fontSize: fontSize,
                          lineLimit: max(1, Int((textRect.height + fontSize * 0.001) / fontLineHeight)),
                          coverPadding: lineHeight * 0.06, vertical: nil,
                          canRender: bounds.height <= textRect.height + fontSize * 0.01 && bounds.width <= textRect.width + fontSize * 0.01)
    }

    private struct GlyphMetrics {
        let inkRatio: CGFloat
        let lineHeightRatio: CGFloat
    }

    private static func glyphMetrics(for text: String) -> GlyphMetrics {
        // CTLine includes actual fallback glyphs (e.g. Chinese/Japanese), unlike
        // capHeight alone. Bound measurement work on long model responses.
        let sample = String(text.prefix(256)).replacingOccurrences(of: "\n", with: " ")
        let referenceFont = UIFont.systemFont(ofSize: 100, weight: .semibold)
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
            let font = UIFont.systemFont(ofSize: size, weight: .semibold)
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
        format.preferredRange = .standard
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

    nonisolated struct RestoredRegion: Sendable {
        let image: CGImage
        /// Normalized top-left image coordinates, including sampling margin.
        let rect: CGRect
    }

    static func restorationsAsync(for document: TranslationDocument) async -> [UUID: RestoredRegion] {
        guard let image = restorationImage(document.image) else { return [:] }
        let blocks = document.blocks
        let task = Task.detached(priority: .userInitiated) { restore(image, blocks: blocks) }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private static func restorationImage(_ image: UIImage) -> CGImage? {
        let factor = min(image.scale, 2048 / max(1, max(image.size.width, image.size.height)))
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.cgImage
    }

    private nonisolated static func restore(_ image: CGImage, blocks: [RecognizedBlock]) -> [UUID: RestoredRegion] {
        var result: [UUID: RestoredRegion] = [:]
        let width = CGFloat(image.width), height = CGFloat(image.height)
        for block in blocks where block.placement == .overlay {
            if Task.isCancelled { break }
            let font = block.flow == .vertical ? block.originalColumnWidth * width : block.originalLineHeight * height
            let source = CGRect(x: block.boundingBox.minX * width, y: (1 - block.boundingBox.maxY) * height,
                                width: block.boundingBox.width * width, height: block.boundingBox.height * height)
            let rect = source.insetBy(dx: -font, dy: -font).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard let crop = image.cropping(to: rect), crop.width * crop.height <= 400_000 else { continue }
            var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let cg = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                // A bitmap context drawing a CGImage produces its original row
                // order (same boundary as grayscaleImage). Do not apply UIKit's
                // display flip here; glyph masks use top-left raster rows.
                cg.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                return true
            }
            guard rendered else { continue }
            // Guide removal with the actual glyph bounds and a one-pixel
            // antialias margin. Recovery grows along confirmed ink, rather
            // than widening the mask into surrounding artwork.
            let glyphs = (block.sourceGlyphBoxes ?? [block.boundingBox]).map {
                CGRect(x: $0.minX * width - rect.minX, y: (1 - $0.maxY) * height - rect.minY,
                       width: $0.width * width, height: $0.height * height)
                    .insetBy(dx: -1, dy: -1)
            }
            let patch = TextInkRestoration.restore(pixels: bytes, width: crop.width, height: crop.height, glyphs: glyphs, glyphSize: font)
            let transparent = TextInkRestoration.compositingPixels(original: bytes, patch: patch)
            guard patch.changedPixels > 0, let provider = CGDataProvider(data: Data(transparent) as CFData),
                  let restored = CGImage(width: crop.width, height: crop.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: crop.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
            result[block.id] = RestoredRegion(image: restored, rect: CGRect(x: rect.minX / width, y: rect.minY / height, width: rect.width / width, height: rect.height / height))
        }
        return result
    }

    static func drawRestoration(_ restored: RestoredRegion?, canvas: CGSize, in context: CGContext) {
        guard let restored else { return }
        let r = restored.rect
        let rect = CGRect(x: r.minX * canvas.width, y: r.minY * canvas.height, width: r.width * canvas.width, height: r.height * canvas.height)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(restored.image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// Render an already processed document without repeating OCR or translation.
    static func translatedImage(_ document: TranslationDocument, palette: [UUID: SampledColor], textScale: Double) -> UIImage {
        let width: CGFloat = 390
        let size = CGSize(width: width, height: width * document.image.size.height / max(1, document.image.size.width))
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        format.scale = min(3, 2560 / max(size.width, size.height))
        format.opaque = true
        let restorations = restorationImage(document.image).map { restore($0, blocks: document.blocks) } ?? [:]
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            document.image.draw(in: CGRect(origin: .zero, size: size))
            for block in document.blocks where block.placement == .overlay && block.translation != block.original {
                let layout = textLayout(for: block, canvasSize: size, textScale: textScale)
                if layout.canRender { drawRestoration(restorations[block.id], canvas: size, in: renderer.cgContext) }
            }
            for block in document.blocks where block.placement == .overlay && block.translation != block.original {
                let layout = textLayout(for: block, canvasSize: size, textScale: textScale)
                guard layout.canRender else { continue } // Keep the original intact rather than paint a fragment/ellipsis.
                let color = palette[block.id] ?? SampledColor(red: 1, green: 1, blue: 1)
                drawText(block.translation, layout: layout, color: color.usesDarkText ? .black : .white,
                         isRTL: document.target.isRightToLeft, in: renderer.cgContext)
            }
        }
    }

    /// Shared by the interactive Canvas and exported image, so neither path can
    /// silently substitute a fixed font or truncate a vertical translation.
    static func drawText(_ text: String, layout: TextLayout, color: UIColor, isRTL: Bool, in context: CGContext) {
        guard layout.canRender else { return }
        context.saveGState()
        context.clip(to: layout.textRect.insetBy(dx: -layout.fontSize * 0.08, dy: -layout.fontSize * 0.08))
        UIGraphicsPushContext(context)
        let font = UIFont.systemFont(ofSize: layout.fontSize, weight: .semibold)
        let outline: UIColor = color == .white ? .black : .white
        let ink: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        func draw(_ attributes: [NSAttributedString.Key: Any]) {
            if let vertical = layout.vertical {
                for glyph in vertical.glyphs {
                    let size = (glyph.text as NSString).size(withAttributes: ink)
                    (glyph.text as NSString).draw(at: CGPoint(x: layout.textRect.minX + glyph.center.x - size.width / 2,
                        y: layout.textRect.minY + glyph.center.y - size.height / 2), withAttributes: attributes)
                }
            } else {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = isRTL ? .right : .left
                paragraph.lineBreakMode = .byWordWrapping
                (text as NSString).draw(with: layout.textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes.merging([.paragraphStyle: paragraph]) { _, new in new }, context: nil)
            }
        }
        // A single negative strokeWidth fills first, then paints a centered
        // outline over the glyph. At small image-relative sizes that can erase
        // thin CJK strokes. Paint the outline first and the intact fill last.
        draw(ink.merging([.strokeColor: outline, .strokeWidth: 10]) { _, new in new })
        draw(ink)
        UIGraphicsPopContext()
        context.restoreGState()
    }
}
