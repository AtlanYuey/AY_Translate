import SwiftUI
import UIKit

/// A Share extension, discoverable by Shortcuts' Share with App, requesting
/// full-screen presentation. The system host can still choose a sheet.
/// It is hosted above the invoking app. Completing
/// the extension request returns to that host; it never foregrounds our app.
@MainActor
final class ShareViewController: UIViewController {
    private var state: AppState?
    private var loading: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var host: ResultHostingController?
    private var pendingImage: UIImage?
    private var didStartLoading = false
    private var presentationReady = false
    private var waitingForPresentation = false
    private var completed = false

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .fullScreen
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Configure presentation in init, before the system presents the
        // principal controller. viewDidLoad can run after adaptation to a sheet.
        view.backgroundColor = .clear
        view.isOpaque = false
        isModalInPresentation = true
        let settings = AppSettings.shared
        settings.refreshSharedPreferences()
        let state = AppState(settings: settings, history: .shared)
        self.state = state
        state.beginImport()
        let host = ResultHostingController(rootView: AnyView(TranslationResultView(onClose: { [weak self] in self?.finish() })
            .environmentObject(state).environmentObject(settings).environmentObject(state.history)
            .environment(\.locale, settings.interfaceLocale).environment(\.layoutDirection, settings.interfaceLayoutDirection)))
        self.host = host
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        host.isModalInPresentation = true
        loadSharedImageIfAvailable()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationReady = true
        loadSharedImageIfAvailable()
        if !didStartLoading { state?.failImport(SharedImageError.noImage) }
        startWhenPresented()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A remote Share host may attach the window without forwarding the
        // principal controller's appearance callback. Do not strand import in
        // that state. Respect an available transition before starting Vision.
        guard view.window != nil, !presentationReady, !waitingForPresentation, !completed else { return }
        waitingForPresentation = true
        if let coordinator = transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] _ in self?.didAttachPresentation() }) { return }
        didAttachPresentation()
    }

    private func didAttachPresentation() {
        guard !completed else { return }
        presentationReady = true
        startWhenPresented()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !completed, state?.isProcessing == true { ProcessingDiagnostics.shared.event("host_disappeared") }
    }

    private func loadSharedImageIfAvailable() {
        guard !didStartLoading, !completed else { return }
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        // Usually available in viewDidLoad: decode during presentation rather
        // than waiting for its animation to finish. Retry when the host appears.
        guard !items.isEmpty else { return }
        didStartLoading = true
        let state = self.state
        loading = Task { [weak self, weak state] in
            do {
                let image = try await SharedImageLoader.load(from: items)
                try Task.checkCancellation()
                guard let self, !completed else { return }
                pendingImage = image
                state?.displayImportedImage(image)
                startWhenPresented()
            } catch is CancellationError { return }
            catch { if self?.completed == false { state?.failImport(error) } }
        }
    }

    private func startWhenPresented() {
        guard presentationReady, pendingImage != nil, starting == nil, !completed else { return }
        starting = Task { [weak self] in
            // Give the transparent loading view one display turn before Vision
            // allocates its model buffers. This is not a processing timeout.
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self, !completed, let image = pendingImage else { return }
            pendingImage = nil
            state?.process(image)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        ProcessingMemory.receivedWarning()
        state?.releaseOptionalResources()
    }

    deinit { loading?.cancel(); starting?.cancel() }

    private func finish() {
        guard !completed else { return }
        completed = true
        loading?.cancel()
        starting?.cancel()
        loading = nil; starting = nil; pendingImage = nil
        state?.closeResult()
        host?.releaseResult()
        host = nil; state = nil
        extensionContext?.completeRequest(returningItems: nil)
    }
}
