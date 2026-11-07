import SwiftUI
import UIKit

/// UIKit keeps the pinch centroid under the fingers, with native inertia and
/// rubber-banding. SwiftUI only redraws when content/settings change, not per pan.
struct NativeZoomScroll<Content: View>: UIViewControllerRepresentable {
    let size: CGSize
    let resetID: UUID
    let zoomChanged: (CGFloat) -> Void
    let allowsDismiss: Bool
    let dismissAction: () -> Void
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> ZoomScrollController<Content> {
        ZoomScrollController(root: content())
    }
    func updateUIViewController(_ controller: ZoomScrollController<Content>, context: Context) {
        controller.host.rootView = AnyView(content())
        controller.onZoom = zoomChanged
        controller.onDismiss = dismissAction
        controller.allowsDismiss = allowsDismiss
        controller.update(size: size, resetID: resetID)
    }

    static func dismantleUIViewController(_ controller: ZoomScrollController<Content>, coordinator: ()) {
        controller.releaseImageResources()
    }
}

@MainActor
protocol ImageResourceReleasing: AnyObject {
    func releaseImageResources()
}

final class ZoomScrollController<Content: View>: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate, ImageResourceReleasing {
    let scroll = UIScrollView()
    let host: UIHostingController<AnyView>
    var onZoom: (CGFloat) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var allowsDismiss = true
    private var fitted = CGSize.zero
    private var resetID: UUID?
    private var reportedZoomed = false
    private var edgeSwipe: UIPanGestureRecognizer!

    init(root: Content) { host = UIHostingController(rootView: AnyView(root)); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func releaseImageResources() {
        scroll.delegate = nil
        onZoom = { _ in }; onDismiss = {}; allowsDismiss = false
        scroll.layer.removeAllAnimations()
        host.rootView = AnyView(EmptyView())
        if host.parent != nil {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        host.safeAreaRegions = []
        scroll.frame = view.bounds; scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true; scroll.decelerationRate = .normal
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self; scroll.backgroundColor = .black
        view.addSubview(scroll)
        addChild(host); scroll.addSubview(host.view); host.didMove(toParent: self)
        host.view.backgroundColor = .clear
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        edgeSwipe = UIPanGestureRecognizer(target: self, action: #selector(edgePanned(_:)))
        edgeSwipe.maximumNumberOfTouches = 1; edgeSwipe.delegate = self
        view.addGestureRecognizer(edgeSwipe)
    }

    func update(size: CGSize, resetID: UUID) {
        loadViewIfNeeded()
        if fitted != size, size.width > 0, size.height > 0 {
            let zoom = scroll.zoomScale
            let center = CGPoint(x: (scroll.contentOffset.x + scroll.bounds.width / 2) / max(1, fitted.width * zoom),
                                 y: (scroll.contentOffset.y + scroll.bounds.height / 2) / max(1, fitted.height * zoom))
            let hadContent = fitted != .zero
            scroll.setZoomScale(1, animated: false)
            fitted = size
            host.view.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size
            if hadContent {
                scroll.setZoomScale(zoom, animated: false)
                centerContent()
                let x = min(1, max(0, center.x)) * size.width * zoom - scroll.bounds.width / 2
                let y = min(1, max(0, center.y)) * size.height * zoom - scroll.bounds.height / 2
                scroll.contentOffset = CGPoint(
                    x: min(max(-scroll.contentInset.left, x), max(-scroll.contentInset.left, scroll.contentSize.width - scroll.bounds.width + scroll.contentInset.right)),
                    y: min(max(-scroll.contentInset.top, y), max(-scroll.contentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.contentInset.bottom)))
            }
        }
        if self.resetID != resetID {
            let animated = self.resetID != nil
            self.resetID = resetID
            scroll.setZoomScale(1, animated: animated)
        }
        centerContent()
    }

    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); centerContent() }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        let zoom = scrollView.zoomScale
        // The parent only needs to know whether dismissal is safe. Publishing
        // every pinch frame would rebuild all SwiftUI text canvases mid-gesture.
        let zoomed = zoom > 1.01
        if zoomed != reportedZoomed {
            reportedZoomed = zoomed
            Task { @MainActor [weak self] in self?.onZoom(zoom) }
        }
    }
    private func centerContent() {
        let x = max(0, (scroll.bounds.width - fitted.width * scroll.zoomScale) / 2)
        let y = max(0, (scroll.bounds.height - fitted.height * scroll.zoomScale) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if scroll.contentInset != inset { scroll.contentInset = inset }
    }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: true); return }
        let point = gesture.location(in: host.view), scale: CGFloat = 2.5
        let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === edgeSwipe else { return true }
        return shouldBeginBottomDismiss(edgeSwipe)
    }
    func shouldBeginBottomDismiss(_ gesture: UIPanGestureRecognizer) -> Bool {
        // The delegate is called after the finger has moved. A fast first
        // sample may already be outside the bottom strip. Recover the actual
        // touch origin in the stationary viewport, not the scrolling content.
        let location = gesture.location(in: view)
        let translation = gesture.translation(in: view)
        let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
        let velocity = gesture.velocity(in: view)
        return allowsDismiss && scroll.zoomScale <= 1.01 && view.bounds.contains(start)
            && start.y > view.bounds.maxY - 110
            && velocity.y < 0 && abs(velocity.y) > abs(velocity.x) * 1.5
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === edgeSwipe || other === edgeSwipe
    }
    @objc private func edgePanned(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .ended, allowsDismiss, scroll.zoomScale <= 1.01, gesture.translation(in: view).y < -100 { onDismiss() }
    }
}
