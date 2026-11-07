import UIKit

/// A neutral, generated image validates the real multimodal path without
/// sending a user's photo or silently substituting local OCR results.
enum ImageRecognitionProbe {
    static func jpeg() throws -> Data {
        try autoreleasepool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = true; format.preferredRange = .standard
            let size = CGSize(width: 640, height: 320)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                for (index, line) in ["Hello, world!", "こんにちは", "你好"].enumerated() {
                    (line as NSString).draw(at: CGPoint(x: 40, y: 40 + index * 80), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: UIColor.black
                    ])
                }
            }
            guard let data = image.jpegData(compressionQuality: 0.9) else { throw ScreenReadingError.invalidImage }
            return data
        }
    }
}
