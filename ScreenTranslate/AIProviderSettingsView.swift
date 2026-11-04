import SwiftUI

/// A saved service can be reused by either engine without re-entering its key.
struct AIServicesView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var adding = false
    @State private var editing: SavedAIService?
    @State private var deleting: SavedAIService?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if settings.serviceCatalog.services.isEmpty {
                    ContentUnavailableView("No AI Services", systemImage: "server.rack", description: Text("Save your providers here, then switch between them with one tap."))
                        .listRowBackground(Color.clear)
                }
                ForEach(settings.serviceCatalog.services) { service in
                    Button { editing = service } label: { ServiceRow(service: service) }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Delete", role: .destructive) { deleting = service }
                        }
                }
            } header: { Text("Saved Services") } footer: {
                Text("Each service keeps its own name, model and secure key. OCR and translation can use different services.")
            }
            Section {
                Button { adding = true } label: { Label("Add AI Service", systemImage: "plus.circle.fill") }
            }
            if let message = settings.serviceMigrationError {
                Section { Text(settings.text(message)).font(.footnote).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("AI Services")
        .sheet(isPresented: $adding) {
            NavigationStack { ServicePresetPicker() }
        }
        .sheet(item: $editing) { service in
            NavigationStack { AIServiceEditor(service: service) }
        }
        .confirmationDialog("Delete this service and its API key?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let service = deleting else { return }
                do { try settings.removeService(service.id) } catch { self.error = error.localizedDescription }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
        .alert("Could Not Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(settings.text(error ?? "")) }
    }
}

private struct ServicePresetPicker: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                ForEach(AIProviderPreset.allCases) { preset in
                    NavigationLink {
                        AIServiceEditor(service: SavedAIService(preset: preset)) { dismiss() }
                    } label: {
                        HStack(spacing: 14) {
                            ProviderIcon(preset: preset).frame(width: 28, height: 28)
                            Text(LocalizedStringKey(preset.name))
                            Spacer()
                            if preset == .deepSeek { Text("Text Only").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 5)
                    }
                }
            } footer: {
                Text("Presets fill the official compatible endpoint. Enter a model available to your account. Use OpenAI (Other) for custom or self-hosted services.")
            }
        }
        .navigationTitle("Choose Provider")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

struct ServiceRow: View {
    let service: SavedAIService
    var body: some View {
        HStack(spacing: 13) {
            ProviderIcon(preset: service.preset).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(service.name).font(.body.weight(.medium))
                Text(service.configuration.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 3)
    }
}

struct AIServiceEditor: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State var service: SavedAIService
    var didSave: (() -> Void)?
    @State private var key = ""
    @State private var loadedKey = ""
    @State private var loadedEndpoint: URL?
    @State private var initialized = false
    @State private var models: [String] = []
    @State private var discovering = false
    @State private var discoveryError: String?
    @State private var modelSelection = "__other__"
    @State private var discoveryRevision = 0
    @State private var probeID = "en"
    @State private var probeResult: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var error: String?

    private var discoveryIdentity: String { service.configuration.baseURL + "\n" + key + "\n" + String(discoveryRevision) }
    private var probes: [TranslationProbe] { TranslationProbe.samples(excluding: settings.target.rawValue) }
    private var probe: TranslationProbe { probes.first { $0.id == probeID } ?? probes[0] }

    var body: some View {
        Form {
            Section("Service Details") {
                TextField("Service Name", text: $service.name)
                    .keyboardType(.default).textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("Provider") { HStack { ProviderIcon(preset: service.preset).frame(width: 24, height: 24); Text(LocalizedStringKey(service.preset.name)) } }
                TextField("Base URL", text: $service.configuration.baseURL, axis: .vertical)
                    .keyboardType(.default).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("service.url")
                TextField("API Key (optional for keyless services)", text: $key, axis: .vertical)
                    .keyboardType(.default).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .privacySensitive().accessibilityIdentifier("service.key")
            }
            Section {
                if !models.isEmpty {
                    Picker("Model", selection: $modelSelection) {
                        ForEach(models, id: \.self) { Text(verbatim: $0).tag($0) }
                        Text("Other Model").tag("__other__")
                    }.accessibilityIdentifier("service.models")
                }
                if modelSelection == "__other__" || models.isEmpty {
                    TextField("Model Name", text: $service.configuration.model)
                        .keyboardType(.default).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("service.custom-model")
                }
                Button { discoveryRevision += 1 } label: {
                    HStack { Label("Fetch Available Models", systemImage: "arrow.clockwise"); Spacer(); if discovering { ProgressView() } }
                }.disabled(discovering)
                if let discoveryError { Text(settings.text(discoveryError)).font(.footnote).foregroundStyle(.secondary) }
                Toggle("Supports Image Input", isOn: $service.supportsVision)
            } header: { Text("Model") } footer: {
                Text("Pasting a key fetches the provider’s model list. If listing is unavailable, choose Other Model and enter its ID. Enable image input only for a vision-capable model.")
            }
            Section {
                NavigationLink {
                    AIRequestOptionsView(options: Binding(
                        get: { service.configuration.requestOptions ?? AIRequestOptions() },
                        set: { service.configuration.requestOptions = $0 }))
                } label: {
                    LabeledContent("Request Parameters", value: settings.text((service.configuration.requestOptions?.preset ?? .modelDefault).name))
                }
            }
            Section {
                Picker("Test Phrase", selection: Binding(get: { probe.id }, set: { probeID = $0 })) {
                    ForEach(probes) { Text(verbatim: $0.languageName).tag($0.id) }
                }
                Text(verbatim: probe.text).textSelection(.enabled)
                LabeledContent("Target Language", value: settings.target.nativeName)
                if let probeResult { Text(verbatim: probeResult).textSelection(.enabled).accessibilityIdentifier("service.test-result") }
                Button(action: testTranslation) {
                    HStack { Label("Test Translation", systemImage: "play.fill"); Spacer(); if testing { ProgressView() } }
                }.disabled(testing).accessibilityIdentifier("service.test")
            } header: { Text("Test Translation") } footer: {
                Text("Test sends only the selected sample to this endpoint with the current key and model. Provider fees may apply. Saving alone sends no translation request.")
            }
            Section {
                Text("The key stays visible for checking pasted text. It is saved only in this device’s Keychain, separately for each service.")
                Text("Changing the endpoint clears a previously saved key. Paste a replacement for the new destination.")
            } header: { Text("Device Keychain") }
        }
        .navigationTitle("Edit AI Service")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { key = ""; loadedKey = ""; dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
        }
        .task {
            guard !initialized else { return }
            do {
                loadedKey = try settings.readAPIKey(forService: service.id)
                key = loadedKey
                loadedEndpoint = try? service.configuration.endpoint()
                initialized = true
            } catch { self.error = error.localizedDescription }
        }
        .task(id: discoveryIdentity) {
            discovering = false
            guard initialized, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || discoveryRevision > 0 else { return }
            let identity = discoveryIdentity
            do {
                try await Task.sleep(for: .milliseconds(700))
                discovering = true
                discoveryError = nil
                let available = try await OpenAIClient().models(configuration: service.configuration, apiKey: key)
                guard !Task.isCancelled, identity == discoveryIdentity else { return }
                models = available
                if service.configuration.model.isEmpty, let first = available.first { service.configuration.model = first }
                modelSelection = available.contains(service.configuration.model) ? service.configuration.model : "__other__"
            } catch is CancellationError { }
            catch { if identity == discoveryIdentity { discoveryError = error.localizedDescription } }
            if identity == discoveryIdentity { discovering = false }
        }
        .onChange(of: modelSelection) { _, value in
            if value != "__other__" { service.configuration.model = value }
        }
        .onChange(of: service.configuration.baseURL) { _, _ in
            models = []; modelSelection = "__other__"; discoveryError = nil; discovering = false
            // Do not send a saved credential automatically to an edited host/path.
            if (try? service.configuration.endpoint()) != loadedEndpoint, key == loadedKey { key = "" }
            cancelTest()
        }
        .onChange(of: key) { _, _ in cancelTest() }
        .onChange(of: service.configuration.model) { _, _ in cancelTest() }
        .onChange(of: service.configuration.requestOptions) { _, _ in cancelTest() }
        .onChange(of: probeID) { _, _ in cancelTest() }
        .onChange(of: settings.target) { _, _ in cancelTest() }
        // Form pickers can push another page. Keep unsaved pasted credentials
        // while choosing a model; explicit Save/Cancel ends the editing session.
        .onDisappear { cancelTest() }
        .alert("Could Not Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(settings.text(error ?? "")) }
    }

    private func cancelTest() { testTask?.cancel(); testTask = nil; testing = false; probeResult = nil }

    private func testTranslation() {
        cancelTest()
        let sample = probe, configuration = service.configuration, apiKey = key, target = settings.target
        let block = RecognizedBlock(id: UUID(), original: sample.text, translation: sample.text, boundingBox: .zero, confidence: 1, placement: .textOnly)
        testing = true
        testTask = Task {
            do {
                let result = try await OpenAIClient().translate([block], source: sample.languageName, target: target.name,
                    preference: settings.preference, configuration: configuration, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                probeResult = result[block.id]
            } catch {
                guard !Task.isCancelled else { return }
                probeResult = settings.text(error.localizedDescription)
            }
            testing = false
        }
    }

    private func save() {
        do {
            service.name = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try settings.saveService(service, keyReplacement: key == loadedKey ? nil : key)
            key = ""; loadedKey = ""
            didSave?()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct EngineSelectionView: View {
    @EnvironmentObject private var settings: AppSettings
    let profile: AIProfile
    @State private var error: String?

    private var localSelected: Bool {
        profile == .ocr ? settings.ocrEngine == .appleVision : settings.translationEngine == .apple
    }

    var body: some View {
        List {
            Section {
                Button { select(nil) } label: {
                    HStack {
                        Label(LocalizedStringKey(profile == .ocr ? "Apple Vision · Free" : "Apple Translation · Free"), systemImage: "apple.logo")
                        Spacer()
                        if localSelected { Image(systemName: "checkmark").foregroundStyle(.blue) }
                    }.foregroundStyle(.primary)
                }
            } header: { Text("On-Device Engine") } footer: { Text("Free, private and available without an API key.") }
            Section {
                ForEach(settings.serviceCatalog.services.filter { profile != .ocr || $0.supportsVision }) { service in
                    Button { select(service.id) } label: {
                        HStack {
                            ServiceRow(service: service)
                            Spacer()
                            if !localSelected && settings.selectedService(for: profile)?.id == service.id {
                                Image(systemName: "checkmark").foregroundStyle(.blue)
                            }
                        }.foregroundStyle(.primary)
                    }
                }
                NavigationLink { AIServicesView() } label: { Label("Manage AI Services", systemImage: "plus.circle") }
            } header: { Text("Saved Services") } footer: {
                Text(LocalizedStringKey(profile == .ocr ? "Only services with image input enabled are offered for OCR." : "Tap a saved service to switch instantly. Keys and other configurations are kept."))
            }
        }
        .navigationTitle(LocalizedStringKey(profile == .ocr ? "OCR Engine" : "Translation Engine"))
        .alert("Could Not Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(settings.text(error ?? "")) }
    }

    private func select(_ id: UUID?) {
        do { try settings.selectService(id, for: profile) }
        catch { self.error = error.localizedDescription }
    }
}

struct ProviderIcon: View {
    let preset: AIProviderPreset
    var body: some View {
        Group {
            if preset == .other {
                Image(systemName: "slider.horizontal.3").resizable().scaledToFit().foregroundStyle(.blue).padding(5)
            } else {
                Image("provider-" + preset.rawValue).renderingMode(.original).resizable().scaledToFit().padding(3)
            }
        }.background(.white, in: RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    }
}
