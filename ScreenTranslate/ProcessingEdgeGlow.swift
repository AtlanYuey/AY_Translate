import SwiftUI

/// An app-owned activity indicator. It does not start Siri or use private UI.
struct ProcessingEdgeGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let angle = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) * 120
            let colors: [Color] = [.cyan, .blue, .purple, .pink, .orange, .cyan]
            Canvas { context, size in
                // Keep the entire glow inside the viewport, including rounded
                // displays and sheet masks. No private display-corner API and no
                // full-screen offscreen blur surface on every animation frame.
                let inset: CGFloat = 12
                let radius = min(64, min(size.width, size.height) * 0.17)
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                let path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
                let paint = GraphicsContext.Shading.conicGradient(Gradient(colors: colors),
                    center: CGPoint(x: size.width / 2, y: size.height / 2), angle: .degrees(angle))
                for (width, opacity) in [(10.0, 0.10), (6.0, 0.22), (2.5, 1.0)] {
                    var layer = context
                    layer.opacity = opacity
                    layer.stroke(path, with: paint, lineWidth: width)
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
