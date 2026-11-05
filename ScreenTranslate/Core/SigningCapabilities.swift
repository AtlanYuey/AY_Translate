import Foundation

nonisolated enum SigningCapabilities {
    /// The embedded CMS provisioning profile contains a plist describing which
    /// entitlements the certificate permits. Missing profiles (e.g. App Store,
    /// simulator) are unknown, not a denial. Never expose its account metadata.
    static func permitsCloudSettings(profile: Data) -> Bool? {
        guard profile.count <= 2_000_000,
              let start = profile.range(of: Data("<plist".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return (entitlements["com.apple.developer.ubiquity-kvstore-identifier"] as? String)?.isEmpty == false
    }
}
