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
    @State private var imageProbeResult: String?
    @State private var testingImage = false
    @State private var imageTestTask: Task<Void, Never>?
    @State private var error: String?
    @State private var consent: CloudConsentRequest?
    @State private var priceNote: String?

    private var priceIdentity: String { [service.configuration.baseURL, service.configuration.model, initialized ? "1" : "0"].joined(separator: "\n") }
    private var discoveryIdentity: String { service.configuration.baseURL + "\n" + key + "\n" + String(discoveryRevision) }
    private var probes: [TranslationProbe] { TranslationProbe.samples(excluding: settings.target.rawValue) }
    private var probe: TranslationProbe { probes.first { $0.id == probeID } ?? probes[0] }

    /// The form and its loading tasks. Kept apart from the change handlers
    /// below: one long modifier chain is more than the type checker manages.
    private var form: some View {
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
            if service.supportsVision {
                Section {
                    Text(verbatim: "Hello, world!\nこんにちは\n你好")
                        .font(.title3.weight(.semibold))
                    if let imageProbeResult { Text(verbatim: imageProbeResult).textSelection(.enabled).accessibilityIdentifier("service.image-test-result") }
                    Button(action: testImageRecognition) {
                        HStack { Label("Test Image Recognition", systemImage: "text.viewfinder"); Spacer(); if testingImage { ProgressView() } }
                    }.disabled(testingImage).accessibilityIdentifier("service.image-test")
                } header: { Text("Test Image Recognition") } footer: {
                    Text("Sends only a built-in sample image to this service. Shows the AI transcription or the specific error, without falling back to Apple Vision. Provider fees may apply.")
                }
            }
            costSection
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
                service.configuration.model = service.configuration.requestModelID
                if service.configuration.model.isEmpty, let first = available.first { service.configuration.model = first }
                modelSelection = available.contains(service.configuration.model) ? service.configuration.model : "__other__"
            } catch is CancellationError { }
            catch { if identity == discoveryIdentity { discoveryError = error.localizedDescription } }
            if identity == discoveryIdentity { discovering = false }
        }
    }

    var body: some View {
        form
        .onChange(of: modelSelection) { _, value in
            if value != "__other__" { service.configuration.model = value }
        }
        .task(id: priceIdentity) {
            // Providers that publish prices fill these fields in themselves,
            // every time this page opens; a discount shows up here.
            guard initialized, !service.configuration.model.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            if let price = await OpenAIClient().price(configuration: service.configuration, apiKey: key), !Task.isCancelled {
                service.inputPrice = price.input; service.outputPrice = price.output
                priceNote = "Price provided by the service and kept up to date automatically."
            } else if !Task.isCancelled {
                priceNote = "This provider does not publish prices. Enter the price from its pricing page; update it when it changes."
            }
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
        .cloudConsentAlert($consent, settings: settings)
    }

    /// Price, this month's use and an optional spending limit.
    @ViewBuilder private var costSection: some View {
        let entry = settings.usageLedger.entry(for: service.id)
        let symbol = service.currencySymbol
        Section {
            if service.preset.billsInYuanOrDollars {
                Picker("Billing Currency", selection: Binding(get: { service.billingCurrency }, set: { service.currency = $0 })) {
                    Text(verbatim: "¥ CNY").tag("CNY")
                    Text(verbatim: "$ USD").tag("USD")
                }
            }
            LabeledContent("Input price / 1M tokens") {
                TextField("0", value: $service.inputPrice, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("Output price / 1M tokens") {
                TextField("0", value: $service.outputPrice, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            if let priceNote { Text(LocalizedStringKey(priceNote)).font(.footnote).foregroundStyle(.secondary) }
            LabeledContent("This month") { usageFigures(entry.monthUsage, cost: entry.monthCost, symbol: symbol) }
            LabeledContent("Total") { usageFigures(entry.totalUsage, cost: entry.totalCost, symbol: symbol) }
            Toggle("Monthly Spending Limit", isOn: Binding(get: { service.spendLimit != nil }, set: { service.spendLimit = $0 ? (service.spendLimit ?? 1) : nil }))
            if service.spendLimit != nil {
                LabeledContent(LocalizedStringKey("Limit")) {
                    HStack(spacing: 4) {
                        Text(verbatim: symbol)
                        TextField("1", value: $service.spendLimit, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
            }
            if !entry.totalUsage.isEmpty {
                Button("Reset Usage Figures", role: .destructive) { settings.resetUsage(forService: service.id) }
            }
        } header: { Text("Cost") } footer: {
            Text("Tokens are counted from what the provider reports for each request, and costed at the price in effect at that moment. When this month’s spending reaches the limit, this service is skipped: the next one in the order takes over, then the on-device engine. A limit needs a price.")
        }
    }

    /// Input and output tokens on their own lines, the amount below them.
    private func usageFigures(_ usage: AIUsage, cost: Double, symbol: String) -> some View {
        let language = settings.interfaceLanguage
        let input: String = AppLocalization.formatted("Input %@ tokens", usage.input.formatted(), language: language)
        let output: String = AppLocalization.formatted("Output %@ tokens", usage.output.formatted(), language: language)
        let amount: String = symbol + cost.formatted(.number.precision(.fractionLength(0...4)))
        return VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: input)
            Text(verbatim: output)
            if service.price != nil || cost > 0 { Text(verbatim: amount).foregroundStyle(.primary) }
        }.font(.callout.monospacedDigit())
    }

    private func cancelTest() {
        testTask?.cancel(); testTask = nil; testing = false; probeResult = nil
        imageTestTask?.cancel(); imageTestTask = nil; testingImage = false; imageProbeResult = nil
    }

    private func testImageRecognition() {
        cancelTest()
        let configuration = service.configuration, apiKey = key
        testingImage = true
        imageTestTask = Task {
            do {
                let data = try ImageRecognitionProbe.jpeg()
                let result = try await OpenAIClient().recognize(imageData: data, anchors: [], configuration: configuration, apiKey: apiKey)
                guard !Task.isCancelled else { return }
                imageProbeResult = result.blocks.map(\.original).joined(separator: "\n")
            } catch {
                guard !Task.isCancelled else { return }
                imageProbeResult = settings.text(error.localizedDescription)
            }
            testingImage = false
        }
    }

    private func testTranslation() {
        cancelTest()
        let sample = probe, configuration = service.configuration, apiKey = key, target = settings.target
        let block = RecognizedBlock(id: UUID(), original: sample.text, translation: sample.text, boundingBox: .zero, confidence: 1, placement: .textOnly)
        testing = true
        testTask = Task {
            do {
                let result = try await OpenAIClient().translate([block], source: sample.languageName, target: target.name,
                    configuration: configuration, apiKey: apiKey)
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
        // A service already approved for recognition or translation that now
        // points somewhere else (endpoint or model) is approved again here,
        // while it is being edited, instead of interrupting the next translation.
        let previous = settings.serviceCatalog.services.first { $0.id == service.id }
        let approved = AIProfile.allCases.filter { profile in previous.map { settings.hasConsent(for: profile, service: $0) } ?? false }
        if let profile = approved.first, previous?.consentID != service.consentID, (try? service.validate()) != nil {
            consent = CloudConsentRequest(profile: profile, service: service) {
                for other in approved where other != profile { settings.grantConsent(for: other, service: service) }
                commit()
            }
        } else { commit() }
    }

    private func commit() {
        do {
            service.name = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try settings.saveService(service, keyReplacement: key == loadedKey ? nil : key)
            key = ""; loadedKey = ""
            didSave?()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Shown where a service is chosen: this is the moment to decide whether
/// screenshots or text may leave the device, not the middle of a translation.
struct CloudConsentRequest: Identifiable {
    let id = UUID()
    let profile: AIProfile
    let service: SavedAIService
    let proceed: () -> Void
}

extension View {
    func cloudConsentAlert(_ request: Binding<CloudConsentRequest?>, settings: AppSettings) -> some View {
        alert("Send data to this AI service?", isPresented: Binding(get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }), presenting: request.wrappedValue) { pending in
            Button("Allow") {
                settings.grantConsent(for: pending.profile, service: pending.service)
                pending.proceed()
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            let host = (try? pending.service.configuration.endpoint().host) ?? pending.service.name
            Text(verbatim: pending.service.name + " · " + host + "\n"
                + settings.text(pending.profile == .ocr ? "Screenshots you translate are sent to this service for recognition." : "Recognized text is sent to this service for translation.")
                + " " + settings.text("Your provider may charge for requests and apply its own retention policy. You can revoke this in Privacy settings."))
        }
    }
}

/// The order AI services are tried in for one job. The first is used; a later
/// one takes over when an earlier one fails or reaches its spending limit;
/// the on-device engine is always the last resort (and the only one when the
/// order is empty).
struct EngineSelectionView: View {
    @EnvironmentObject private var settings: AppSettings
    let profile: AIProfile
    @State private var error: String?
    @State private var consent: CloudConsentRequest?

    private var chain: [SavedAIService] { settings.chain(for: profile) }
    private var unused: [SavedAIService] {
        let used = Set(chain.map(\.id))
        return settings.serviceCatalog.services.filter { !used.contains($0.id) && (profile != .ocr || $0.supportsVision) }
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(chain.enumerated()), id: \.element.id) { index, service in
                    HStack(spacing: 10) {
                        Text(verbatim: String(index + 1)).font(.footnote.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary).frame(width: 16)
                        ServiceRow(service: service)
                        Spacer()
                        if settings.isOverLimit(service) { Text("Limit reached").font(.caption).foregroundStyle(.orange) }
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == chain.count - 1)
                        Button { setChain(chain.map(\.id).filter { $0 != service.id }) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                    }.buttonStyle(.borderless)
                }
                HStack(spacing: 10) {
                    Text(verbatim: String(chain.count + 1)).font(.footnote.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary).frame(width: 16)
                    Label(LocalizedStringKey(profile == .ocr ? "Apple Vision · Free" : "Apple Translation · Free"), systemImage: "apple.logo")
                    Spacer()
                    Text(LocalizedStringKey(chain.isEmpty ? "In use" : "Last resort")).font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Order of Use") } footer: {
                Text("The first one is used. When it fails or reaches its spending limit the next one takes over, and you are told. The on-device engine is free and always last.")
            }
            if !unused.isEmpty {
                Section("Add to the Order") {
                    ForEach(unused) { service in
                        Button { add(service) } label: {
                            HStack { ServiceRow(service: service); Spacer(); Image(systemName: "plus.circle.fill").foregroundStyle(.green) }.foregroundStyle(.primary)
                        }
                    }
                }
            }
            if profile == .ocr { assistSection }
            Section {
                NavigationLink { AIServicesView() } label: { Label("Manage AI Services", systemImage: "plus.circle") }
            } footer: {
                Text(LocalizedStringKey(profile == .ocr ? "Only services with image input enabled are offered for OCR." : "Keys, prices and spending limits are set per service."))
            }
        }
        .navigationTitle(LocalizedStringKey(profile == .ocr ? "OCR Engine" : "Translation Engine"))
        .alert("Could Not Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(settings.text(error ?? "")) }
        .cloudConsentAlert($consent, settings: settings)
    }

    /// Whether the services above read every screenshot, or only the ones the
    /// device could not read reliably — and whether to ask first.
    @ViewBuilder private var assistSection: some View {
        Section {
            Toggle("AI Assistance (only when needed)", isOn: $settings.aiAssistEnabled)
            if settings.aiAssistEnabled {
                Toggle("Ask before using AI", isOn: $settings.aiAssistAsks)
            }
        } footer: {
            Text(LocalizedStringKey(chain.isEmpty
                ? "Add an AI service to the order above to use this."
                : "On: Apple Vision reads first, and the services above are used only when its reading looks unreliable (handwriting, stylised lettering, unread speech bubbles). Off: the services above read every screenshot."))
        }.disabled(chain.isEmpty)
    }

    private func add(_ service: SavedAIService) {
        let ids = chain.map(\.id) + [service.id]
        if settings.hasConsent(for: profile, service: service) { setChain(ids) }
        else { consent = CloudConsentRequest(profile: profile, service: service) { setChain(ids) } }
    }

    private func move(_ index: Int, by offset: Int) {
        var ids = chain.map(\.id)
        guard ids.indices.contains(index), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        setChain(ids)
    }

    private func setChain(_ ids: [UUID]) {
        do { try settings.setChain(ids, for: profile) }
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
