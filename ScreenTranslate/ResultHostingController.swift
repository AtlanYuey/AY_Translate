import SwiftUI
import UIKit

/// Drop SwiftUI image/repair state before completing an extension request.
/// The system may retain its principal controller for the next invocation.
@MainActor
final class ResultHostingController: UIHostingController<AnyView> {
    func releaseResult() {
        func releaseChildren(_ controller: UIViewController) {
            for child in controller.children { releaseChildren(child) }
            (controller as? any ImageResourceReleasing)?.releaseImageResources()
        }
        releaseChildren(self)
        rootView = AnyView(EmptyView())
        willMove(toParent: nil)
        view.removeFromSuperview()
        removeFromParent()
    }
}
