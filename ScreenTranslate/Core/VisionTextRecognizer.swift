#if canImport(Vision) && canImport(CoreGraphics)
import Foundation
import CoreGraphics
@preconcurrency import Vision

/// The same local recognizer runs in the app, Share extension and native macOS
/// regression tests. Callers normalize image orientation before this boundary.
nonisolated enum VisionTextRecognizer {
    static func recognize(_ cgImage: CGImage, language: String?) async throws -> [RecognizedBlock] {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let task = Task.detached(priority: .userInitiated) {
            var blocks = try read(cgImage, language: language)
            try Task.checkCancellation()
            // Small print gains resolution in overlapping tiles. Bound the work
            // and keep all boxes in the original upright image coordinate system.
            if max(cgImage.width, cgImage.height) >= 1800 && (blocks.count < 4 || blocks.contains { $0.boundingBox.height < 0.015 }) {
                for x in [0.0, 0.44] {
                    for y in [0.0, 0.44] {
                        try Task.checkCancellation()
                        let region = CGRect(x: x, y: y, width: 0.56, height: 0.56)
                        let pixel = CGRect(x: x * Double(cgImage.width), y: (1 - region.maxY) * Double(cgImage.height), width: 0.56 * Double(cgImage.width), height: 0.56 * Double(cgImage.height))
                        guard let crop = cgImage.cropping(to: pixel) else { continue }
                        let additions = try read(crop, language: language, region: region, originalSize: size)
                        merge(additions, into: &blocks)
                    }
                }
            }
            if language == nil || ["ja", "zh-Hans", "zh-Hant"].contains(language ?? "") {
                let detection = VNDetectTextRectanglesRequest()
                detection.reportCharacterBoxes = true
                #if targetEnvironment(simulator) || os(macOS)
                detection.usesCPUOnly = true
                #endif
                // A supplemental detector failure must not discard successful OCR.
                try? VNImageRequestHandler(cgImage: cgImage).perform([detection])
                let glyphBoxes = (detection.results ?? []).flatMap { $0.characterBoxes ?? [] }.map(\.boundingBox)
                var columns = VerticalOCRGeometry.columns(glyphBoxes, imageSize: size)
                if let raster = grayscaleImage(cgImage) {
                    let inkColumns = VerticalInkDetector.columns(grayscale: raster.bytes, width: raster.width, height: raster.height)
                    for candidate in inkColumns {
                        let box = candidate.reduce(CGRect.null) { $0.union($1) }
                        if !columns.contains(where: { overlap($0.reduce(CGRect.null) { $0.union($1) }, box) >= 0.7 }) { columns.append(candidate) }
                    }
                }
                var attempts = 0
                for column in columns {
                    try Task.checkCancellation()
                    let box = column.reduce(CGRect.null) { $0.union($1) }
                    // Aligned first characters in ordinary horizontal rows can
                    // look like a column. Never overwrite those verified rows.
                    let existing = blocks.filter { overlap($0.boundingBox, box) > 0.7 }
                    let conflicts = VerticalOCRGeometry.horizontalConflicts(column: column, blocks: blocks, imageSize: size)
                    guard !conflicts.protected else { continue }
                    guard attempts < 32 else { break }
                    attempts += 1
                    guard let strip = stripImage(cgImage, glyphs: column) else { continue }
                    let recognized = try read(strip, language: language ?? "ja")
                    let text = recognized.sorted { $0.boundingBox.minX < $1.boundingBox.minX }.map(\.original).joined()
                    guard text.count >= 2, VerticalTextLayout.supports(text),
                          (recognized.map(\.confidence).min() ?? 0) >= 0.4,
                          text.count >= (existing.map { $0.original.filter { !$0.isWhitespace }.count }.max() ?? 0) else { continue }
                    let width = column.map(\.width).sorted()[column.count / 2]
                    let height = column.map(\.height).sorted()[column.count / 2]
                    // Remove fragments only after a complete local transcription
                    // of the same column exists; never erase unknown text.
                    blocks.removeAll { conflicts.fragmentedRows.contains($0.id) || (overlap($0.boundingBox, box) > 0.7 && $0.boundingBox.width < box.width * 1.5) }
                    blocks.append(RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: box,
                        confidence: recognized.map(\.confidence).min() ?? 0, sourceLineHeight: height, flow: .vertical, sourceColumnWidth: width))
                }
            }
            guard !blocks.isEmpty else { throw ScreenReadingError.noText }
            return blocks
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private nonisolated static func read(_ image: CGImage, language: String?, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), originalSize: CGSize? = nil) throws -> [RecognizedBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeight = 0.0025 // Vision's 1/32 default drops small print.
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = language == nil
        let supported = try request.supportedRecognitionLanguages()
        let desired = language.map { [$0] } ?? (Locale.preferredLanguages + ["en-US", "ja-JP", "zh-Hans", "zh-Hant", "ko-KR", "es-ES", "fr-FR", "de-DE", "it-IT", "pt-PT", "ru-RU", "ar-SA"])
        let selected = desired.compactMap { code in supported.first { $0 == code || $0.hasPrefix(code + "-") || code.hasPrefix($0 + "-") } }
        if !selected.isEmpty { request.recognitionLanguages = selected.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
        #if targetEnvironment(simulator) || os(macOS)
        request.usesCPUOnly = true
        #endif
        try VNImageRequestHandler(cgImage: image).perform([request])
        let imageSize = originalSize ?? CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let local = observation.boundingBox
            let box = CGRect(x: region.minX + local.minX * region.width, y: region.minY + local.minY * region.height,
                             width: local.width * region.width, height: local.height * region.height)
            let vertical = VerticalTextLayout.supports(candidate.string) && box.height * imageSize.height > box.width * imageSize.width * 1.8 && candidate.string.count >= 2
            let glyphWidth = min(box.width, box.height * imageSize.height / imageSize.width / CGFloat(max(1, candidate.string.filter { !$0.isWhitespace }.count)))
            return RecognizedBlock(id: UUID(), original: candidate.string, translation: candidate.string, boundingBox: box,
                confidence: candidate.confidence, sourceLineHeight: vertical ? glyphWidth * imageSize.width / imageSize.height : box.height,
                flow: vertical ? .vertical : .horizontal, sourceColumnWidth: vertical ? glyphWidth : nil)
        }
    }

    private nonisolated static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height / max(0.000001, min(a.width * a.height, b.width * b.height))
    }

    private nonisolated static func merge(_ additions: [RecognizedBlock], into blocks: inout [RecognizedBlock]) {
        for addition in additions {
            if let index = blocks.firstIndex(where: { overlap($0.boundingBox, addition.boundingBox) >= 0.7 }) {
                // Prefer the more complete crop result, not a clipped tile edge.
                if addition.original.count >= blocks[index].original.count && addition.confidence > blocks[index].confidence { blocks[index] = addition }
            } else { blocks.append(addition) }
        }
    }

    private nonisolated static func stripImage(_ image: CGImage, glyphs: [CGRect]) -> CGImage? {
        guard !glyphs.isEmpty, glyphs.count <= 80,
              let context = CGContext(data: nil, width: glyphs.count * 48, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: glyphs.count * 48, height: 64))
        for (index, box) in glyphs.enumerated() {
            let rect = CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height), width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height)).insetBy(dx: -1, dy: -1).integral
            guard let glyph = image.cropping(to: rect) else { continue }
            let factor = min(42 / CGFloat(glyph.width), 50 / CGFloat(glyph.height))
            let w = CGFloat(glyph.width) * factor, h = CGFloat(glyph.height) * factor
            context.draw(glyph, in: CGRect(x: CGFloat(index * 48) + (48 - w) / 2, y: (64 - h) / 2, width: w, height: h))
        }
        return context.makeImage()
    }

    private static func grayscaleImage(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let factor = min(1, 1600 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * factor)), height = max(1, Int(Double(image.height) * factor))
        var bytes = [UInt8](repeating: 255, count: width * height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? (bytes, width, height) : nil
    }
}

#endif
