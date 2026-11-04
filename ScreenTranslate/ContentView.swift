import PhotosUI
import SwiftUI
import Translation
import UIKit

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var selectedTab = 0
    @State private var showsOnboarding = false
    @State private var showsFirstSetup = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView()
            }
            .tabItem { Label("Translate", systemImage: "viewfinder") }
            .tag(0)

            if settings.savesHistory {
                NavigationStack { HistoryView() }
                    .tabItem { Label("History", systemImage: "clock") }.tag(1)
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(2)
        }
        .tint(.blue)
        .fullScreenCover(isPresented: $showsOnboarding) {
            OnboardingView {
                hasCompletedOnboarding = true
                showsOnboarding = false
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    showsFirstSetup = true
                }
            }
        }
        .sheet(isPresented: $showsFirstSetup) {
            ShortcutSetupView()
        }
        .fullScreenCover(isPresented: $appState.presentsResult) { TranslationResultView() }
        .onChange(of: settings.savesHistory) { _, enabled in
            if !enabled && selectedTab == 1 { selectedTab = 0 }
        }
        .task {
            if !hasCompletedOnboarding {
                showsOnboarding = true
            }
            loadPendingShortcutImage()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                settings.refreshSharedPreferences()
                appState.history.load()
                loadPendingShortcutImage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pendingScreenshotReady)) { _ in
            loadPendingShortcutImage()
        }
    }

    private func loadPendingShortcutImage() {
        if let image = PendingScreenshotStore.take() {
            appState.process(image)
        }
    }
}

private struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @State private var photoItem: PhotosPickerItem?
    @State private var showsSetup = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                hero
                languageCard
                setupCard
                privacyNote
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Translate Screen")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showsSetup) {
            ShortcutSetupView()
        }
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                guard let data = try? await newValue.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                appState.process(image)
                photoItem = nil
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 104, height: 104)
                Image(systemName: "viewfinder")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.blue)
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white, .blue)
                    .offset(x: 34, y: 34)
            }

            VStack(spacing: 8) {
                Text("Translate anything\nyou can see")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Turn any screenshot into a translated screen in seconds.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Translate Screenshot", systemImage: "photo.badge.magnifyingglass")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.top, 8)
    }

    private var languageCard: some View {
        VStack(spacing: 0) {
            LanguageRow(title: "Source Language", selection: $settings.source, options: AppLanguage.sourceLanguages)
            Divider().padding(.leading, 54)
            LanguageRow(title: "Target Language", selection: $settings.target, options: AppLanguage.targetLanguages)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "button.programmable")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 42)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Action Button Setup").font(.headline)
                    Text("Translate with one press").font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Text("Use the Action Button to capture and translate whatever is on your screen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                showsSetup = true
            } label: {
                Text("Set Up Shortcut")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var privacyNote: some View {
        Label(LocalizedStringKey(settings.ocrEngine == .appleVision && settings.translationEngine == .apple
              ? "Free on-device engines · No account · No ads"
              : "Cloud AI selected · Sharing requires your permission"),
              systemImage: settings.ocrEngine == .appleVision && settings.translationEngine == .apple ? "lock.shield.fill" : "cloud")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }
}

private struct LanguageRow: View {
    @EnvironmentObject private var settings: AppSettings
    let title: String
    @Binding var selection: AppLanguage
    let options: [AppLanguage]

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: selection.symbol)
                .foregroundStyle(.blue)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
                Text(selection == .automatic ? settings.text(selection.name) : selection.nativeName).font(.body.weight(.medium))
            }
            Spacer()
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options) { language in
                        Text(language == .automatic ? settings.text(language.name) : language.nativeName).tag(language)
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
        .padding(16)
    }
}
