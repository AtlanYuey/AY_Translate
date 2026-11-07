#if DEBUG && !SCREEN_TRANSLATE_SHARE_EXTENSION
import SwiftUI
import UIKit

/// Debug-only host used to exercise the real system activity extension in CI.
struct ShareExtensionTestHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SourceViewController { SourceViewController() }
    func updateUIViewController(_ controller: SourceViewController, context: Context) {}
}

final class SourceViewController: UIViewController {
    private let image = SourceViewController.testImage(0)
    private var invocation = 0
    private static func testImage(_ number: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.preferredRange = .standard
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
            ("Hello World \(number)\nA screenshot from the source app." as NSString).draw(in: CGRect(x: 24, y: 160, width: 342, height: 220), withAttributes: [.font: UIFont.systemFont(ofSize: 25), .foregroundColor: UIColor.black])
            for row in 0..<5 {
                for column in 0..<3 {
                    let rect = CGRect(x: 14 + column * 124, y: 370 + row * 70, width: 112, height: 58)
                    UIColor(white: CGFloat(90 + (number + row) % 10) / 100, alpha: 1).setFill()
                    context.fill(rect)
                    ("Panel \(row)-\(column)\nSmall print survives." as NSString).draw(in: rect.insetBy(dx: 4, dy: 4),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black])
                }
            }
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: SourceContent(image: image, share: { [weak self] in self?.share() }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    private func share() {
        invocation += 1
        let controller = UIActivityViewController(activityItems: [Self.testImage(invocation)], applicationActivities: nil)
        if traitCollection.userInterfaceIdiom == .phone {
            controller.modalPresentationStyle = .pageSheet
        } else {
            controller.popoverPresentationController?.sourceView = view
            controller.popoverPresentationController?.sourceRect = view.bounds
        }
        // Use the actual system sharing presenter. Wrapping an activity
        // controller in SwiftUI.sheet creates an extra page-sheet container.
        present(controller, animated: true)
    }
}

private struct SourceContent: View {
    let image: UIImage
    let share: () -> Void
    var body: some View {
        VStack {
            Text("Source app").accessibilityIdentifier("share.test.source")
            Image(uiImage: image).resizable().scaledToFit()
            Button("Share Test Screenshot", action: share).accessibilityIdentifier("share.test.present")
        }
    }
}
#endif
