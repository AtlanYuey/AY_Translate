import AppIntents
import Foundation
import UniformTypeIdentifiers
import UIKit

extension Notification.Name {
    static let pendingScreenshotReady = Notification.Name("pendingScreenshotReady")
}

enum PendingScreenshotStore {
    nonisolated private static var url: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pending-translate-screen-image")
    }

    nonisolated static func save(_ data: Data) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        Task { @MainActor in
            NotificationCenter.default.post(name: .pendingScreenshotReady, object: nil)
        }
    }

    static func take() -> UIImage? {
        // Remove even malformed/expired handoffs. Never retain a failed import.
        defer { try? FileManager.default.removeItem(at: url) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 120,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return image
    }
}

struct TranslateScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Translate Screenshot in App"
    static let description = IntentDescription(
        "Opens the screenshot in the full editor. Use the installed Screenshot → Share shortcut for an overlay above your current app."
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(
        title: "Screenshot",
        description: "Connect this to the Take Screenshot action directly above it",
        supportedContentTypes: [.image],
        requestValueDialog: "Add Take Screenshot above this action, or choose an image.",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var screenshot: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Translate \(\.$screenshot)")
    }

    func perform() async throws -> some IntentResult {
        try PendingScreenshotStore.save(screenshot.data)
        return .result()
    }

}

struct TranslateScreenshotInAppIntent: AppIntent {
    static let isDiscoverable = false
    static let title: LocalizedStringResource = "Translate Screenshot in App"
    static let description = IntentDescription("Open the full editor to prepare language models, zoom, pan and read all text.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    @Parameter(title: "Screenshot", supportedContentTypes: [.image], inputConnectionBehavior: .connectToPreviousIntentResult)
    var screenshot: IntentFile

    func perform() async throws -> some IntentResult {
        try PendingScreenshotStore.save(screenshot.data)
        return .result()
    }
}

struct TranslateScreenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TranslateScreenshotIntent(),
            phrases: [
                "Translate a screenshot with \(.applicationName)",
                "Open a screenshot in \(.applicationName)"
            ],
            shortTitle: "Translate Screenshot",
            systemImageName: "camera.viewfinder"
        )
    }
}
