#if canImport(Vision) && canImport(CoreGraphics)
import Foundation
import CoreGraphics
import CoreML
@preconcurrency import Vision

/// The same local recognizer runs in the app, Share extension and native macOS
/// regression tests. Callers normalize image orientation before this boundary.
nonisolated enum VisionTextRecognizer {
    private static let workGate = SerialWorkGate()

    static func recognize(_ cgImage: CGImage, language: String?, memoryLimited: Bool = false, underPressure: Bool = false,
                          resourcePolicy: (@Sendable () async -> OCRResourcePolicy)? = nil,
                          checkpoint: (@Sendable (String) async -> Void)? = nil) async throws -> [RecognizedBlock] {
        try await workGate.run {
            // Recheck after queued work drains; a snapshot taken before waiting
            // would miss pressure left by the preceding screenshot.
            let policy = await resourcePolicy?() ?? OCRResourcePolicy(memoryLimited: memoryLimited, recentWarning: underPressure)
            return try await recognizeSerial(cgImage, language: language, policy: policy, checkpoint: checkpoint)
        }
    }

    private static func recognizeSerial(_ image: CGImage, language: String?, policy: OCRResourcePolicy,
                                        checkpoint: (@Sendable (String) async -> Void)?) async throws -> [RecognizedBlock] {
        try Task.checkCancellation()
        if #available(iOS 26.0, macOS 26.0, *) {
            var blocks: [RecognizedBlock] = []
            let regions = policy.regions(for: CGSize(width: image.width, height: image.height))
            for (index, region) in regions.enumerated() {
                try Task.checkCancellation()
                await checkpoint?(policy.prefersCPU ? "document_cpu_\(index + 1)_begin" : "document_begin")
                do {
                    // The scoped helper releases each crop and all document
                    // observations before the next tile is allocated.
                    let additions = try await readDocumentRegion(image, region: region, language: language, preferCPU: policy.prefersCPU)
                    mergeDocument(additions, into: &blocks)
                } catch { try Task.checkCancellation() }
                await checkpoint?("document_\(index + 1)_end")
            }
            if !blocks.isEmpty {
                await checkpoint?("coverage_begin")
                let result = try await supplementVerticalGaps(image, blocks: blocks, language: language,
                    detectionImage: boundedWorkingImage(image, maximum: 1600), cpuOnly: policy.prefersCPU)
                await checkpoint?("coverage_end")
                return result
            }
        }
        await checkpoint?("legacy_begin")
        let working = policy.memoryLimited ? (boundedWorkingImage(image, maximum: policy.tileDimension) ?? image) : image
        let result = try await recognizeLegacy(working, language: language, cpuOnly: policy.prefersCPU)
        await checkpoint?("legacy_end")
        return result
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func readDocumentRegion(_ image: CGImage, region: CGRect, language: String?, preferCPU: Bool) async throws -> [RecognizedBlock] {
        let pixel = CGRect(x: region.minX * CGFloat(image.width), y: (1 - region.maxY) * CGFloat(image.height),
                           width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropping(to: pixel) else { return [] }
        let actual = CGRect(x: pixel.minX / CGFloat(image.width), y: 1 - pixel.maxY / CGFloat(image.height),
                            width: pixel.width / CGFloat(image.width), height: pixel.height / CGFloat(image.height))
        return try await readDocument(crop, language: language, preferCPU: preferCPU).map { block in
            func box(_ local: CGRect) -> CGRect {
                CGRect(x: actual.minX + local.minX * actual.width, y: actual.minY + local.minY * actual.height,
                       width: local.width * actual.width, height: local.height * actual.height)
            }
            return RecognizedBlock(id: block.id, original: block.original, translation: block.translation,
                boundingBox: box(block.boundingBox), confidence: block.confidence, placement: block.placement,
                sourceLineHeight: block.originalLineHeight * actual.height, flow: block.flow,
                sourceColumnWidth: block.sourceColumnWidth.map { $0 * actual.width }, sourceGlyphBoxes: block.sourceGlyphBoxes?.map(box))
        }
    }

    private static func mergeDocument(_ additions: [RecognizedBlock], into blocks: inout [RecognizedBlock]) {
        for addition in additions {
            if let index = blocks.firstIndex(where: {
                $0.flow == addition.flow && overlap($0.boundingBox, addition.boundingBox) >= 0.7
                    && ($0.flow != .vertical || abs($0.boundingBox.midX - addition.boundingBox.midX) < max($0.boundingBox.width, addition.boundingBox.width) * 0.5)
            }) {
                let old = blocks[index]
                if addition.original.count > old.original.count && addition.confidence >= old.confidence * 0.8
                    || addition.original.count == old.original.count && addition.confidence > old.confidence { blocks[index] = addition }
            } else { blocks.append(addition) }
        }
    }

    private static func boundedWorkingImage(_ image: CGImage, maximum: Int) -> CGImage? {
        guard max(image.width, image.height) > maximum else { return image }
        return autoreleasepool {
            let factor = Double(maximum) / Double(max(image.width, image.height))
            let width = max(1, Int(Double(image.width) * factor)), height = max(1, Int(Double(image.height) * factor))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
    }

    /// Check only uncovered vertical runs, not every recognized column. Never
    /// upload additional images or discard successful native OCR on a failure.
    static func supplementVerticalGaps(_ image: CGImage, blocks: [RecognizedBlock], language: String?, detectionImage: CGImage? = nil, cpuOnly: Bool = false) async throws -> [RecognizedBlock] {
        guard language == nil || language == "ja" || language?.hasPrefix("zh") == true || blocks.contains(where: {
            $0.flow == .vertical || $0.original.unicodeScalars.contains { (0x3041...0x30FF).contains($0.value) }
        }) else { return blocks }
        let task = Task.detached(priority: .userInitiated) {
            return try autoreleasepool {
            guard let raster = grayscaleImage(image) else { return blocks }
            let size = CGSize(width: image.width, height: image.height)
            let inkColumns = VerticalInkDetector.columns(grayscale: raster.bytes, width: raster.width, height: raster.height)
            // Halftones, outlines and art behind a glyph can defeat the local
            // uniform-ring detector. Vision's independent character detector
            // supplies extra geometry; only uncovered columns are transcribed.
            let detection = VNDetectTextRectanglesRequest()
            detection.reportCharacterBoxes = true
            detection.preferBackgroundProcessing = true
            detection.usesCPUOnly = cpuOnly
            #if targetEnvironment(simulator) || os(macOS)
            detection.usesCPUOnly = true
            #endif
            try? VNImageRequestHandler(cgImage: detectionImage ?? image).perform([detection])
            try Task.checkCancellation()
            let detected = VerticalOCRGeometry.columns((detection.results ?? []).flatMap { $0.characterBoxes ?? [] }.map(\.boundingBox), imageSize: size)
            let columns = VerticalOCRGeometry.mergingColumns(detected, supplemental: inkColumns)
            let missing = OCRCoverage.uncoveredColumns(columns, blocks: blocks, imageSize: size)
            var result = blocks
            let pending = Array(missing.prefix(32))
            // Four upright columns become four horizontal rows in one small
            // OCR request. This covers short bubbles beyond the old six-column
            // limit without starting a separate Vision request for every column.
            for start in stride(from: 0, to: pending.count, by: 4) {
                try Task.checkCancellation()
                let batch = Array(pending[start..<min(start + 4, pending.count)])
                guard let rows = try? autoreleasepool(invoking: { try readColumns(image, columns: batch, language: language ?? "ja", cpuOnly: cpuOnly) }) else { continue }
                for (column, recognized) in zip(batch, rows) {
                    guard !OCRCoverage.uncoveredColumns([column], blocks: result, imageSize: size).isEmpty else { continue }
                    let text = recognized.sorted { $0.boundingBox.minX < $1.boundingBox.minX }.map(\.original).joined()
                    guard text.count >= 2, VerticalTextLayout.supports(text),
                          text.count >= column.count / 2, text.count <= column.count * 2,
                          (recognized.map(\.confidence).min() ?? 0) >= 0.45 else { continue }
                    let box = column.reduce(CGRect.null) { $0.union($1) }
                    let conflicts = VerticalOCRGeometry.horizontalConflicts(column: column, blocks: result, imageSize: size)
                    guard !conflicts.protected, !result.contains(where: {
                        $0.flow == .vertical && overlap(box, $0.boundingBox) > 0.7 && $0.original.count >= text.count
                            && OCRCoverage.uncoveredColumns([column], blocks: [$0], imageSize: size).isEmpty
                    }) else { continue }
                    // Replace a partial fragment only once the complete local run
                    // was successfully read; independent bubbles stay independent.
                    result.removeAll { block in
                        if conflicts.fragmentedRows.contains(block.id) { return true }
                        return block.flow == .vertical && text.count >= block.original.count
                            && !OCRCoverage.uncoveredColumns([column], blocks: [block], imageSize: size).isEmpty
                            && box.contains(CGPoint(x: block.boundingBox.midX, y: block.boundingBox.midY))
                            && overlap(box, block.boundingBox) > 0.7
                    }
                    let widths = column.map(\.width).sorted(), heights = column.map(\.height).sorted()
                    result.append(RecognizedBlock(id: UUID(), original: text, translation: text, boundingBox: box,
                        confidence: recognized.map(\.confidence).min() ?? 0, sourceLineHeight: heights[heights.count / 2],
                        flow: .vertical, sourceColumnWidth: widths[widths.count / 2], sourceGlyphBoxes: column))
                }
            }
            return result
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func recognizeLegacy(_ cgImage: CGImage, language: String?, cpuOnly: Bool = false) async throws -> [RecognizedBlock] {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let task = Task.detached(priority: .userInitiated) {
            return try autoreleasepool {
            var blocks = try read(cgImage, language: language, cpuOnly: cpuOnly)
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
                        let additions = try read(crop, language: language, region: region, originalSize: size, cpuOnly: cpuOnly)
                        merge(additions, into: &blocks)
                    }
                }
            }
            if language == nil || ["ja", "zh-Hans", "zh-Hant"].contains(language ?? "") {
                let detection = VNDetectTextRectanglesRequest()
                detection.reportCharacterBoxes = true
                detection.preferBackgroundProcessing = true
                detection.usesCPUOnly = cpuOnly
                #if targetEnvironment(simulator) || os(macOS)
                detection.usesCPUOnly = true
                #endif
                // A supplemental detector failure must not discard successful OCR.
                try? VNImageRequestHandler(cgImage: cgImage).perform([detection])
                let glyphBoxes = (detection.results ?? []).flatMap { $0.characterBoxes ?? [] }.map(\.boundingBox)
                var columns = VerticalOCRGeometry.columns(glyphBoxes, imageSize: size)
                if let raster = grayscaleImage(cgImage) {
                    let inkColumns = VerticalInkDetector.columns(grayscale: raster.bytes, width: raster.width, height: raster.height)
                    columns = VerticalOCRGeometry.mergingColumns(columns, supplemental: inkColumns)
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
                    let recognized = try read(strip, language: language ?? "ja", cpuOnly: cpuOnly)
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
                        confidence: recognized.map(\.confidence).min() ?? 0, sourceLineHeight: height, flow: .vertical, sourceColumnWidth: width, sourceGlyphBoxes: column))
                }
            }
            guard !blocks.isEmpty else { throw ScreenReadingError.noText }
            return blocks
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func readDocument(_ image: CGImage, language: String?, preferCPU: Bool = false) async throws -> [RecognizedBlock] {
        var request = RecognizeDocumentsRequest()
        if preferCPU {
            for (stage, devices) in request.supportedComputeStageDevices {
                if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
        request.barcodeDetectionOptions.enabled = false
        request.textRecognitionOptions.maximumCandidateCount = 1
        request.textRecognitionOptions.minimumTextHeightFraction = 0.0025
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.automaticallyDetectLanguage = language == nil
        // Automatic detection still needs a multilingual candidate list; the
        // framework's initial recognitionLanguages can otherwise favor English.
        let desired = language.map { [$0] } ?? (Locale.preferredLanguages + ["ja", "zh-Hans", "zh-Hant", "en", "ko", "es", "fr", "de", "it", "pt", "ru", "ar"])
        let supported = request.supportedRecognitionLanguages
        var languages: [Locale.Language] = []
        for code in desired {
            if let match = supported.first(where: { $0.minimalIdentifier == Locale.Language(identifier: code).minimalIdentifier }),
               !languages.contains(match) { languages.append(match) }
        }
        if !languages.isEmpty { request.textRecognitionOptions.recognitionLanguages = languages }
        let observations = try await request.perform(on: image)
        try Task.checkCancellation()
        return observations.flatMap { observation in
            observation.document.text.lines.compactMap { line -> RecognizedBlock? in
                guard let candidate = line.topCandidates(1).first,
                      !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let box = line.boundingRegion.boundingBox.cgRect
                let vertical = line.textDirection == .topToBottom || (VerticalTextLayout.supports(candidate.string)
                    && box.height * CGFloat(image.height) > box.width * CGFloat(image.width) * 2.2 && candidate.string.count >= 3)
                // These are guidance boxes. Background restoration still segments
                // the actual ink within them instead of erasing the rectangles.
                let glyphs = candidate.string.indices.prefix(256).compactMap { index -> CGRect? in
                    guard !candidate.string[index].isWhitespace else { return nil }
                    let end = candidate.string.index(after: index)
                    return candidate.boundingBox(for: index..<end)?.boundingBox.cgRect
                }
                let widths = glyphs.map(\.width).filter { $0 > 0 }.sorted()
                let heights = glyphs.map(\.height).filter { $0 > 0 }.sorted()
                let width = widths.isEmpty ? box.width : widths[widths.count / 2]
                let height = heights.isEmpty ? box.height : heights[heights.count / 2]
                return RecognizedBlock(id: UUID(), original: candidate.string, translation: candidate.string,
                    boundingBox: box, confidence: candidate.confidence, sourceLineHeight: vertical ? height : box.height,
                    flow: vertical ? .vertical : .horizontal, sourceColumnWidth: vertical ? width : nil,
                    sourceGlyphBoxes: glyphs.isEmpty ? nil : glyphs)
            }
        }
    }

    private nonisolated static func read(_ image: CGImage, language: String?, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), originalSize: CGSize? = nil, cpuOnly: Bool = false) throws -> [RecognizedBlock] {
        return try autoreleasepool {
        let request = VNRecognizeTextRequest()
        request.preferBackgroundProcessing = true
        request.usesCPUOnly = cpuOnly
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

    private static func readColumns(_ image: CGImage, columns: [[CGRect]], language: String, cpuOnly: Bool = false) throws -> [[RecognizedBlock]] {
        let width = max(48, (columns.map(\.count).max() ?? 1) * 48)
        let height = columns.count * 96
        guard columns.count <= 4, width <= 3840, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, column) in columns.enumerated() {
            try Task.checkCancellation()
            if let strip = stripImage(image, glyphs: column) {
                context.draw(strip, in: CGRect(x: 0, y: height - (index + 1) * 96 + 16, width: strip.width, height: 64))
            }
        }
        guard let composite = context.makeImage() else { return [] }
        let recognized = try read(composite, language: language, cpuOnly: cpuOnly)
        var rows = [[RecognizedBlock]](repeating: [], count: columns.count)
        for block in recognized {
            let row = Int((1 - block.boundingBox.midY) * CGFloat(height) / 96)
            // Reject a spurious box spanning two packed rows.
            if rows.indices.contains(row), block.boundingBox.height * CGFloat(height) < 80 { rows[row].append(block) }
        }
        return rows
    }

    nonisolated static func stripImage(_ image: CGImage, glyphs: [CGRect]) -> CGImage? {
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

    static func grayscaleImage(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
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
