import SwiftUI

struct AIProviderSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let profile: AIProfile
    @State private var configuration = AIServiceConfiguration()
    @State private var newKey = ""
    @State private var hasSavedKey = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Base URL, including /v1 if required", text: $configuration.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Model name", text: $configuration.model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("OpenAI-Compatible Service") } footer: {
                Text(profile == .ocr
                     ? "Choose a model that accepts image input and returns JSON text regions. Enter the exact model ID from your provider."
                     : "Enter the exact model ID from your provider. Custom providers and self-hosted HTTPS services are supported.")
            }
            Section {
                SecureField(hasSavedKey ? "New API Key (blank keeps saved key)" : "API Key (optional for keyless services)", text: $newKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Label(hasSavedKey ? "A key is stored securely" : "No saved key", systemImage: hasSavedKey ? "key.fill" : "key")
                    .font(.footnote).foregroundStyle(.secondary)
                if hasSavedKey {
                    Button("Delete Saved API Key", role: .destructive) {
                        do { try settings.keyStore.save("", for: profile); hasSavedKey = false; newKey = "" }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            } header: { Text("Device Keychain") } footer: {
                Text("OCR and translation have separate keys. Keys do not sync to iCloud. Changing the endpoint clears the old key unless you enter a replacement.")
            }
            Section {
                Text("Saving does not send a request. Select this AI engine in Settings; the app asks permission before sharing with a new endpoint or model. Apple’s engines remain available without a key.")
                Text("Your provider controls availability, pricing and data retention. A free app does not make external API usage free.")
                    .foregroundStyle(.secondary)
            } header: { Text("Sharing & Cost") }
        }
        .navigationTitle(profile.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) } }
        .task {
            configuration = settings.configuration(for: profile)
            do { hasSavedKey = try !settings.keyStore.read(profile).isEmpty }
            catch { errorMessage = error.localizedDescription }
        }
        .onDisappear { newKey = "" }
        .alert("Could Not Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        do {
            try settings.saveConfiguration(configuration, keyReplacement: newKey.isEmpty ? nil : newKey, for: profile)
            newKey = ""
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
