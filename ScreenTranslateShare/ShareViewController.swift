import SwiftUI
import UIKit

/// A full-screen Action extension, hosted above the invoking app. Completing
/// the extension request returns to that host; it never foregrounds our app.
@MainActor
final class ShareViewController: UIViewController {
    private var state: AppState?
    private var loading: Task<Void, Never>?
    private var completed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        modalPresentationStyle = .fullScreen
        view.backgroundColor = .black
        let settings = AppSettings.shared
        let state = AppState(settings: settings, history: .shared)
        self.state = state
        let host = UIHostingController(rootView: TranslationResultView(onClose: { [weak self] in self?.finish() })
            .environmentObject(state).environmentObject(settings).environmentObject(state.history)
            .environment(\.locale, settings.interfaceLocale).environment(\.layoutDirection, settings.interfaceLayoutDirection))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard loading == nil, !completed else { return }
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let state = self.state
        loading = Task { [weak self, weak state] in
            do {
                let image = try await SharedImageLoader.load(from: items)
                try Task.checkCancellation()
                state?.process(image)
            } catch is CancellationError { return }
            catch { if self?.completed == false { state?.failImport(error) } }
        }
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        loading?.cancel()
        state?.closeResult()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
