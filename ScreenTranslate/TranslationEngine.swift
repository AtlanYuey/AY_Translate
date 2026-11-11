// Modified for AY Translate by AtlanYuey (2026). See NOTICE.
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
            // Journal writes happen on the main actor; Vision must not wait for them.
            checkpoint: { point in _ = Task { @MainActor in journal.checkpoint(point, id: id) } })
    }
}
