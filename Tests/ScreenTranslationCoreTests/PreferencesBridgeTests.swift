import Foundation
import XCTest
@testable import ScreenTranslationCore

final class PreferencesBridgeTests: XCTestCase {
    @MainActor func testSeparateSandboxesSharePreferencesThroughTheCredentialStore() async throws {
        let name = "BridgeTest." + UUID().uuidString
        let main = UserDefaults(suiteName: name)!, sheet = UserDefaults(suiteName: name + ".sheet")!
        defer { main.removePersistentDomain(forName: name); sheet.removePersistentDomain(forName: name + ".sheet") }
        let store = BridgeTestStore()
        main.set("ja", forKey: "defaultTargetLanguage")
        main.set("zh-Hans", forKey: "interfaceLanguage")
        main.set("do-not-copy", forKey: "unrelated.private")
        try PreferencesBridge.synchronize(main, store: store)
        try PreferencesBridge.synchronize(sheet, store: store)
        XCTAssertEqual(sheet.string(forKey: "defaultTargetLanguage"), "ja")
        XCTAssertEqual(sheet.string(forKey: "interfaceLanguage"), "zh-Hans")
        XCTAssertNil(sheet.object(forKey: "unrelated.private"))
        main.set("es", forKey: "defaultTargetLanguage")
        try PreferencesBridge.update("es", key: "defaultTargetLanguage", defaults: main, store: store)
        try PreferencesBridge.synchronize(sheet, store: store)
        XCTAssertEqual(sheet.string(forKey: "defaultTargetLanguage"), "es")
    }

    @MainActor func testUnavailableMirrorDoesNotReplaceNewLocalSettingsWithOldValues() async throws {
        let name = "BridgeTest." + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BridgeTestStore()
        defaults.set("old", forKey: "ai.services.v1")
        try PreferencesBridge.synchronize(defaults, store: store)
        store.failWrites = true
        defaults.set("new", forKey: "ai.services.v1")
        XCTAssertThrowsError(try PreferencesBridge.update("new", key: "ai.services.v1", defaults: defaults, store: store))
        XCTAssertThrowsError(try PreferencesBridge.synchronize(defaults, store: store))
        XCTAssertEqual(defaults.string(forKey: "ai.services.v1"), "new")
        store.failWrites = false
        try PreferencesBridge.synchronize(defaults, store: store)
        XCTAssertEqual(try PreferencesBridge.read(from: store)["ai.services.v1"] as? String, "new")
    }

    @MainActor func testRevocationAndMissingMirrorPreserveTheIntendedLocalState() async throws {
        let name = "BridgeTest." + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BridgeTestStore(), consent = "cloudConsent.translation.test"
        defaults.set("approved-endpoint", forKey: consent)
        defaults.set("my-service", forKey: "ai.services.v1")
        try PreferencesBridge.synchronize(defaults, store: store)
        defaults.removeObject(forKey: consent)
        try PreferencesBridge.update(nil, key: consent, defaults: defaults, store: store)
        XCTAssertNil(try PreferencesBridge.read(from: store)[consent])
        try store.save("", for: .sharedPreferences)
        try PreferencesBridge.synchronize(defaults, store: store)
        XCTAssertEqual(defaults.string(forKey: "ai.services.v1"), "my-service")
        XCTAssertNil(defaults.object(forKey: consent))
    }
}

@MainActor private final class BridgeTestStore: APIKeyStoring {
    private var values: [APIKeySlot: String] = [:]
    var failWrites = false
    func read(_ profile: APIKeySlot) throws -> String { values[profile] ?? "" }
    func save(_ key: String, for profile: APIKeySlot) throws {
        if failWrites { throw BridgeTestError.unavailable }
        values[profile] = key
    }
}
private enum BridgeTestError: Error { case unavailable }
