import Combine
import Foundation
import SwiftUI
import Translation
import UIKit
import NaturalLanguage

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle, awaitingConsent, reading, translating, preparing, ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var document: TranslationDocument?
    @Published private(set) var translationConfiguration: TranslationSession.Configuration?
    @Published var presentsResult = false
    @Published private(set) var translatedBlockCount = 0
    @Published private(set) var totalBlockCount = 0
    @Published private(set) var notice: String?
    @Published private(set) var consentDestinations: [String] = []
    @Published private(set) var appleRequestID: UUID?

    let settings: AppSettings
    let history: HistoryStore
    var hasSourceImage: Bool { sourceImage != nil }

    private let services: ProcessingServices
    @Published private(set) var sourceImage: UIImage?
    private var previewID = UUID()
    /// A failed OCR/translation must never replace the user's image with a blank screen.
    var displayedDocument: TranslationDocument? {
        if let document { return document }
        guard let sourceImage else { return nil }
        return TranslationDocument(id: previewID, image: sourceImage, blocks: [], source: settings.source, target: settings.target, createdAt: Date())
    }
    private var activeProcessID: UUID?
    private var processingTask: Task<Void, Never>?
    private var pendingConsentIDs: [AIProfile: String] = [:]
    private var cachedAppleConfiguration: TranslationSession.Configuration?
    private var cachedAppleLanguages = ""
    private var pendingAppleIDs = Set<UUID>()
    private var appleResolvedSource: Locale.Language?

    init(settings: AppSettings, history: HistoryStore, services: ProcessingServices? = nil) {
        self.settings = settings
        self.history = history
        self.services = services ?? .live
    }

    func process(_ image: UIImage) {
        cancelCurrentWork()
        let processID = UUID()
        previewID = processID
        activeProcessID = processID
        sourceImage = image // Retain for OCR failure/retry; released on Close.
        document = nil
        notice = nil
        translatedBlockCount = 0
        totalBlockCount = 0
        presentsResult = true

        let ocrEngine = settings.ocrEngine
        let translator = settings.translationEngine
        let source = settings.source
        let target = settings.target
        let preference = settings.preference
        let ocrConfiguration = settings.aiOCR
        let translationConfiguration = settings.aiTranslation
        let profiles: [AIProfile] = (ocrEngine == .ai ? [.ocr] : []) + (translator == .ai ? [.translation] : [])
        pendingConsentIDs = [:]
        do {
            for profile in profiles { try settings.configuration(for: profile).validate() }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        let missingConsent = profiles.filter { !settings.hasConsent(for: $0) }
        if !missingConsent.isEmpty {
            pendingConsentIDs = Dictionary(uniqueKeysWithValues: profiles.map { ($0, settings.consentIdentity(for: $0)) })
            consentDestinations = missingConsent.map { profile in
                let host = (try? settings.configuration(for: profile).endpoint().host) ?? "selected provider"
                return (settings.selectedService(for: profile)?.name ?? "") + " · " + settings.text(profile == .ocr ? "Screenshot" : "Recognized Text") + " → " + host
            }
            phase = .awaitingConsent
            return
        }
        consentDestinations = []
        // Snapshot each key together with its approved endpoint before the first
        // suspension. Editing Settings during OCR must not send a new key to an
        // older request's destination.
        let ocrKey: String
        let translationKey: String
        do {
            ocrKey = ocrEngine == .ai ? try settings.readAPIKey(for: .ocr) : ""
            translationKey = translator == .ai ? try settings.readAPIKey(for: .translation) : ""
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        phase = .reading
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { if activeProcessID == processID { processingTask = nil } }
            do {
                let result: OCRResult
                if ocrEngine == .appleVision {
                    result = OCRResult(blocks: try await services.vision(image, source))
                } else {
                    // Local anchors validate AI positions. A failed AI request can
                    // fall back locally; the reverse never uploads without consent.
                    var anchors: [RecognizedBlock] = []
                    do { anchors = try await services.vision(image, source) }
                    catch { try Task.checkCancellation() }
                    try Task.checkCancellation()
                    do {
                        result = try await services.aiOCR(image, anchors, ocrConfiguration, ocrKey)
                    } catch {
                        try Task.checkCancellation()
                        guard !anchors.isEmpty else { throw error }
                        result = OCRResult(blocks: anchors, notice: "AI OCR was unavailable. Apple Vision was used locally; you can retry with another engine.")
                    }
                }
                guard isActive(processID) else { return }
                guard !result.blocks.isEmpty else { throw ScreenReadingError.noText }
                let blocks = TranslationPlanner.paragraphs(result.blocks, preference: preference)
                notice = result.notice
                document = TranslationDocument(id: processID, image: image, blocks: blocks, source: source, target: target, createdAt: Date())
                totalBlockCount = blocks.count
                if source != .automatic && source == target {
                    translatedBlockCount = blocks.count
                    finish(processID)
                } else if translator == .apple {
                    pendingAppleIDs = Set(blocks.filter { !Self.alreadyInTargetLanguage($0.original, target: target) }.map(\.id))
                    translatedBlockCount = blocks.count - pendingAppleIDs.count
                    if pendingAppleIDs.isEmpty { finish(processID); return }
                    let pendingText = blocks.filter { pendingAppleIDs.contains($0.id) }.map(\.original).joined(separator: "\n")
                    let detected = NLLanguageRecognizer.dominantLanguage(for: pendingText)
                    let resolvedSource = source.localeLanguage ?? detected.flatMap { $0 == .undetermined ? nil : Locale.Language(identifier: $0.rawValue) }
                    appleResolvedSource = resolvedSource
                    if resolvedSource?.minimalIdentifier == target.localeLanguage?.minimalIdentifier {
                        translatedBlockCount = blocks.count
                        finish(processID)
                        return
                    }
                    phase = .translating
                    appleRequestID = processID
                    let signature = (resolvedSource?.minimalIdentifier ?? source.rawValue) + ":" + target.rawValue + ":" + preference.rawValue
                    if signature != cachedAppleLanguages || cachedAppleConfiguration == nil {
                        cachedAppleLanguages = signature
                        cachedAppleConfiguration = preference == .speed
                            ? TranslationSession.Configuration(source: resolvedSource, target: target.localeLanguage, preferredStrategy: .lowLatency)
                            : TranslationSession.Configuration(source: resolvedSource, target: target.localeLanguage)
                    }
                    // Repeated screenshots with the same languages must restart
                    // the view-bound session even if SwiftUI coalesces updates.
                    cachedAppleConfiguration?.invalidate()
                    self.translationConfiguration = cachedAppleConfiguration
                } else {
                    phase = .translating
                    let translations = try await services.aiTranslation(blocks, source, target, preference, translationConfiguration, translationKey)
                    guard isActive(processID), var current = document else { return }
                    guard current.blocks.allSatisfy({ translations[$0.id]?.isEmpty == false }) else { throw AIServiceError.incompleteTranslation }
                    for index in current.blocks.indices { current.blocks[index].translation = translations[current.blocks[index].id]! }
                    document = current
                    translatedBlockCount = current.blocks.count
                    finish(processID)
                }
            } catch {
                guard isActive(processID) else { return }
                // Only local, sanitized client errors reach this screen. Never log screenshots, text, keys, or provider bodies.
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func allowCloudProcessing() {
        guard phase == .awaitingConsent, let image = sourceImage else { return }
        let selected: [AIProfile] = (settings.ocrEngine == .ai ? [.ocr] : []) + (settings.translationEngine == .ai ? [.translation] : [])
        guard Set(selected) == Set(pendingConsentIDs.keys), pendingConsentIDs.allSatisfy({ settings.consentIdentity(for: $0.key) == $0.value }) else {
            process(image) // Changed settings require a new, accurate disclosure.
            return
        }
        if settings.ocrEngine == .ai { settings.grantConsent(for: .ocr) }
        if settings.translationEngine == .ai { settings.grantConsent(for: .translation) }
        process(image)
    }

    func useAppleEngines() {
        settings.ocrEngine = .appleVision
        settings.translationEngine = .apple
        retry()
    }

    func translate(using session: TranslationSession, processID: UUID?) async {
        guard let processID, isActive(processID), appleRequestID == processID,
              phase == .translating, var current = document else { return }
        do {
            // prepareTranslation throws when source is nil. Resolve it locally
            // first when possible, then let the system request model downloads.
            if appleResolvedSource != nil {
                phase = .preparing
                try await session.prepareTranslation()
                guard isActive(processID) else { session.cancel(); return }
                phase = .translating
            }
            let requests = current.blocks.filter { pendingAppleIDs.contains($0.id) }.map { TranslationSession.Request(sourceText: $0.original, clientIdentifier: $0.id.uuidString) }
            let indices = Dictionary(uniqueKeysWithValues: current.blocks.indices.map { (current.blocks[$0].id.uuidString, $0) })
            var completed = Set<String>()
            for try await response in session.translate(batch: requests) {
                guard isActive(processID) else { session.cancel(); return }
                guard let key = response.clientIdentifier, let index = indices[key],
                      !response.targetText.isEmpty, completed.insert(key).inserted else { continue }
                current.blocks[index].translation = response.targetText
                translatedBlockCount = current.blocks.count - pendingAppleIDs.count + completed.count
                document = current
            }
            guard isActive(processID) else { return }
            guard completed.count == requests.count else { throw AIServiceError.incompleteTranslation }
            finish(processID)
        } catch {
            guard isActive(processID) else { return }
            // Keep completed regions and all remaining originals visible. A
            // single unsupported label must not discard an otherwise useful image.
            if current.blocks.contains(where: { $0.translation != $0.original }) {
                notice = "Some regions could not be translated. Their original text is preserved; tap a translated region to read it in full."
                document = current
                finish(processID)
                return
            }
            let detected = NLLanguageRecognizer.dominantLanguage(for: current.originalText)
            let source = appleResolvedSource ?? current.source.localeLanguage ?? detected.map { Locale.Language(identifier: $0.rawValue) }
            if let source, let target = current.target.localeLanguage,
               source.minimalIdentifier != target.minimalIdentifier,
               await LanguageAvailability().status(from: source, to: target) == .unsupported {
                guard isActive(processID) else { return }
                phase = .failed("Apple Translation does not support this language pair. Choose an AI translation service in More, or change the source and target languages.")
            } else {
                guard isActive(processID) else { return }
                phase = .failed(AppLocalization.formatted("Translation couldn’t be completed: %@", settings.text(error.localizedDescription), language: settings.interfaceLanguage))
            }
        }
    }

    static func alreadyInTargetLanguage(_ text: String, target: AppLanguage) -> Bool {
        guard text.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(8_000)))
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let (language, confidence) = hypotheses.first, confidence >= 0.85 else { return false }
        return Locale.Language(identifier: language.rawValue).minimalIdentifier == target.localeLanguage?.minimalIdentifier
    }

    func retry(using engine: OCREngine? = nil) {
        guard let image = sourceImage else { return }
        if let engine { settings.ocrEngine = engine }
        process(image)
    }

    func failImport(_ error: Error) {
        closeResult()
        presentsResult = true
        phase = .failed(error.localizedDescription)
    }

    /// The background shortcut can avoid an unsupported same-language session
    /// after local language detection. No cloud request is needed in this case.
    func completeIdentityTranslation(processID: UUID) {
        guard isActive(processID), phase == .translating, let document else { return }
        translatedBlockCount = document.blocks.count
        finish(processID)
    }

    func viewRecognizedText() {
        guard document != nil else { return }
        cancelCurrentWork()
        notice = "Showing recognized text. Translation did not complete."
        phase = .ready
    }

    func closeResult() {
        cancelCurrentWork()
        presentsResult = false
        document = nil
        sourceImage = nil
        notice = nil
        consentDestinations = []
        pendingConsentIDs = [:]
        phase = .idle
        translatedBlockCount = 0
        totalBlockCount = 0
    }

    private func isActive(_ id: UUID) -> Bool { !Task.isCancelled && activeProcessID == id }

    private func finish(_ id: UUID) {
        guard isActive(id), let document else { return }
        phase = .ready
        if settings.savesHistory { history.add(document) }
    }

    private func cancelCurrentWork() {
        activeProcessID = nil
        processingTask?.cancel()
        processingTask = nil
        translationConfiguration = nil
        appleRequestID = nil
        pendingAppleIDs = []
        appleResolvedSource = nil
    }
}
