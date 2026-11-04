import Foundation
import SwiftUI
import UIKit

@MainActor
final class ShortcutInstaller: NSObject, UIDocumentInteractionControllerDelegate {
    private static let shared = ShortcutInstaller()
    private var controller: UIDocumentInteractionController?
    static let name = "Translate Screen"
    static var bundledFile: URL? { Bundle.main.url(forResource: "TranslateScreen", withExtension: "shortcut") }
    static var runURL: URL {
        var url = URLComponents(string: "shortcuts://run-shortcut")!
        url.queryItems = [URLQueryItem(name: "name", value: name)]
        return url.url!
    }
    static func install() -> Bool { shared.present() }

    private func present() -> Bool {
        guard let file = Self.bundledFile,
              let header = try? Data(contentsOf: file).prefix(4), header == Data("AEA1".utf8),
              var host = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController else { return false }
        while let presented = host.presentedViewController { host = presented }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(Self.name + ".shortcut")
        do {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: file, to: destination)
        } catch { return false }
        let controller = UIDocumentInteractionController(url: destination)
        controller.delegate = self
        self.controller = controller // The menu does not retain its controller.
        return controller.presentOpenInMenu(from: host.view.bounds, in: host.view, animated: true)
    }
}

struct ShortcutFileExport: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [file], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
