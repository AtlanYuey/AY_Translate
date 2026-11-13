import SwiftUI
import UIKit

/// A Share extension, discoverable by Shortcuts' Share with App, requesting
/// full-screen presentation. The system host can still choose a sheet.
/// It is hosted above the invoking app. Completing
/// the extension request returns to that host; it never foregrounds our app.
@MainActor
final class ShareViewController: UIViewController {
    private static weak var activeController: ShareViewController?
    private var state: AppState?
    private var loading: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var host: ResultHostingController?
    private var pendingImage: UIImage?
    private var didStartLoading = false
    private var presentationReady = false
    private var waitingForPresentation = false
    private var completed = false
    private let createdAt = Date()
    /// The earlier request whose work this one shows (a repeated trigger).
    private var borrowed: ShareViewController?
    /// The settings singleton was built by this process's first request; only
    /// later requests need to re-read what the app changed in the meantime.
    private static var servedBefore = false

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
        let state: AppState
        if let earlier = Self.activeController, let running = earlier.adoptableState {
            // Triggered again while the first request is still working (a
            // double tap that seemed to do nothing): keep that work and show
            // it here instead of starting over and paying twice. This second
            // screenshot only pictures the first one's loading screen.
            state = running
            borrowed = earlier
            didStartLoading = true
            earlier.lendWork()
            ProcessingDiagnostics.shared.event("repeated_trigger")
        } else {
            // Shortcuts can end its presentation without invoking our Close
            // button. A new request is definitive replacement evidence: release
            // any old SwiftUI host/session before allocating the next screenshot.
            Self.activeController?.releaseResources(outcome: "replaced")
            if Self.servedBefore { settings.refreshSharedPreferences() }
            state = AppState(settings: settings, history: .shared)
            state.beginImport()
        }
        Self.servedBefore = true
        Self.activeController = self
        self.state = state
        let host = ResultHostingController(rootView: AnyView(TranslationResultView(onClose: { [weak self] in self?.finish() }, onOpenApp: { [weak self] in self?.openContainingApp() })
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
        ProcessingDiagnostics.shared.event("view_ready")
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
                let image = try await SharedImageLoader.load(from: items, consumesInput: true)
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

    /// Open the app itself (for Settings and the rest) and end this overlay.
    /// An extension has no direct way to open its app: the request travels up
    /// the responder chain to the process's application object.
    private func openContainingApp() {
        guard let url = URL(string: "aytranslate://open") else { return }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector), let method = class_getInstanceMethod(type(of: current), selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                unsafeBitCast(method_getImplementation(method), to: Open.self)(current, selector, url as NSURL, NSDictionary(), nil)
                break
            }
            responder = current.next
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.finish()
        }
    }

    /// Work a repeated trigger may take over: recent, unfinished, and not in
    /// the middle of the view-bound Apple translation session.
    private var adoptableState: AppState? {
        guard !completed, let state, Date().timeIntervalSince(createdAt) < 12, state.appleRequestID == nil else { return nil }
        switch state.phase {
        case .loading, .reading, .translating, .preparing, .awaitingAssist, .awaitingConsent: return state
        case .idle, .ready, .failed: return nil
        }
    }

    /// Hand this request's screen to the newer one. Its image may still be
    /// loading: that continues here, and recognition starts as soon as it is in.
    private func lendWork() {
        host?.releaseResult()
        host = nil
        presentationReady = true
        startWhenPresented()
    }

    /// The newer request closed (or was replaced): end this one with it.
    private func endLent() {
        guard !completed else { return }
        completed = true
        loading?.cancel(); starting?.cancel()
        loading = nil; starting = nil; pendingImage = nil; state = nil
        borrowed?.endLent(); borrowed = nil
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func finish() {
        guard !completed else { return }
        releaseResources(outcome: "closed")
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func releaseResources(outcome: String) {
        guard !completed else { return }
        completed = true
        loading?.cancel()
        starting?.cancel()
        loading = nil; starting = nil; pendingImage = nil
        state?.closeResult(outcome: outcome)
        host?.releaseResult()
        host = nil; state = nil
        borrowed?.endLent(); borrowed = nil
        if Self.activeController === self { Self.activeController = nil }
    }
}
