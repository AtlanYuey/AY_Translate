import Foundation
import UniformTypeIdentifiers
import UIKit

enum SharedImageError: LocalizedError, Equatable {
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
    private nonisolated enum Payload: @unchecked Sendable {
        // UIImage is immutable; the other payload values have value semantics.
        case image(UIImage), data(Data), file(URL)
    }

    static func load(from items: [NSExtensionItem]) async throws -> UIImage {
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers {
            try Task.checkCancellation()
            let types = provider.registeredTypeIdentifiers.filter { UTType($0)?.conforms(to: .image) == true }
            for type in types {
                // Prefer the provider's file. Decode in its callback, before
                // temporary access expires, without retaining encoded bytes.
                if let image = try? await fileImage(from: provider, type: type) {
                    try Task.checkCancellation()
                    return try validate(image)
                }
                if let data = try? await encodedData(from: provider, type: type) {
                    try Task.checkCancellation()
                    if let image = try decoded(data) { return image }
                }
                if let item = try? await sharedItem(from: provider, type: type) {
                    try Task.checkCancellation()
                    switch item {
                    case .image(let image): return try validate(image)
                    case .data(let data):
                        if let image = try decoded(data) { return image }
                    case .file(let url):
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                        if let size, size > 32 * 1_024 * 1_024 { throw SharedImageError.tooLarge }
                        if let image = try? ScreenshotInput.decode(file: url, maximumDimension: ScreenshotInput.importDimension) { return try validate(image) }
                    }
                }
            }
            // Some hosts only vend UIImage objects; retain that fallback.
            if provider.canLoadObject(ofClass: UIImage.self), let image = try? await objectImage(from: provider) {
                try Task.checkCancellation()
                return try validate(image)
            }
        }
        try Task.checkCancellation()
        throw SharedImageError.noImage
    }

    private static func fileImage(from provider: NSItemProvider, type: String) async throws -> UIImage {
        let dimension = ScreenshotInput.importDimension
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { continuation.resume(throwing: SharedImageError.noImage); return }
                do { continuation.resume(returning: try ScreenshotInput.decode(file: url, maximumDimension: dimension)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func objectImage(from provider: NSItemProvider) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { continuation.resume(throwing: SharedImageError.noImage); return }
                continuation.resume(returning: image)
            }
        }
    }

    private static func sharedItem(from provider: NSItemProvider, type: String) async throws -> Payload {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let image = item as? UIImage { continuation.resume(returning: .image(image)) }
                else if let data = item as? Data { continuation.resume(returning: .data(data)) }
                else if let url = item as? URL, url.isFileURL { continuation.resume(returning: .file(url)) }
                else { continuation.resume(throwing: SharedImageError.noImage) }
            }
        }
    }

    private static func encodedData(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data else { continuation.resume(throwing: SharedImageError.noImage); return }
                continuation.resume(returning: data)
            }
        }
    }

    private static func decoded(_ data: Data) throws -> UIImage? {
        guard data.count <= 32 * 1_024 * 1_024 else { throw SharedImageError.tooLarge }
        return try? ScreenshotInput.decode(data, maximumDimension: ScreenshotInput.importDimension)
    }

    private static func validate(_ image: UIImage) throws -> UIImage {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        guard pixels.isFinite, pixels > 0, image.cgImage != nil else { throw SharedImageError.noImage }
        guard pixels <= 30_000_000 else { throw SharedImageError.tooLarge }
        return try ScreenshotInput.bounded(image, maximumDimension: ScreenshotInput.importDimension)
    }
}
