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
                            Image(systemName: preset == .other ? "slider.horizontal.3" : "sparkles")
                                .foregroundStyle(.blue).frame(width: 28)
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
            Image(systemName: service.supportsVision ? "eye.square" : "text.bubble")
                .font(.title3).foregroundStyle(.blue)
                .frame(width: 38, height: 38).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
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
    @State private var newKey = ""
    @State private var hasSavedKey = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Service Details") {
                TextField("Service Name", text: $service.name)
                LabeledContent("Provider") { Text(LocalizedStringKey(service.preset.name)) }
                TextField("Base URL", text: $service.configuration.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Model Name", text: $service.configuration.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Toggle("Supports Image Input", isOn: $service.supportsVision)
            } footer: {
                Text("Enable only for a vision-capable model. DeepSeek's text models cannot perform image OCR. Model availability depends on your provider.")
            }
            Section {
                SecureField(settings.text(hasSavedKey ? "New API Key (blank keeps saved key)" : "API Key (optional for keyless services)"), text: $newKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Label(LocalizedStringKey(hasSavedKey ? "A key is stored securely" : "No saved key"), systemImage: hasSavedKey ? "key.fill" : "key")
                    .font(.footnote).foregroundStyle(.secondary)
                if hasSavedKey {
                    Button("Delete Saved API Key", role: .destructive) {
                        do { try settings.deleteAPIKey(forService: service.id); hasSavedKey = false; newKey = "" }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } header: { Text("Device Keychain") } footer: {
                Text("Keys are stored separately for every saved service and never sync to iCloud. Changing the endpoint clears this service's old key unless you enter a replacement.")
            }
            Section {
                Text("Saving does not send a request. Select a service for OCR or translation; sharing requires your permission. Apple engines remain free without a key.")
                Text("Your provider controls availability, pricing and data retention. A free app does not make external API usage free.")
                    .foregroundStyle(.secondary)
            } header: { Text("Sharing & Cost") }
        }
        .navigationTitle("Edit AI Service")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
        }
        .task {
            do { hasSavedKey = try !settings.readAPIKey(forService: service.id).isEmpty }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { newKey = "" }
        .alert("Could Not Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(settings.text(error ?? "")) }
    }

    private func save() {
        do {
            service.name = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try settings.saveService(service, keyReplacement: newKey.isEmpty ? nil : newKey)
            newKey = ""
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
