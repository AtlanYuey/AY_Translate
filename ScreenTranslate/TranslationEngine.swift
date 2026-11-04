import Foundation
import UIKit

enum ScreenReader {
    static func recognize(in image: UIImage, source: AppLanguage) async throws -> [RecognizedBlock] {
        guard image.size.width > 0, image.size.height > 0 else { throw ScreenReadingError.invalidImage }
        // Normalize EXIF orientation once, before cropping or mapping coordinates.
        let factor = min(image.scale, 4096 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = upright.cgImage else { throw ScreenReadingError.invalidImage }
        return try await VisionTextRecognizer.recognize(cgImage, language: source.recognitionCode)
    }
}
