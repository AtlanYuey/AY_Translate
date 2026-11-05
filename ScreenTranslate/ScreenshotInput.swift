import ImageIO
import UIKit

/// Decode directly at a bounded resolution. Share extensions have a much
/// smaller memory budget than the main app; decoding a full photo then resizing
/// it can kill the extension before an error can be displayed.
@MainActor
enum ScreenshotInput {
    static let maximumDimension: CGFloat = 3072

    static func decode(_ data: Data) throws -> UIImage {
        guard data.count <= 32 * 1_024 * 1_024 else { throw SharedImageError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maximumDimension),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw SharedImageError.noImage }
        return try bounded(UIImage(cgImage: image))
    }

    static func bounded(_ image: UIImage) throws -> UIImage {
        guard let cg = image.cgImage, image.size.width > 0, image.size.height > 0 else { throw SharedImageError.noImage }
        if image.imageOrientation == .up, max(cg.width, cg.height) <= Int(maximumDimension), cg.bitsPerComponent <= 8 { return image }
        let factor = min(image.scale, maximumDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
