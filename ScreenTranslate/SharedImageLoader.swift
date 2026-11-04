import Foundation
import UniformTypeIdentifiers
import UIKit

enum SharedImageError: LocalizedError {
    case noImage, tooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .noImage: "Share a screenshot or image to translate."
        case .tooLarge: "This image is too large. Share a single screen-sized screenshot."
        case .unavailable: "Shared access is unavailable. Sign the app and extension with the same App Group and Keychain group, then open the app once."
        }
    }
}

@MainActor
enum SharedImageLoader {
    static func load(from items: [NSExtensionItem]) async throws -> UIImage {
        let providers = items.flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
              let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { throw SharedImageError.noImage }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data else { continuation.resume(throwing: SharedImageError.noImage); return }
                continuation.resume(returning: data)
            }
        }
        try Task.checkCancellation()
        guard data.count <= 32 * 1_024 * 1_024 else { throw SharedImageError.tooLarge }
        guard let image = UIImage(data: data) else { throw SharedImageError.noImage }
        guard image.size.width * image.size.height <= 30_000_000 else { throw SharedImageError.tooLarge }
        return image
    }
}
