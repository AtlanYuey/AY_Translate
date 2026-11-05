import SwiftUI

/// An app-owned activity indicator. It does not start Siri or use private UI.
struct ProcessingEdgeGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let angle = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) * 120
            let colors: [Color] = [.cyan, .blue, .purple, .pink, .orange, .cyan]
            let gradient = AngularGradient(colors: colors, center: .center, angle: .degrees(angle))
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(gradient, lineWidth: 3)
                .shadow(color: .blue.opacity(0.65), radius: 8)
                .padding(3)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
