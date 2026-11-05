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
                settings.resumeSettingsSync()
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
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: geometry.size.height < 500 ? 16 : 28) {
                    Spacer(minLength: 0)
                    Image(systemName: "viewfinder")
                        .font(.system(size: geometry.size.height < 500 ? 36 : 64, weight: .light))
                        .foregroundStyle(.blue.gradient)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("Choose an image. Read it in your language.")
                            .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                        Text("Screenshots and photos, translated in place.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    languageCard
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose Image to Translate", systemImage: "photo.badge.magnifyingglass")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .accessibilityIdentifier("home.choose-image")
                    Label(LocalizedStringKey(settings.ocrEngine == .appleVision && settings.translationEngine == .apple
                          ? "Free on-device engines · No account · No ads" : "Cloud AI selected · Sharing requires your permission"),
                          systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                }
                .padding(24).frame(maxWidth: 560)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("AY Translate")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                guard let data = try? await newValue.loadTransferable(type: Data.self),
                      let image = try? ScreenshotInput.decode(data) else { return }
                appState.process(image)
                photoItem = nil
            }
        }
    }

    private var languageCard: some View {
        VStack(spacing: 0) {
            LanguageRow(title: "Source Language", selection: $settings.source, options: AppLanguage.sourceLanguages)
            Divider().padding(.leading, 54)
            LanguageRow(title: "Target Language", selection: $settings.target, options: AppLanguage.targetLanguages)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                Picker(LocalizedStringKey(title), selection: $selection) {
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
