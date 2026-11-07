import Foundation
import SwiftUI
import UIKit

/// A small device-local journal, not screenshot/recognition history. No image,
/// text, endpoint, model name, credential or provider response is recorded.
@MainActor
final class ProcessingDiagnostics {
    static let shared = ProcessingDiagnostics()
    struct MemoryCheckpoint: Codable {
        var point: String
        var footprintBytes: UInt64?
        var availableBytes: UInt64
    }
    struct Entry: Codable, Identifiable {
        var id: UUID
        var started: Date
        var updated: Date
        var context: String
        var target: String
        var stage: String
        var outcome: String
        var event: String
        var memoryWarnings: Int = 0
        var footprintBytes: UInt64?
        var peakFootprintBytes: UInt64?
        var availableBytes: UInt64?
        var checkpoints: [MemoryCheckpoint]?
        var version: String?
        var build: String?
        var processSession: UUID?
        var ocrFallback: String?
    }
    private let defaults: UserDefaults
    private let keys: any APIKeyStoring
    private let context: String
    private var entries: [Entry]
    private var current: UUID?
    private static let processSession = UUID()
    private var memoryObserver: NSObjectProtocol?
    var currentID: UUID? { current }

    init(defaults: UserDefaults? = nil, keys: (any APIKeyStoring)? = nil, context: String? = nil) {
        self.defaults = defaults ?? SharedAppContainer.preferences
        self.keys = keys ?? KeychainStore()
        self.context = context ?? (Bundle.main.bundleURL.pathExtension == "appex" ? "share" : "app")
        entries = self.defaults.data(forKey: "processing.diagnostics." + self.context)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.memoryWarning() }
            }
    }

    deinit { if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) } }

    func begin(id: UUID, target: String, stage: String = "reading") {
        if current != nil { end("replaced") }
        current = id
        let now = Date()
        entries.append(Entry(id: id, started: now, updated: now, context: context, target: target,
            stage: stage, outcome: "unfinished", event: "started",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            processSession: Self.processSession))
        entries = Array(entries.suffix(8))
        update { _ in }
    }

    func stage(_ value: String) { update { $0.stage = value; $0.event = value } }
    func event(_ value: String) { update { $0.event = value } }
    func recordOCRFallback(_ code: String) {
        update { $0.ocrFallback = code; $0.event = "ai_ocr_fallback" }
    }
    func checkpoint(_ point: String, id: UUID?) {
        // A cancelled, late framework return must not annotate the next image.
        guard let id, id == current else { return }
        update { $0.event = point }
    }
    func end(_ outcome: String) {
        update { $0.outcome = outcome }
        current = nil
    }
    func memoryWarning() {
        ProcessingMemory.receivedWarning()
        update { $0.memoryWarnings += 1; $0.event = "memory_warning" }
    }
    func beginRendering(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].outcome == "completed" else { return }
        current = id
        update { $0.stage = "background"; $0.outcome = "unfinished"; $0.event = "preparing_image" }
    }

    private func update(_ change: (inout Entry) -> Void) {
        guard let current, let index = entries.firstIndex(where: { $0.id == current }) else { return }
        change(&entries[index]); entries[index].updated = Date()
        let memory = ProcessingMemory.snapshot()
        entries[index].footprintBytes = memory.footprint
        entries[index].peakFootprintBytes = max(entries[index].peakFootprintBytes ?? 0, memory.footprint ?? 0)
        entries[index].availableBytes = memory.available
        var samples = entries[index].checkpoints ?? []
        let sample = MemoryCheckpoint(point: entries[index].event == "started" ? entries[index].stage : entries[index].event,
            footprintBytes: memory.footprint, availableBytes: memory.available)
        if sample.point == "memory_warning", samples.last?.point == "memory_warning" { samples[samples.count - 1] = sample }
        else { samples.append(sample) }
        // Keep import/start evidence as well as the last framework checkpoints.
        if samples.count > 20 { samples = Array(samples.prefix(6)) + Array(samples.suffix(14)) }
        entries[index].checkpoints = samples
        persist()
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: "processing.diagnostics." + context)
        // Reuse the existing local shared-Keychain bridge when Feather has
        // removed App Groups. This slot is never included in iCloud settings.
        try? keys.save(String(decoding: data, as: UTF8.self), for: .processingDiagnostics(context))
    }

    func reports() -> [Entry] {
        var found: [UUID: Entry] = [:]
        for context in ["app", "share"] {
            let local = defaults.data(forKey: "processing.diagnostics." + context)
            let shared = (try? keys.read(.processingDiagnostics(context))).map { Data($0.utf8) }
            for data in [local, shared].compactMap({ $0 }) where data.count <= 32_000 {
                for entry in (try? JSONDecoder().decode([Entry].self, from: data)) ?? [] {
                    if found[entry.id].map({ $0.updated < entry.updated }) ?? true { found[entry.id] = entry }
                }
            }
        }
        return found.values.sorted { $0.started > $1.started }
    }
}

struct ProcessingDiagnosticsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var entries: [ProcessingDiagnostics.Entry] = []
    var body: some View {
        List {
            Section {
                Text("Only processing stages and exit states are recorded, without image content or API keys. An unfinished record does not prove a crash or memory termination.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Copy Processing Report", systemImage: "doc.on.doc") {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    if let data = try? encoder.encode(entries) { UIPasteboard.general.string = String(decoding: data, as: UTF8.self) }
                }.disabled(entries.isEmpty)
            }
            ForEach(entries) { entry in
                Section {
                    LabeledContent("Status", value: settings.text(status(entry.outcome)))
                    LabeledContent("Stage", value: settings.text(entry.stage == "reading" ? "Reading screen…" : ["background", "importing", "presenting"].contains(entry.stage) ? "Preparing image…" : "Translating…"))
                    LabeledContent("Target Language", value: AppLanguage(rawValue: entry.target)?.nativeName ?? entry.target)
                    LabeledContent("Memory Warnings", value: String(entry.memoryWarnings))
                    if let version = entry.version { LabeledContent("Version", value: version + " (" + (entry.build ?? "?") + ")") }
                    if let fallback = entry.ocrFallback { LabeledContent("AI OCR", value: fallback) }
                    Text(entry.context == "share" ? "Share Extension" : "AY Translate").font(.caption).foregroundStyle(.secondary)
                } header: { Text(entry.started, style: .date) + Text(" · ") + Text(entry.started, style: .time) }
            }
        }
        .navigationTitle("Processing Diagnostics")
        .onAppear { entries = ProcessingDiagnostics.shared.reports() }
        .refreshable { entries = ProcessingDiagnostics.shared.reports() }
    }
    private func status(_ outcome: String) -> String {
        switch outcome {
        case "completed": "Completed"
        case "closed": "Closed by user"
        case "failed": "Request failed"
        case "cancelled": "Request interrupted"
        case "replaced": "Replaced by another request"
        default: "No completion recorded"
        }
    }
}
