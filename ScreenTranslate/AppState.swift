import Combine
import Foundation
import SwiftUI
import Translation
import UIKit

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
    private var sourceImage: UIImage?
    private var activeProcessID: UUID?
    private var processingTask: Task<Void, Never>?
    private var pendingConsentIDs: [AIProfile: String] = [:]
    private var cachedAppleConfiguration: TranslationSession.Configuration?
    private var cachedAppleLanguages = ""

    init(settings: AppSettings, history: HistoryStore, services: ProcessingServices = .live) {
        self.settings = settings
        self.history = history
        self.services = services
    }

    func process(_ image: UIImage) {
        cancelCurrentWork()
        let processID = UUID()
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
            pendingConsentIDs = Dictionary(uniqueKeysWithValues: profiles.map { ($0, settings.configuration(for: $0).consentID) })
            consentDestinations = missingConsent.map { profile in
                let host = (try? settings.configuration(for: profile).endpoint().host) ?? "selected provider"
                return profile == .ocr ? "Screenshot → \(host)" : "Recognized text → \(host)"
            }
            phase = .awaitingConsent
            return
        }
        consentDestinations = []
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
                    let key = try settings.keyStore.read(.ocr)
                    do {
                        result = try await services.aiOCR(image, anchors, ocrConfiguration, key)
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
                    phase = .translating
                    appleRequestID = processID
                    let signature = source.rawValue + ":" + target.rawValue + ":" + preference.rawValue
                    if signature != cachedAppleLanguages || cachedAppleConfiguration == nil {
                        cachedAppleLanguages = signature
                        cachedAppleConfiguration = preference == .speed
                            ? TranslationSession.Configuration(source: source.localeLanguage, target: target.localeLanguage, preferredStrategy: .lowLatency)
                            : TranslationSession.Configuration(source: source.localeLanguage, target: target.localeLanguage)
                    }
                    // Repeated screenshots with the same languages must restart
                    // the view-bound session even if SwiftUI coalesces updates.
                    cachedAppleConfiguration?.invalidate()
                    self.translationConfiguration = cachedAppleConfiguration
                } else {
                    phase = .translating
                    let key = try settings.keyStore.read(.translation)
                    let translations = try await services.aiTranslation(blocks, source, target, preference, translationConfiguration, key)
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
        guard Set(selected) == Set(pendingConsentIDs.keys), pendingConsentIDs.allSatisfy({ settings.configuration(for: $0.key).consentID == $0.value }) else {
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
            let requests = current.blocks.map { TranslationSession.Request(sourceText: $0.original, clientIdentifier: $0.id.uuidString) }
            let indices = Dictionary(uniqueKeysWithValues: current.blocks.indices.map { (current.blocks[$0].id.uuidString, $0) })
            var completed = Set<String>()
            for try await response in session.translate(batch: requests) {
                guard isActive(processID) else { session.cancel(); return }
                guard let key = response.clientIdentifier, let index = indices[key],
                      !response.targetText.isEmpty, completed.insert(key).inserted else { continue }
                current.blocks[index].translation = response.targetText
                translatedBlockCount = completed.count
                document = current
            }
            guard isActive(processID) else { return }
            guard completed.count == requests.count else { throw AIServiceError.incompleteTranslation }
            finish(processID)
        } catch {
            guard isActive(processID) else { return }
            phase = .failed("Translation couldn’t be completed: \(error.localizedDescription)")
        }
    }

    func retry(using engine: OCREngine? = nil) {
        guard let image = sourceImage else { return }
        if let engine { settings.ocrEngine = engine }
        process(image)
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
    }
}
