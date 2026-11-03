import CoreImage
import SwiftUI
import UIKit

@MainActor
enum ScreenshotRendering {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func palette(for document: TranslationDocument) -> [UUID: SampledColor] {
        guard document.image.size.width > 0, document.image.size.height > 0 else { return [:] }
        let factor = min(1, 640 / max(document.image.size.width, document.image.size.height))
        let size = CGSize(width: max(1, floor(document.image.size.width * factor)), height: max(1, floor(document.image.size.height * factor)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            document.image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = upright.cgImage else { return [:] }
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(CIImage(cgImage: cgImage), toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return Dictionary(uniqueKeysWithValues: document.blocks.filter { $0.placement == .overlay }.map {
            ($0.id, BackgroundSampling.sample(pixels: bytes, width: width, height: height, region: $0.boundingBox))
        })
    }

    /// Pre-rendering makes the system snippet lightweight; it never starts OCR or
    /// network requests again when the system asks the snippet to redraw.
    static func translatedImage(_ document: TranslationDocument, palette: [UUID: SampledColor], textScale: Double) -> UIImage {
        let width: CGFloat = 390
        let size = CGSize(width: width, height: width * document.image.size.height / max(1, document.image.size.width))
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(3, 2560 / max(size.width, size.height))
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            document.image.draw(in: CGRect(origin: .zero, size: size))
            for block in document.blocks where block.placement == .overlay && block.translation != block.original {
                let rect = CGRect(x: block.boundingBox.minX * size.width, y: (1 - block.boundingBox.maxY) * size.height,
                                  width: block.boundingBox.width * size.width, height: max(16, block.boundingBox.height * size.height))
                let color = palette[block.id] ?? SampledColor(red: 1, green: 1, blue: 1)
                UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
                renderer.fill(rect.insetBy(dx: -1, dy: -1))
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = document.target.isRightToLeft ? .right : .left
                paragraph.lineBreakMode = .byTruncatingTail
                let fontSize = max(12, min(rect.height / 1.15, min(28, max(12, rect.height * 0.65)) * textScale))
                (block.translation as NSString).draw(in: rect.insetBy(dx: 2, dy: 0), withAttributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: color.usesDarkText ? UIColor.black : UIColor.white,
                    .paragraphStyle: paragraph
                ])
            }
        }
    }
}
