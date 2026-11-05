import Foundation
import UIKit

/// Injectable boundaries keep the local route independent of cloud services and
/// let simulator tests exercise cancellation/failures without paid API calls.
@MainActor
struct ProcessingServices {
    var vision: (UIImage, AppLanguage) async throws -> [RecognizedBlock]
    var aiOCR: (UIImage, [RecognizedBlock], AIServiceConfiguration, String) async throws -> OCRResult
    var aiTranslation: ([RecognizedBlock], AppLanguage, AppLanguage, TranslationPreference, AIServiceConfiguration, String) async throws -> [UUID: String]

    static var live: ProcessingServices {
        // Reuse the ephemeral connection pool for OCR, translation and retries;
        // keep cookies/cache disabled without repeating TLS setup per operation.
        let client = OpenAIClient()
        return ProcessingServices(
            vision: { try await ScreenReader.recognize(in: $0, source: $1) },
            aiOCR: { image, anchors, configuration, key in
                let data = try screenshotJPEG(image)
                return try await client.recognize(imageData: data, anchors: anchors, configuration: configuration, apiKey: key)
            },
            aiTranslation: { blocks, source, target, preference, configuration, key in
                try await client.translate(blocks, source: source == .automatic ? "auto-detect" : source.name, target: target.name + " (" + target.rawValue + ")", preference: preference, configuration: configuration, apiKey: key)
            }
        )
    }

    private static func screenshotJPEG(_ image: UIImage) throws -> Data {
        let maxDimension: CGFloat = 2_048
        guard image.size.width > 0, image.size.height > 0 else { throw ScreenReadingError.invalidImage }
        let factor = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.88) else { throw ScreenReadingError.invalidImage }
        return data
    }
}
