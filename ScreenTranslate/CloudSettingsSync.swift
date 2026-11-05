import Foundation

@MainActor
protocol CloudKeyValueStoring: AnyObject {
    var dictionaryRepresentation: [String: Any] { get }
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStoring {}

/// KVS is only touched after explicit opt-in in the containing app. Signing
/// profiles must keep its iCloud entitlement. Extensions use the local bridge.
@MainActor
final class CloudSettingsSync {
    private let defaults: UserDefaults
    private let store: any CloudKeyValueStoring
    private let apply: ([String: Any]) -> Bool
    private let status: (String) -> Void
    private var observer: NSObjectProtocol?
    private var uploadTask: Task<Void, Never>?
    private let device: String
    private var active = false
    private let prefix = "ay.settings.v1."
    private let remotePrefix = "ay.settings.v2."

    private func remoteKey(_ key: String) -> String { remotePrefix + device + "." + key }

    init(defaults: UserDefaults, store: any CloudKeyValueStoring = NSUbiquitousKeyValueStore.default,
         apply: @escaping ([String: Any]) -> Bool, status: @escaping (String) -> Void) {
        self.defaults = defaults; self.store = store; self.apply = apply; self.status = status
        device = defaults.string(forKey: "icloud.device") ?? UUID().uuidString
        defaults.set(device, forKey: "icloud.device")
    }

    func start() {
        guard !active else { return }
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
        // Seed existing saved choices automatically. A migration baseline is
        // older than any dated remote edit, so another device's record wins.
        // Unset defaults are not seeded. Later explicit edits use real dates.
        for key in CloudSettingsRecord.allowedKeys where defaults.data(forKey: prefix + key) == nil {
            if let value = defaults.object(forKey: key),
               let record = try? CloudSettingsRecord(value: value, timestamp: 1, device: device),
               record.decodedValue(for: key) != nil {
                defaults.set(try? JSONEncoder().encode(record), forKey: prefix + key)
            }
        }
        resume()
        scheduleUpload()
    }

    func stop() {
        active = false
        uploadTask?.cancel(); uploadTask = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func changed(_ value: Any, key: String) {
        guard active, CloudSettingsRecord.allowedKeys.contains(key),
              let record = try? CloudSettingsRecord(value: value, timestamp: Date().timeIntervalSince1970, device: device),
              record.decodedValue(for: key) != nil,
              let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: prefix + key)
        store.set(data, forKey: remoteKey(key))
        scheduleUpload()
    }

    private func scheduleUpload() {
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self, active else { return }
            requestSynchronization()
        }
    }

    private func requestSynchronization() {
        if !store.synchronize() { status("iCloud sync is unavailable. Check your iCloud account and signing profile.") }
        else { status("Automatic sync is active. Changes are queued to iCloud; delivery depends on the account and network.") }
    }

    /// Reconcile edits made in the Share extension while the app was suspended.
    /// iCloud does not require the user to press an upload button on returning.
    func resume() {
        guard active else { return }
        for key in CloudSettingsRecord.allowedKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            let current = try? PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
            let record = defaults.data(forKey: prefix + key).flatMap { try? JSONDecoder().decode(CloudSettingsRecord.self, from: $0) }
            if current != record?.value { changed(value, key: key) }
        }
        requestSynchronization()
        merge()
    }

    func uploadLocalSettings() {
        guard active else { return }
        for key in CloudSettingsRecord.allowedKeys {
            if let value = defaults.object(forKey: key) { changed(value, key: key) }
        }
        requestSynchronization()
    }

    func merge() {
        guard active else { return }
        var changes: [String: Any] = [:]
        var accepted: [String: Data] = [:]
        let cloudValues = store.dictionaryRepresentation
        for key in CloudSettingsRecord.allowedKeys {
            // Each device writes only its own slot. A new install cannot erase
            // another device's unseen settings while the first download is in
            // flight. Continue reading v1 records for upgrade compatibility.
            let candidates = cloudValues.filter { $0.key == prefix + key || ($0.key.hasPrefix(remotePrefix) && $0.key.hasSuffix("." + key)) }
            let records = candidates.values.compactMap { value -> CloudSettingsRecord? in
                guard let data = value as? Data, let record = try? JSONDecoder().decode(CloudSettingsRecord.self, from: data),
                      record.decodedValue(for: key) != nil else { return nil }
                return record
            }
            let remote = records.reduce(nil as CloudSettingsRecord?) { latest, record in record.isNewer(than: latest) ? record : latest }
            let local = defaults.data(forKey: prefix + key).flatMap { try? JSONDecoder().decode(CloudSettingsRecord.self, from: $0) }
            if let remote, let value = remote.decodedValue(for: key), remote.isNewer(than: local) {
                changes[key] = value
                accepted[key] = try? JSONEncoder().encode(remote)
            } else if let local, local.isNewer(than: remote), local.decodedValue(for: key) != nil {
                store.set(try? JSONEncoder().encode(local), forKey: remoteKey(key))
            }
        }
        if !changes.isEmpty && apply(changes) {
            for (key, data) in accepted { defaults.set(data, forKey: prefix + key) }
        }
    }
}
