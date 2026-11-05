import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @State private var showsShortcutSetup = false
    @State private var showsAbout = false

    var body: some View {
        Form {
            Section("Interface") {
                Picker("App Language", selection: $settings.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        if language == .system { Text("Follow System").tag(language) }
                        else { Text(verbatim: language.name).tag(language) }
                    }
                }
            }
            Section {
                NavigationLink { EngineSelectionView(profile: .ocr) } label: {
                    LabeledContent("OCR Engine", value: engineName(.ocr))
                }
                Picker("Source Language", selection: $settings.source) {
                    ForEach(AppLanguage.sourceLanguages) { Text($0 == .automatic ? settings.text($0.name) : $0.nativeName).tag($0) }
                }
            } header: { Text("OCR") } footer: {
                Text("Apple Vision uses accurate recognition, language correction and automatic detection. AI OCR sends a screenshot only with permission; uncertain positions appear in Full Text.")
            }
            Section {
                NavigationLink { EngineSelectionView(profile: .translation) } label: {
                    LabeledContent("Translation Engine", value: engineName(.translation))
                }
                Picker("Target Language", selection: $settings.target) {
                    ForEach(AppLanguage.targetLanguages) { Text(verbatim: $0.nativeName).tag($0) }
                }
                Picker("Priority", selection: $settings.preference) {
                    ForEach(TranslationPreference.allCases) { Text(LocalizedStringKey($0.name)).tag($0) }
                }.pickerStyle(.segmented)
            } header: { Text("Translation") } footer: {
                Text("Apple Translation is free and uses downloaded on-device models. Speed favors low latency; Quality keeps longer paragraphs together and gives AI more output space and screen context.")
            }
            Section {
                NavigationLink { AIServicesView() } label: {
                    Label("AI Services", systemImage: "sparkles")
                }
                NavigationLink { ConfigurationSyncView() } label: {
                    Label("Configuration Sync", systemImage: "icloud")
                }
            }
            Section {
                NavigationLink { DisplaySettingsView() } label: { Label("Display", systemImage: "textformat.size") }
                NavigationLink { HistorySettingsView() } label: { Label("Translation History", systemImage: "clock.arrow.circlepath") }
                NavigationLink { PrivacySettingsView() } label: { Label("Privacy", systemImage: "hand.raised") }
            }
            #if !SCREEN_TRANSLATE_SHARE_EXTENSION
            Section("Quick Actions") {
                Button { showsShortcutSetup = true } label: { Label("Action Button & Shortcuts", systemImage: "button.programmable") }
                Text("The screenshot shortcut presents the translated image above your current app. Close or swipe up to continue where you were.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            #endif
            Section("Information") {
                NavigationLink { ProcessingDiagnosticsView() } label: { Label("Processing Diagnostics", systemImage: "waveform.path.ecg") }
                Button { showsAbout = true } label: { Label("About AY Translate", systemImage: "info.circle") }
            }
        }
        .navigationTitle("Settings")
        #if !SCREEN_TRANSLATE_SHARE_EXTENSION
        .sheet(isPresented: $showsShortcutSetup) { ShortcutSetupView() }
        #endif
        .sheet(isPresented: $showsAbout) { AboutView() }

    }

    private func engineName(_ profile: AIProfile) -> String {
        let local = profile == .ocr ? settings.ocrEngine == .appleVision : settings.translationEngine == .apple
        return local ? settings.text(profile == .ocr ? "Apple Vision · Free" : "Apple Translation · Free") : settings.selectedService(for: profile)?.name ?? settings.text("Choose Provider")
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
            Text(LocalizedStringKey(title)).font(.headline)
            Text(LocalizedStringKey(detail)).foregroundStyle(.secondary)
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
                Text("AY Translate").font(.title2.bold())
                Text("See it. Press. Understand.")
                    .foregroundStyle(.secondary)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2")")
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

private struct DisplaySettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Form {
            Section("Display") {
                Picker("Default Result View", selection: $settings.defaultResultMode) {
                    ForEach(ResultDisplayMode.allCases) { Text(LocalizedStringKey($0.name)).tag($0) }
                }
                Picker("Overlay Appearance", selection: $settings.appearance) {
                    ForEach(TranslationAppearance.allCases) { Text(LocalizedStringKey($0.name)).tag($0) }
                }
                Toggle("Tap text for details", isOn: $settings.showsTextDetailsOnTap).accessibilityIdentifier("settings.text-details")
                LabeledContent("Text Size", value: settings.overlayTextScale.formatted(.percent.precision(.fractionLength(0))))
                Slider(value: $settings.overlayTextScale, in: 0.8...1.8, step: 0.1).accessibilityLabel("Translation text size")
                Text("Tap the original icon to compare. Touch and hold it for copy, full text, engines and settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

        }.navigationTitle("Display").navigationBarTitleDisplayMode(.inline)
    }
}

private struct HistorySettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    var body: some View {
        Form {
            Section {
                Toggle("Save Translation History", isOn: $settings.savesHistory)
                    .accessibilityIdentifier("settings.history")
                    .onChange(of: settings.savesHistory) { _, enabled in if !enabled { history.clear() } }
                if !history.items.isEmpty { Button("Clear Saved History", role: .destructive) { history.clear() } }
            } footer: { Text("History is off by default. Turning it off deletes saved history. Screenshots and history are never included in iCloud settings sync.") }
        }.navigationTitle("Translation History").navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacySettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showsDetails = false
    @State private var revoked = false
    var body: some View {
        Form {
            Section {
                Button("Revoke Cloud Sharing Permission") { settings.revokeCloudConsent(); revoked = true }
                Button("Privacy Details") { showsDetails = true }
            } footer: { Text("Screenshots stay on your device unless you select an AI engine and approve sharing. No account or ads.") }
        }.navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsDetails) { PrivacyView() }
        .alert("Cloud permission revoked", isPresented: $revoked) { Button("OK", role: .cancel) {} } message: {
            Text("The next AI operation will ask before sending data. Requests already in progress are not recalled.")
        }
    }
}

private struct ConfigurationSyncView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var transferMessage: String?
    var body: some View {
        Form {
            #if !SCREEN_TRANSLATE_SHARE_EXTENSION
            Section("iCloud") {
                Toggle("Sync Settings with iCloud", isOn: $settings.iCloudSyncEnabled)
                if settings.iCloudSyncEnabled {
                    Button("Upload This Device’s Settings") { settings.uploadSettingsToCloud() }
                    Text("Saved settings sync automatically after enabling. Changes are sent after a short pause; opening the app also checks other devices. Manual upload is only a fallback.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Sync languages, display preferences and AI service details across your devices. API keys, screenshots, history and cloud permissions stay on this device.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message = settings.iCloudSyncMessage { Text(settings.text(message)).font(.footnote).foregroundStyle(.secondary) }
            }
            #endif
            Section("On This Device") {
                if SharedAppContainer.url == nil {
                    Text("Settings also sync through the shared Keychain. If your signing tool removes both sharing permissions, copy configuration from the main app and paste it here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button { settings.refreshSharedPreferences() } label: { Label("Refresh Shared Settings", systemImage: "arrow.clockwise") }
                #if !SCREEN_TRANSLATE_SHARE_EXTENSION
                Button {
                    do {
                        let token = try settings.configurationTransfer()
                        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: token]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
                        transferMessage = "Configuration copied for 60 seconds. It includes API keys, stays on this device, and can be pasted in the translation sheet’s settings."
                    } catch { transferMessage = error.localizedDescription }
                } label: { Label("Copy Configuration & API Keys", systemImage: "doc.on.clipboard") }
                #endif
                HStack {
                    Text("Import Configuration")
                    Spacer()
                    PasteButton(payloadType: String.self) { tokens in
                        do {
                            guard let token = tokens.first else { return }
                            try settings.importConfiguration(token)
                            transferMessage = "Configuration imported. Your saved AI services are now available here."
                        } catch { transferMessage = error.localizedDescription }
                    }
                }
                if let message = settings.synchronizationError { Text(settings.text(message)).font(.footnote).foregroundStyle(.orange) }

            }
        }.navigationTitle("Configuration Sync").navigationBarTitleDisplayMode(.inline)
        .alert("Configuration Sync", isPresented: Binding(get: { transferMessage != nil }, set: { if !$0 { transferMessage = nil } })) {
            Button("OK", role: .cancel) { transferMessage = nil }
        } message: { Text(settings.text(transferMessage ?? "")) }
    }
}
