import Foundation

/// KVS is only touched after explicit opt-in in the containing app. Signing
/// profiles must keep its iCloud entitlement. Extensions use the local bridge.
@MainActor
final class CloudSettingsSync {
    private let defaults: UserDefaults
    private let store: NSUbiquitousKeyValueStore
    private let apply: ([String: Any]) -> Bool
    private let status: (String) -> Void
    private var observer: NSObjectProtocol?
    private let device: String
    private var active = false
    private let prefix = "ay.settings.v1."

    init(defaults: UserDefaults, store: NSUbiquitousKeyValueStore = .default,
         apply: @escaping ([String: Any]) -> Bool, status: @escaping (String) -> Void) {
        self.defaults = defaults; self.store = store; self.apply = apply; self.status = status
        device = defaults.string(forKey: "icloud.device") ?? UUID().uuidString
        defaults.set(device, forKey: "icloud.device")
    }

    func start() {
        active = true
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            Task { @MainActor [weak self] in
                guard let self, active else { return }
                if reason == NSUbiquitousKeyValueStoreAccountChange {
                    stop()
                    defaults.set(false, forKey: "iCloudSyncEnabled")
                    status("iCloud account changed. Enable sync again to choose this account.")
                    return
                }
                if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
                    status("iCloud storage quota exceeded. Local settings are still available.")
                    return
                }
                merge()
            }
        }
        if !store.synchronize() { status("iCloud sync is unavailable. Check your iCloud account and signing profile.") }
        else { status("iCloud settings sync requested. Other devices update when the app opens.") }
        merge()
    }

    func stop() {
        active = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func changed(_ value: Any, key: String) {
        guard CloudSettingsRecord.allowedKeys.contains(key),
              let record = try? CloudSettingsRecord(value: value, timestamp: Date().timeIntervalSince1970, device: device),
              record.decodedValue(for: key) != nil,
              let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: prefix + key)
        store.set(data, forKey: prefix + key)
    }

    func merge() {
        var changes: [String: Any] = [:]
        var accepted: [String: Data] = [:]
        for key in CloudSettingsRecord.allowedKeys {
            let remote = store.data(forKey: prefix + key).flatMap { try? JSONDecoder().decode(CloudSettingsRecord.self, from: $0) }
            let local = defaults.data(forKey: prefix + key).flatMap { try? JSONDecoder().decode(CloudSettingsRecord.self, from: $0) }
            if let remote, let value = remote.decodedValue(for: key), remote.isNewer(than: local) {
                changes[key] = value
                accepted[key] = try? JSONEncoder().encode(remote)
            } else if let local, local.isNewer(than: remote), local.decodedValue(for: key) != nil {
                store.set(try? JSONEncoder().encode(local), forKey: prefix + key)
            } else if remote == nil, local == nil, let value = defaults.object(forKey: key) {
                changed(value, key: key)
            }
        }
        if !changes.isEmpty && apply(changes) {
            for (key, data) in accepted { defaults.set(data, forKey: prefix + key) }
        }
    }
}
