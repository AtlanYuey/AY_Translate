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

    /// Keep manual enlargement within free space around neighboring source
    /// regions. Compute once for the page and share with screen/export drawing.
    static func textLayouts(for blocks: [RecognizedBlock], canvasSize: CGSize, textScale: Double) -> [UUID: TextLayout] {
        let positioned = blocks.filter { $0.placement == .overlay }
        let bases = Dictionary(uniqueKeysWithValues: positioned.map {
            ($0.id, textLayout(for: $0, canvasSize: canvasSize, textScale: min(1, textScale)))
        })
        return Dictionary(uniqueKeysWithValues: positioned.map { block in
            let base = bases[block.id]!
            guard textScale > 1 else { return (block.id, base) }
            // Split the available gap equally, so two enlarged neighboring
            // translations cannot each consume all of the same free space.
            func collides(_ layout: TextLayout) -> Bool {
                let expanded = layout.textRect.insetBy(dx: -layout.fontSize * 0.08, dy: -layout.fontSize * 0.08)
                return bases.contains { id, other in
                    guard id != block.id, !base.sourceRect.intersects(other.sourceRect) else { return false }
                    let horizontalGap = max(other.sourceRect.minX - base.sourceRect.maxX, base.sourceRect.minX - other.sourceRect.maxX)
                    let verticalGap = max(other.sourceRect.minY - base.sourceRect.maxY, base.sourceRect.minY - other.sourceRect.maxY)
                    if horizontalGap > 0 && verticalGap <= 0 {
                        return expanded.minX < base.sourceRect.minX - horizontalGap / 2 && other.sourceRect.midX < base.sourceRect.midX
                            || expanded.maxX > base.sourceRect.maxX + horizontalGap / 2 && other.sourceRect.midX > base.sourceRect.midX
                    }
                    if verticalGap > 0 && horizontalGap <= 0 {
                        return expanded.minY < base.sourceRect.minY - verticalGap / 2 && other.sourceRect.midY < base.sourceRect.midY
                            || expanded.maxY > base.sourceRect.maxY + verticalGap / 2 && other.sourceRect.midY > base.sourceRect.midY
                    }
                    return false
                }
            }
            let requested = textLayout(for: block, canvasSize: canvasSize, textScale: textScale)
            guard collides(requested) else { return (block.id, requested) }
            var low = 1.0, high = textScale, best = base
            for _ in 0..<6 {
                let middle = (low + high) / 2
                let candidate = textLayout(for: block, canvasSize: canvasSize, textScale: middle)
                if collides(candidate) { high = middle }
                else { low = middle; best = candidate }
            }
            return (block.id, best)
        })
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
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return [:] }
        return Dictionary(uniqueKeysWithValues: blocks.filter { $0.placement == .overlay }.map {
            ($0.id, BackgroundSampling.sample(pixels: bytes, width: width, height: height, region: $0.boundingBox))
        })
    }

    nonisolated struct RestoredRegion: Sendable {
        let image: CGImage
        /// Normalized top-left image coordinates, including sampling margin.
        let rect: CGRect
    }

    static func restorationsAsync(for document: TranslationDocument, showUnchanged: Bool = false) async -> [UUID: RestoredRegion] {
        guard let image = restorationImage(document.image) else { return [:] }
        let blocks = document.blocks.filter { $0.shouldOverlay(showUnchanged: showUnchanged) }
        let task = Task.detached(priority: .userInitiated) { restore(image, blocks: blocks) }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private static func restorationImage(_ image: UIImage) -> CGImage? {
        // Imported images are already upright. Keep that storage and downsample
        // only individual text patches, not another full 2048px bitmap.
        if image.imageOrientation == .up { return image.cgImage }
        return try? ScreenshotInput.bounded(image).cgImage
    }

    private nonisolated static func restore(_ image: CGImage, blocks: [RecognizedBlock]) -> [UUID: RestoredRegion] {
        var result: [UUID: RestoredRegion] = [:]
        var retainedPixels = 0
        for block in blocks where block.placement == .overlay {
            if Task.isCancelled { break }
            let restored = autoreleasepool { restoreRegion(image, block: block) }
            if let restored {
                let pixels = restored.image.width * restored.image.height
                // Bound accumulated patches too, not only each temporary crop.
                if retainedPixels + pixels <= 4_000_000 {
                    result[block.id] = restored
                    retainedPixels += pixels
                }
            }
        }
        return result
    }

    private nonisolated static func restoreRegion(_ image: CGImage, block: RecognizedBlock) -> RestoredRegion? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let font = block.flow == .vertical ? block.originalColumnWidth * width : block.originalLineHeight * height
        let source = CGRect(x: block.boundingBox.minX * width, y: (1 - block.boundingBox.maxY) * height,
                            width: block.boundingBox.width * width, height: block.boundingBox.height * height)
        let rect = source.insetBy(dx: -font, dy: -font).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isEmpty, let crop = image.cropping(to: rect) else { return nil }
        let factor = min(1, 2048 / max(width, height), sqrt(390_000 / (rect.width * rect.height)))
        let w = max(1, Int(ceil(rect.width * factor))), h = max(1, Int(ceil(rect.height * factor)))
        let sx = CGFloat(w) / rect.width, sy = CGFloat(h) / rect.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let cg = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            cg.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered, !Task.isCancelled else { return nil }
        let glyphs = (block.sourceGlyphBoxes ?? [block.boundingBox]).map {
            CGRect(x: ($0.minX * width - rect.minX) * sx, y: ((1 - $0.maxY) * height - rect.minY) * sy,
                   width: $0.width * width * sx, height: $0.height * height * sy).insetBy(dx: -1, dy: -1)
        }
        let patch = TextInkRestoration.restore(pixels: bytes, width: w, height: h, glyphs: glyphs, glyphSize: font * min(sx, sy))
        guard patch.changedPixels > 0, !Task.isCancelled else { return nil }
        let transparent = TextInkRestoration.compositingPixels(original: bytes, patch: patch)
        guard let provider = CGDataProvider(data: Data(transparent) as CFData),
              let restored = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return RestoredRegion(image: restored, rect: CGRect(x: rect.minX / width, y: rect.minY / height, width: rect.width / width, height: rect.height / height))
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
    static func translatedImage(_ document: TranslationDocument, palette: [UUID: SampledColor], textScale: Double, showUnchanged: Bool = false) -> UIImage {
        let width: CGFloat = 390
        let naturalSize = CGSize(width: width, height: width * document.image.size.height / max(1, document.image.size.width))
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        format.scale = min(3, 2560 / max(naturalSize.width, naturalSize.height))
        format.opaque = true
        // The renderer rounds fractional pixel dimensions up. Draw through the
        // same pixel boundary so an opaque canvas cannot leave a black last row.
        let size = CGSize(width: ceil(naturalSize.width * format.scale) / format.scale,
                          height: ceil(naturalSize.height * format.scale) / format.scale)
        let restorations = restorationImage(document.image).map { restore($0, blocks: document.blocks.filter { $0.shouldOverlay(showUnchanged: showUnchanged) }) } ?? [:]
        let layouts = textLayouts(for: document.blocks, canvasSize: size, textScale: textScale)
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            document.image.draw(in: CGRect(origin: .zero, size: size))
            for block in document.blocks where block.shouldOverlay(showUnchanged: showUnchanged) {
                guard let layout = layouts[block.id] else { continue }
                if layout.canRender { drawRestoration(restorations[block.id], canvas: size, in: renderer.cgContext) }
            }
            for block in document.blocks where block.shouldOverlay(showUnchanged: showUnchanged) {
                guard let layout = layouts[block.id] else { continue }
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
