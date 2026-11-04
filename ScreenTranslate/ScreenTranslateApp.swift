//
//  ScreenTranslateApp.swift
//  ScreenTranslate
//
//  Created by Bahaa on 15/02/1448 AH.
//

import SwiftUI

@main
struct ScreenTranslateApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var history: HistoryStore
    @StateObject private var appState: AppState

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-reset") {
            let preferences = SharedAppContainer.preferences
            preferences.set("en", forKey: "interfaceLanguage")
            preferences.set("automatic", forKey: "defaultSourceLanguage")
            preferences.set("en", forKey: "defaultTargetLanguage")
            preferences.set(false, forKey: "saveTranslationHistory")
            preferences.set("appleVision", forKey: "ocrEngine")
            preferences.set("apple", forKey: "translationEngine")
            // Isolate UI-test defaults from a previous shared-Keychain snapshot.
            try? KeychainStore().save("", for: .sharedPreferences)
            preferences.removeObject(forKey: "preferences.bridge.bootstrapped")
            preferences.synchronize()
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }
        #endif
        let settings = AppSettings.shared
        let history = HistoryStore.shared
        _settings = StateObject(wrappedValue: settings)
        _history = StateObject(wrappedValue: history)
        _appState = StateObject(wrappedValue: AppState(settings: settings, history: history))
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-share") { ShareExtensionTestHost() }
            else { mainContent }
            #else
            mainContent
            #endif
        }
    }

    private var mainContent: some View {
            ContentView()
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(appState)
                .environment(\.locale, settings.interfaceLocale)
                .environment(\.layoutDirection, settings.interfaceLayoutDirection)
    }
}
