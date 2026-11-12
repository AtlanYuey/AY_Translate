// Modified for AY Translate by AtlanYuey (2026). See NOTICE.
import Combine
import Foundation
import SwiftUI
import Translation
import UIKit
import NaturalLanguage
import os

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, awaitingConsent, awaitingAssist, reading, translating, preparing, ready
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
    var isProcessing: Bool { phase == .loading || phase == .reading || phase == .translating || phase == .preparing }

    private let services: ProcessingServices
    private let diagnostics: ProcessingDiagnostics?
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
    private var visionCache: (image: UIImage, source: AppLanguage, blocks: [RecognizedBlock])?
    /// A cloud reading of the current image is paid for once: changing the
    /// target language or translator afterwards reuses it.
    private var cloudCache: (image: UIImage, source: AppLanguage, service: String, result: OCRResult)?
    /// The answer to "use AI for this image?", kept while the image is open.
    private var assistDecision: (image: UIImage, useAI: Bool)?
    private var startedAt = ContinuousClock.now
    private var translationStartedAt = ContinuousClock.now
    @Published private(set) var recognitionSeconds: Double = 0
    @Published private(set) var translationSeconds: Double = 0

    private func localRecognition(_ image: UIImage, source: AppLanguage) async throws -> [RecognizedBlock] {
        if let cache = visionCache, cache.image === image, cache.source == source { return cache.blocks }
        let blocks = try await services.vision(image, source)
        try Task.checkCancellation()
        visionCache = (image, source, blocks)
        return blocks
    }

    private func seconds(since instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    init(settings: AppSettings, history: HistoryStore, services: ProcessingServices? = nil, diagnostics: ProcessingDiagnostics? = nil) {
        self.settings = settings
        self.history = history
        self.services = services ?? .live
        self.diagnostics = diagnostics ?? (services == nil ? .shared : nil)
    }

    func beginImport() {
        diagnostics?.end("replaced")
        cancelCurrentWork()
        document = nil; sourceImage = nil; visionCache = nil; cloudCache = nil; assistDecision = nil
        let id = UUID()
        activeProcessID = id; previewID = id
        notice = nil
        presentsResult = true
        phase = .loading
        diagnostics?.begin(id: id, target: settings.target.rawValue, stage: "importing")
    }

    func displayImportedImage(_ image: UIImage) {
        guard phase == .loading else { return }
        sourceImage = image
        diagnostics?.stage("presenting")
    }

    func releaseOptionalResources() {
        visionCache = nil; cloudCache = nil
        if ProcessingMemory.isExtension { history.releaseCache() }
    }

    /// `assist` carries the user's answer when recognition paused to ask
    /// whether a cloud recognizer may help with this image.
    func process(_ image: UIImage, assist answer: Bool? = nil) {
        let importedID = phase == .loading || (phase == .awaitingAssist && answer != nil) ? activeProcessID : nil
        if importedID == nil { diagnostics?.end("replaced") }
        cancelCurrentWork()
        let processID = importedID ?? UUID()
        previewID = processID
        activeProcessID = processID
        if sourceImage !== image { visionCache = nil; cloudCache = nil; assistDecision = nil }
        if let answer { assistDecision = (image, answer) }
        let decision = assistDecision?.useAI
        startedAt = .now
        recognitionSeconds = 0; translationSeconds = 0
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
        if importedID == nil { diagnostics?.begin(id: processID, target: target.rawValue) }
        else { diagnostics?.stage("reading") }
        let ocrConfiguration = settings.aiOCR
        let translationConfiguration = settings.aiTranslation
        let profiles: [AIProfile] = (ocrEngine == .ai ? [.ocr] : []) + (translator == .ai ? [.translation] : [])
        pendingConsentIDs = [:]
        do {
            for profile in profiles { try settings.configuration(for: profile).validate() }
        } catch {
            diagnostics?.end("failed")
            phase = .failed(error.localizedDescription)
            return
        }
        let missingConsent = profiles.filter { !settings.hasConsent(for: $0) }
        if !missingConsent.isEmpty {
            diagnostics?.event("awaiting_consent")
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
            diagnostics?.end("failed")
            phase = .failed(error.localizedDescription)
            return
        }
        // Apple Vision with AI assistance: a cloud recognizer is used only when
        // the local reading looks unreliable, and only with a service whose
        // use was approved where it was chosen. Otherwise nothing is uploaded.
        var assist: (configuration: AIServiceConfiguration, key: String, service: String, asks: Bool)?
        if ocrEngine == .appleVision, decision != false, settings.aiAssistAutomatic || settings.aiAssistAsks || decision == true,
           let service = settings.assistService, settings.hasConsent(for: .ocr, service: service),
           (try? service.configuration.validate()) != nil, let key = try? settings.readAPIKey(forService: service.id) {
            assist = (service.configuration, key, service.consentID, decision == nil && !settings.aiAssistAutomatic)
        }
        let assistPlan = assist
        let ocrService = settings.consentIdentity(for: .ocr)
        phase = .reading
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { if activeProcessID == processID { processingTask = nil } }
            do {
                let result: OCRResult
                if ocrEngine == .appleVision, let plan = assistPlan {
                    var local: [RecognizedBlock] = []
                    var localFailure: Error?
                    do { local = try await localRecognition(image, source: source) }
                    catch { try Task.checkCancellation(); localFailure = error }
                    let needed: Bool
                    if decision == true { needed = true } else { needed = await services.needsAssist(image, local) }
                    guard isActive(processID) else { return }
                    if needed && plan.asks {
                        diagnostics?.event("assist_asked")
                        phase = .awaitingAssist
                        return
                    }
                    if needed {
                        diagnostics?.event("assist_ai")
                        result = try await cloudRecognition(image, source: source, anchors: local, configuration: plan.configuration, key: plan.key, service: plan.service)
                    } else if let localFailure { throw localFailure }
                    else { result = OCRResult(blocks: local) }
                } else if ocrEngine == .appleVision {
                    result = OCRResult(blocks: try await localRecognition(image, source: source))
                } else {
                    var anchors: [RecognizedBlock] = []
                    do { anchors = try await localRecognition(image, source: source) }
                    catch { try Task.checkCancellation() }
                    try Task.checkCancellation()
                    result = try await cloudRecognition(image, source: source, anchors: anchors, configuration: ocrConfiguration, key: ocrKey, service: ocrService)
                }
                guard isActive(processID) else { return }
                guard !result.blocks.isEmpty else { throw ScreenReadingError.noText }
                recognitionSeconds = seconds(since: startedAt)
                translationStartedAt = .now
                diagnostics?.stage("translating")
                let blocks = TranslationPlanner.paragraphs(result.blocks)
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
                    let pendingText = blocks.filter { self.pendingAppleIDs.contains($0.id) }.map(\.original).joined(separator: "\n")
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
                    let signature = (resolvedSource?.minimalIdentifier ?? source.rawValue) + ":" + target.rawValue
                    if signature != cachedAppleLanguages || cachedAppleConfiguration == nil {
                        cachedAppleLanguages = signature
                        cachedAppleConfiguration = TranslationSession.Configuration(source: resolvedSource, target: target.localeLanguage, preferredStrategy: .lowLatency)
                    }
                    // Repeated screenshots with the same languages must restart
                    // the view-bound session even if SwiftUI coalesces updates.
                    cachedAppleConfiguration?.invalidate()
                    self.translationConfiguration = cachedAppleConfiguration
                } else {
                    phase = .translating
                    let translations: [UUID: String]
                    var incomplete = false
                    do {
                        translations = try await services.aiTranslation(blocks, source, target, translationConfiguration, translationKey)
                    } catch let partial as PartialTranslationError {
                        // Keep every verified region; only the failed ones show
                        // their original text. One bad region must not blank the page.
                        translations = partial.translations
                        incomplete = true
                        diagnostics?.event("ai_translation_partial_" + partial.reason.diagnosticCode)
                    }
                    guard isActive(processID), var current = document else { return }
                    guard incomplete || current.blocks.allSatisfy({ translations[$0.id]?.isEmpty == false }) else { throw AIServiceError.incompleteTranslation }
                    for index in current.blocks.indices {
                        if let text = translations[current.blocks[index].id], !text.isEmpty { current.blocks[index].translation = text }
                    }
                    document = current
                    translatedBlockCount = current.blocks.filter { translations[$0.id]?.isEmpty == false }.count
                    if incomplete {
                        let message = "Some regions could not be translated. Their original text is preserved; tap a translated region to read it in full."
                        notice = notice.map { $0 + "\n" + AppLocalization.text(message) } ?? message
                    }
                    finish(processID)
                }
            } catch {
                fail(error, processID: processID)
            }
        }
    }

    /// Local anchors validate AI positions. A failed AI request falls back to
    /// them; a successful reading of this image is kept for later retries.
    private func cloudRecognition(_ image: UIImage, source: AppLanguage, anchors: [RecognizedBlock],
                                  configuration: AIServiceConfiguration, key: String, service: String) async throws -> OCRResult {
        if let cache = cloudCache, cache.image === image, cache.source == source, cache.service == service { return cache.result }
        do {
            diagnostics?.event("ai_ocr_begin")
            let recognized = try await services.aiOCR(image, anchors, configuration, key)
            diagnostics?.event("ai_ocr_completed")
            cloudCache = (image, source, service, recognized)
            return recognized
        } catch {
            try Task.checkCancellation()
            let failure = error as? AIServiceError ?? .invalidResponse
            diagnostics?.recordOCRFallback(failure.diagnosticCode)
            guard !anchors.isEmpty else { throw error }
            let message = AppLocalization.text("AI OCR failed; this result uses local Apple Vision.")
                + "\n" + AppLocalization.text(failure.localizedDescription)
                + "\n" + failure.diagnosticCode
            return OCRResult(blocks: anchors, notice: message)
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

    /// The answer to the "use AI for this image?" question.
    func resolveAssist(useAI: Bool) {
        guard phase == .awaitingAssist, let image = sourceImage else { return }
        diagnostics?.event(useAI ? "assist_accepted" : "assist_declined")
        process(image, assist: useAI)
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
            guard session.targetLanguage?.languageCode == current.target.localeLanguage?.languageCode else {
                throw AIServiceError.incompleteTranslation
            }
            // prepareTranslation throws when source is nil. Resolve it locally
            // first when possible, then let the system request model downloads.
            if let source = appleResolvedSource, let target = current.target.localeLanguage,
               await LanguageAvailability().status(from: source, to: target) != .installed {
                phase = .preparing
                try await session.prepareTranslation()
                guard isActive(processID) else { session.cancel(); return }
                phase = .translating
            }
            let requests = current.blocks.filter { self.pendingAppleIDs.contains($0.id) }.map { TranslationSession.Request(sourceText: $0.original, clientIdentifier: $0.id.uuidString) }
            let indices = Dictionary(uniqueKeysWithValues: current.blocks.indices.map { (current.blocks[$0].id.uuidString, $0) })
            var completed = Set<String>()
            var lastPublish = ContinuousClock.now
            for try await response in session.translate(batch: requests) {
                guard isActive(processID) else { session.cancel(); return }
                guard let key = response.clientIdentifier, let index = indices[key],
                      !response.targetText.isEmpty, completed.insert(key).inserted else { continue }
                guard response.targetLanguage.languageCode == current.target.localeLanguage?.languageCode else {
                    throw AIServiceError.incompleteTranslation
                }
                current.blocks[index].translation = response.targetText
                translatedBlockCount = current.blocks.count - pendingAppleIDs.count + completed.count
                if lastPublish.duration(to: .now) >= .milliseconds(80) {
                    document = current
                    lastPublish = .now
                }
            }
            guard isActive(processID) else { return }
            guard completed.count == requests.count else { throw AIServiceError.incompleteTranslation }
            document = current
            finish(processID)
        } catch {
            guard activeProcessID == processID else { return }
            if error is CancellationError || Task.isCancelled {
                fail(error, processID: processID)
                return
            }
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
            diagnostics?.end("failed")
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
        diagnostics?.end("failed")
        cancelCurrentWork()
        presentsResult = true
        phase = .failed(error.localizedDescription)
    }

    func viewRecognizedText() {
        guard document != nil else { return }
        cancelCurrentWork()
        notice = "Showing recognized text. Translation did not complete."
        phase = .ready
    }

    func beginRendering(id: UUID) { if document?.id == id { diagnostics?.beginRendering(id: id) } }
    func finishRendering(id: UUID) { if document?.id == id { diagnostics?.end("completed") } }

    func closeResult(outcome: String = "closed") {
        diagnostics?.end(outcome)
        cancelCurrentWork()
        presentsResult = false
        document = nil
        sourceImage = nil
        visionCache = nil; cloudCache = nil; assistDecision = nil
        if ProcessingMemory.isExtension { history.releaseCache() }
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
        translationSeconds = seconds(since: translationStartedAt)
        Logger(subsystem: "AYTranslate", category: "Performance").info("OCR seconds: \(self.recognitionSeconds); translation seconds: \(self.translationSeconds)")
        phase = .ready
        if let diagnostics {
            // Content-free counts that explain a result: how many regions were
            // found, grouped into bubbles, left unchanged or could not be drawn.
            let overlay = document.blocks.filter { $0.placement == .overlay }
            let canvas = ImageViewport.fittedSize(image: document.image.size, container: CGSize(width: 390, height: 844))
            let layouts = ScreenshotRendering.textLayouts(for: document.blocks, canvasSize: canvas, textScale: settings.overlayTextScale)
            let unchanged = overlay.filter { $0.translation == $0.original }.count
            let undrawn = overlay.filter { $0.translation != $0.original && layouts[$0.id]?.canRender != true }.count
            let bubbleCount = overlay.filter { $0.container != nil }.count
            let textOnly = document.blocks.count - overlay.count
            let parts: [String] = ["regions=" + String(overlay.count), "bubbles=" + String(bubbleCount), "unchanged=" + String(unchanged),
                                   "undrawn=" + String(undrawn), "textOnly=" + String(textOnly), "scale=" + String(settings.overlayTextScale)]
            diagnostics.recordSummary(parts.joined(separator: " "))
        }
        diagnostics?.end("completed")
        if settings.savesHistory { history.add(document) }
    }

    private func fail(_ error: Error, processID: UUID) {
        // A cancelled framework/network request can still belong to the active
        // screen. Keep the image and show recovery; never leave it spinning or
        // silently dismiss it. Explicit Close invalidates the ID beforehand.
        guard activeProcessID == processID else { return }
        let interrupted = error is CancellationError || Task.isCancelled
        diagnostics?.end(interrupted ? "cancelled" : "failed")
        phase = .failed(interrupted
            ? "The translation request was interrupted. The original image is still here; retry to continue."
            : error.localizedDescription)
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
