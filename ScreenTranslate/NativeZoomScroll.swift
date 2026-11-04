import SwiftUI
import UIKit

/// UIKit keeps the pinch centroid under the fingers, with native inertia and
/// rubber-banding. SwiftUI only redraws when content/settings change, not per pan.
struct NativeZoomScroll<Content: View>: UIViewControllerRepresentable {
    let size: CGSize
    let resetID: UUID
    let zoomChanged: (CGFloat) -> Void
    let dismissAction: () -> Void
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> ZoomScrollController<Content> {
        ZoomScrollController(root: content())
    }
    func updateUIViewController(_ controller: ZoomScrollController<Content>, context: Context) {
        controller.host.rootView = content()
        controller.onZoom = zoomChanged
        controller.onDismiss = dismissAction
        controller.update(size: size, resetID: resetID)
    }
}

final class ZoomScrollController<Content: View>: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scroll = UIScrollView()
    let host: UIHostingController<Content>
    var onZoom: (CGFloat) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    private var fitted = CGSize.zero
    private var resetID: UUID?
    private var reportedZoomed = false
    private var swipeStart = CGPoint.zero
    private var edgeSwipe: UIPanGestureRecognizer!

    init(root: Content) { host = UIHostingController(rootView: root); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

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
        scroll.addGestureRecognizer(edgeSwipe)
    }

    func update(size: CGSize, resetID: UUID) {
        loadViewIfNeeded()
        if fitted != size, size.width > 0, size.height > 0 {
            let zoom = scroll.zoomScale
            let center = CGPoint(x: (scroll.contentOffset.x + scroll.bounds.midX) / max(1, fitted.width * zoom),
                                 y: (scroll.contentOffset.y + scroll.bounds.midY) / max(1, fitted.height * zoom))
            let hadContent = fitted != .zero
            scroll.setZoomScale(1, animated: false)
            fitted = size
            host.view.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size
            if hadContent {
                scroll.setZoomScale(zoom, animated: false)
                centerContent()
                scroll.contentOffset = CGPoint(x: min(1, max(0, center.x)) * size.width * zoom - scroll.bounds.midX,
                                               y: min(1, max(0, center.y)) * size.height * zoom - scroll.bounds.midY)
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
        swipeStart = gestureRecognizer.location(in: scroll)
        let velocity = edgeSwipe.velocity(in: scroll)
        return scroll.zoomScale <= 1.01 && swipeStart.y > scroll.bounds.maxY - 110
            && velocity.y < 0 && abs(velocity.y) > abs(velocity.x) * 1.5
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === edgeSwipe || other === edgeSwipe
    }
    @objc private func edgePanned(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .ended, scroll.zoomScale <= 1.01, gesture.translation(in: scroll).y < -100 { onDismiss() }
    }
}
