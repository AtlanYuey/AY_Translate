import AppIntents
import Foundation
import NaturalLanguage
import SwiftUI
import Translation
import UIKit

@MainActor
final class ShortcutSession: Identifiable {
    enum Continuation { case none, languageModels, slow }
    let id = UUID()
    let state: AppState
    let createdAt = Date()
    var showsOriginal = false
    var renderedImage: UIImage?
    var continuation: Continuation = .none

    init(state: AppState) { self.state = state }
}

@MainActor
final class ShortcutSessionStore {
    static let shared = ShortcutSessionStore()
    private(set) var current: ShortcutSession?
    private var expirationTask: Task<Void, Never>?
    private var foregroundRequest: UUID?
    private let settings: AppSettings
    private let services: ProcessingServices
    private let installedTranslator: ((AppState) async throws -> Bool)?

    init(settings: AppSettings? = nil, services: ProcessingServices? = nil, installedTranslator: ((AppState) async throws -> Bool)? = nil) {
        self.settings = settings ?? .shared
        self.services = services ?? .live
        self.installedTranslator = installedTranslator
    }

    func start(_ image: UIImage) async throws -> UUID {
        if let current { clear(id: current.id) }
        let session = ShortcutSession(state: AppState(settings: settings, history: HistoryStore(), services: services))
        current = session
        session.state.process(image)
        let sessionID = session.id
        expirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
            self?.clear(id: sessionID)
        }
        try await advance(id: session.id)
        return session.id
    }

    func session(id: UUID) -> ShortcutSession? {
        guard let current, current.id == id else { return nil }
        if Date().timeIntervalSince(current.createdAt) > 600 { clear(id: id); return nil }
        return current
    }

    func advance(id: UUID) async throws {
        guard let session = session(id: id) else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while current?.id == id {
            try Task.checkCancellation()
            switch session.state.phase {
            case .idle, .failed, .awaitingConsent: return
            case .ready:
                if session.renderedImage == nil, let document = session.state.document {
                    session.renderedImage = ScreenshotRendering.translatedImage(document, palette: ScreenshotRendering.palette(for: document), textScale: settings.overlayTextScale)
                }
                session.continuation = .none
                return
            case .translating where session.state.appleRequestID != nil:
                let canContinue: Bool
                if let installedTranslator { canContinue = try await installedTranslator(session.state) }
                else { canContinue = await translateWithInstalledModels(session.state) }
                guard canContinue else { session.continuation = .languageModels; return }
            default: break
            }
            if ContinuousClock.now >= deadline { session.continuation = .slow; return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func translateWithInstalledModels(_ state: AppState) async -> Bool {
        guard let document = state.document, let processID = state.appleRequestID,
              let target = document.target.localeLanguage else { return false }
        let source: Locale.Language
        if let explicit = document.source.localeLanguage { source = explicit }
        else {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(document.originalText)
            guard let detected = recognizer.dominantLanguage else { return false }
            source = Locale.Language(identifier: detected.rawValue)
        }
        if source.minimalIdentifier == target.minimalIdentifier {
            state.completeIdentityTranslation(processID: processID)
            return true
        }
        // This public initializer never downloads models or presents permission UI
        // from a background intent. Preparation continues in the app when needed.
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { return false }
        let translation: TranslationSession
        if settings.preference == .speed {
            translation = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else { translation = TranslationSession(installedSource: source, target: target) }
        await state.translate(using: translation, processID: processID)
        return true
    }

    func requestForeground(id: UUID) {
        guard session(id: id) != nil else { return }
        expirationTask?.cancel()
        foregroundRequest = id
        NotificationCenter.default.post(name: .shortcutForegroundRequested, object: nil)
    }

    func takeForegroundRequest() -> ShortcutSession? {
        defer { foregroundRequest = nil }
        guard let id = foregroundRequest, let session = session(id: id) else { return nil }
        // Ownership passes to the full editor. A later background screenshot
        // must not clear the document currently displayed by that editor.
        expirationTask?.cancel()
        expirationTask = nil
        current = nil
        return session
    }

    func clear(state: AppState) {
        guard current?.state === state, let id = current?.id else { return }
        clear(id: id)
    }

    func clear(id: UUID) {
        guard current?.id == id else { return }
        expirationTask?.cancel()
        expirationTask = nil
        current?.state.closeResult()
        current?.renderedImage = nil
        current = nil
        if foregroundRequest == id { foregroundRequest = nil }
    }
}

extension Notification.Name {
    static let shortcutForegroundRequested = Notification.Name("shortcutForegroundRequested")
}

struct ScreenTranslationSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Screenshot Translation Result"
    @Parameter(title: "Result") var sessionID: String
    init() {}
    init(id: UUID) { sessionID = id.uuidString }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        // Rendering is read-only. System redraws never repeat OCR, translation,
        // consent grants or billable requests.
        let session = UUID(uuidString: sessionID).flatMap { ShortcutSessionStore.shared.session(id: $0) }
        return .result(view: ShortcutSnippetView(session: session).environment(\.locale, AppSettings.shared.interfaceLocale))
    }
}

struct UpdateShortcutPreviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Update Translation Preview"
    static let isDiscoverable = false
    @Parameter(title: "Result") var sessionID: String
    @Parameter(title: "Action") var action: String
    init() {}
    init(id: UUID, action: String) { sessionID = id.uuidString; self.action = action }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: sessionID), let session = ShortcutSessionStore.shared.session(id: id) else { return .result() }
        switch action {
        case "original": session.showsOriginal.toggle()
        case "allow": session.state.allowCloudProcessing(); try await ShortcutSessionStore.shared.advance(id: id)
        case "apple": session.state.useAppleEngines(); try await ShortcutSessionStore.shared.advance(id: id)
        case "refresh": try await ShortcutSessionStore.shared.advance(id: id)
        case "close": ShortcutSessionStore.shared.clear(id: id)
        default: break
        }
        return .result()
    }
}

struct OpenShortcutResultIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Translation in App"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground(.immediate)
    @Parameter(title: "Result") var sessionID: String
    init() {}
    init(id: UUID) { sessionID = id.uuidString }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: sessionID) { ShortcutSessionStore.shared.requestForeground(id: id) }
        return .result()
    }
}

private struct ShortcutSnippetView: View {
    let session: ShortcutSession?
    var body: some View {
        Group {
            if let session {
                if session.state.phase == .ready, let document = session.state.document, let rendered = session.renderedImage {
                    if !session.showsOriginal && !document.blocks.contains(where: { $0.placement == .overlay }) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Full Text").font(.caption).foregroundStyle(.secondary)
                            Text(document.translatedText).lineLimit(24)
                            controls(session)
                        }.padding(16)
                    } else {
                        Image(uiImage: session.showsOriginal ? document.image : rendered)
                            .resizable().scaledToFit().frame(maxHeight: 760)
                            .overlay(alignment: .bottomTrailing) { controls(session).padding(12) }
                    }
                } else { continuation(session).padding(20) }
            } else { EmptyView() }
        }
    }

    private func controls(_ session: ShortcutSession) -> some View {
        HStack(spacing: 10) {
            Button(intent: OpenShortcutResultIntent(id: session.id)) { Image(systemName: "ellipsis").frame(width: 42, height: 42) }
                .accessibilityLabel("Open in App")
            Button(intent: UpdateShortcutPreviewIntent(id: session.id, action: "original")) {
                Image(systemName: session.showsOriginal ? "text.viewfinder" : "rectangle.on.rectangle").frame(width: 42, height: 42)
            }.accessibilityLabel("Show Original")
            Button(intent: UpdateShortcutPreviewIntent(id: session.id, action: "close")) { Image(systemName: "xmark").frame(width: 42, height: 42) }
                .accessibilityLabel("Close")
        }.buttonStyle(.bordered).buttonBorderShape(.circle)
    }

    @ViewBuilder private func continuation(_ session: ShortcutSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if session.state.phase == .awaitingConsent {
                Label("Use your selected AI service?", systemImage: "cloud").font(.headline)
                ForEach(session.state.consentDestinations, id: \.self) { Text($0) }
                Button("Continue with AI", intent: UpdateShortcutPreviewIntent(id: session.id, action: "allow"))
                Button("Use Free Apple Engines", intent: UpdateShortcutPreviewIntent(id: session.id, action: "apple"))
            } else {
                if case .failed(let message) = session.state.phase {
                    Text(AppSettings.shared.text(message))
                } else if session.continuation == .languageModels {
                    Text("Prepare Apple language models in the app once, then lightweight previews can translate on device without switching apps.")
                } else { Text("Processing continues. Open the app for progress, or refresh this preview.") }
                Button("Open in App", intent: OpenShortcutResultIntent(id: session.id))
                Button("Refresh Preview", intent: UpdateShortcutPreviewIntent(id: session.id, action: "refresh"))
            }
            Button(intent: UpdateShortcutPreviewIntent(id: session.id, action: "close")) { Image(systemName: "xmark") }
                .accessibilityLabel("Close")
        }
    }
}
