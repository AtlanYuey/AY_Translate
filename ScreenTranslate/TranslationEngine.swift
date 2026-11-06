import Foundation
import UIKit

enum ScreenReader {
    static func recognize(in image: UIImage, source: AppLanguage) async throws -> [RecognizedBlock] {
        guard image.size.width > 0, image.size.height > 0 else { throw ScreenReadingError.invalidImage }
        // Most screenshots already have upright 8-bit pixels. Reuse them rather
        // than allocating another full-size extended-range bitmap for Vision.
        let upright = try ScreenshotInput.bounded(image)
        guard let cgImage = upright.cgImage else { throw ScreenReadingError.invalidImage }
        return try await VisionTextRecognizer.recognize(cgImage, language: source.recognitionCode,
            memoryLimited: ProcessingMemory.isExtension, underPressure: ProcessingMemory.isConstrained)
    }
}
