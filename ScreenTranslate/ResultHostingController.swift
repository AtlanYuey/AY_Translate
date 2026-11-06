import SwiftUI
import UIKit

/// Drop SwiftUI image/repair state before completing an extension request.
/// The system may retain its principal controller for the next invocation.
@MainActor
final class ResultHostingController: UIHostingController<AnyView> {
    func releaseResult() {
        rootView = AnyView(EmptyView())
        willMove(toParent: nil)
        view.removeFromSuperview()
        removeFromParent()
    }
}
