import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @State private var showsShortcutSetup = false
    @State private var showsPrivacy = false
    @State private var showsAbout = false
    @State private var permissionsCleared = false

    var body: some View {
        Form {
            Section {
                Picker("OCR Engine", selection: $settings.ocrEngine) {
                    ForEach(OCREngine.allCases) { Text($0.name).tag($0) }
                }
                Picker("Source Language", selection: $settings.source) {
                    ForEach(AppLanguage.sourceLanguages) { Text($0.name).tag($0) }
                }
                NavigationLink("Configure AI OCR") { AIProviderSettingsView(profile: .ocr) }
            } header: { Text("OCR") } footer: {
                Text("Apple Vision uses accurate recognition, language correction and automatic detection. AI OCR sends a screenshot only with permission; uncertain positions appear in Full Text.")
            }
            Section {
                Picker("Translation Engine", selection: $settings.translationEngine) {
                    ForEach(TranslationEngine.allCases) { Text($0.name).tag($0) }
                }
                Picker("Target Language", selection: $settings.target) {
                    ForEach(AppLanguage.targetLanguages) { Text($0.name).tag($0) }
                }
                Picker("Priority", selection: $settings.preference) {
                    ForEach(TranslationPreference.allCases) { Text($0.name).tag($0) }
                }.pickerStyle(.segmented)
                NavigationLink("Configure AI Translation") { AIProviderSettingsView(profile: .translation) }
            } header: { Text("Translation") } footer: {
                Text("Apple Translation is free and uses downloaded on-device models. Speed favors low latency; Quality keeps longer paragraphs together and gives AI more output space and screen context.")
            }
            Section("Display") {
                Picker("Overlay Appearance", selection: $settings.appearance) {
                    ForEach(TranslationAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("Text Size", value: settings.overlayTextScale.formatted(.percent.precision(.fractionLength(0))))
                Slider(value: $settings.overlayTextScale, in: 0.8...1.8, step: 0.1).accessibilityLabel("Translation text size")
                Text("Pinch to zoom, drag to pan, or tap any region to read and copy the complete translation. Long text is truncated visibly instead of shrinking to unreadable sizes.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Quick Actions") {
                Button { showsShortcutSetup = true } label: { Label("Action Button & Shortcuts", systemImage: "button.programmable") }
            }
            Section {
                Toggle("Save Translation History", isOn: $settings.savesHistory)
                    .onChange(of: settings.savesHistory) { _, enabled in if !enabled { history.clear() } }
                if !history.items.isEmpty { Button("Clear Saved History", role: .destructive) { history.clear() } }
                Button("Revoke Cloud Sharing Permission") { settings.revokeCloudConsent(); permissionsCleared = true }
                Button { showsPrivacy = true } label: { Label("Privacy Details", systemImage: "hand.raised") }
            } header: { Text("Privacy") } footer: {
                Text("History is off by default. Turning it off deletes saved history. No account or ads. AI providers may charge fees; their API keys are stored only in this device’s Keychain.")
            }
            Section("Information") {
                Button { showsAbout = true } label: { Label("About Translate Screen", systemImage: "info.circle") }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showsShortcutSetup) { ShortcutSetupView() }
        .sheet(isPresented: $showsPrivacy) { PrivacyView() }
        .sheet(isPresented: $showsAbout) { AboutView() }
        .alert("Cloud permission revoked", isPresented: $permissionsCleared) { Button("OK", role: .cancel) {} } message: {
            Text("The next AI operation will ask before sending data. Requests already in progress are not recalled.")
        }
    }
}

private struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("Your screen stays yours", systemImage: "lock.shield.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.blue)

                    privacySection(
                        "On-device processing",
                        "Apple Vision and Apple Translation are the defaults and need no API key. Their language models may need a one-time system download. The app has no screenshot-upload server, analytics, account or ads."
                    )
                    privacySection(
                        "Temporary by default",
                        "When history is off, imported screenshots stay in memory until Close. Shortcuts uses a protected, temporary handoff file, deleted when consumed or expired. No image is added to Photos."
                    )
                    privacySection(
                        "Optional cloud processing",
                        "Only selecting an AI engine and granting permission sends data to your configured HTTPS provider: an image for AI OCR, or recognized text for AI translation. Permission is tied to the endpoint and model. Provider retention policies and fees apply. API keys are kept in the device Keychain and never written to logs or history."
                    )
                    privacySection(
                        "History is your choice",
                        "If you enable history, recent screenshots and recognized text are stored in the app’s private local storage. You can delete them at any time."
                    )
                }
                .padding(24)
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func privacySection(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.blue.gradient)
                        .frame(width: 104, height: 104)
                    Image(systemName: "viewfinder")
                        .font(.system(size: 50, weight: .medium))
                        .foregroundStyle(.white)
                }
                Text("Translate Screen").font(.title2.bold())
                Text("See it. Press. Understand.")
                    .foregroundStyle(.secondary)
                Text("Version 1.0")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.top, 50)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
