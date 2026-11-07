import Foundation
import UIKit

enum ScreenReader {
    static func recognize(in image: UIImage, source: AppLanguage) async throws -> [RecognizedBlock] {
        guard image.size.width > 0, image.size.height > 0 else { throw ScreenReadingError.invalidImage }
        // Most screenshots already have upright 8-bit pixels. Reuse them rather
        // than allocating another full-size extended-range bitmap for Vision.
        let upright = try ScreenshotInput.bounded(image)
        guard let cgImage = upright.cgImage else { throw ScreenReadingError.invalidImage }
        let journal = ProcessingDiagnostics.shared
        let id = journal.currentID
        return try await VisionTextRecognizer.recognize(cgImage, language: source.recognitionCode,
            resourcePolicy: { await MainActor.run { ProcessingMemory.ocrPolicy } },
            checkpoint: { point in await MainActor.run { journal.checkpoint(point, id: id) } })
    }
}
