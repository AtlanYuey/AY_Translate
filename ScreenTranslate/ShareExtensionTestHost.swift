#if DEBUG && !SCREEN_TRANSLATE_SHARE_EXTENSION
import SwiftUI
import UIKit

/// Debug-only host used to exercise the real system activity extension in CI.
struct ShareExtensionTestHost: View {
    @State private var sharing = false
    private let image: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
            ("Hello World\nA screenshot from the source app." as NSString).draw(in: CGRect(x: 24, y: 160, width: 342, height: 220), withAttributes: [.font: UIFont.systemFont(ofSize: 25), .foregroundColor: UIColor.black])
        }
    }()
    var body: some View {
        VStack {
            Text("Source app").accessibilityIdentifier("share.test.source")
            Image(uiImage: image).resizable().scaledToFit()
            Button("Share Test Screenshot") { sharing = true }.accessibilityIdentifier("share.test.present")
        }
        .sheet(isPresented: $sharing) { SourceActivityView(image: image) { sharing = false } }
    }
}

private struct SourceActivityView: UIViewControllerRepresentable {
    let image: UIImage
    let completion: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
