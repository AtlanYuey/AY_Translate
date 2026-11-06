import SwiftUI
import UIKit

/// An app-owned edge light based on Siri's public visual design, not private UI.
/// Small perimeter tiles avoid allocating a screen-sized animated canvas.
struct ProcessingEdgeGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var frameTime: TimeInterval? = nil
    var cornerRadius: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 24 : 64

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || frameTime != nil)) { timeline in
                let time = frameTime ?? (reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
                let radius = min(cornerRadius, min(geometry.size.width, geometry.size.height) / 3)
                let tiles = Self.tiles(size: geometry.size, radius: radius)
                ZStack(alignment: .topLeading) {
                    ForEach(tiles.indices, id: \.self) { index in
                        let tile = tiles[index]
                        Canvas { context, _ in
                            context.clip(to: Path(CGRect(origin: .zero, size: tile.size)))
                            context.translateBy(x: -tile.minX, y: -tile.minY)
                            let path = RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .path(in: CGRect(origin: .zero, size: geometry.size))
                            // The light's centerline is the outer edge. Clip its
                            // outward half at the display contour, leaving a
                            // soft inward glow with no inset frame or corner cuts.
                            context.clip(to: path)
                            let angle = time.truncatingRemainder(dividingBy: 8) / 8 * 360
                            let paint = GraphicsContext.Shading.conicGradient(
                                Gradient(colors: [.cyan, .blue, .purple, .pink, .orange, .pink, .cyan]),
                                center: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2),
                                angle: .degrees(angle + sin(time * 0.7) * 20))
                            let breathe = 1 + 0.12 * sin(time * 2.1)
                            // Fine steps approximate Gaussian falloff without
                            // coarse visible bands or offscreen blur textures.
                            var previousOpacity = 0.0
                            for step in stride(from: 24, through: 1, by: -1) {
                                let distance = Double(step) * 0.75
                                let opacity = 0.92 * exp(-pow(distance / 7.0, 1.35))
                                var layer = context
                                layer.opacity = (opacity - previousOpacity) / (1 - previousOpacity)
                                layer.stroke(path, with: paint, lineWidth: distance * 2 * breathe)
                                previousOpacity = opacity
                            }
                        }
                        .frame(width: tile.width, height: tile.height)
                        .offset(x: tile.minX, y: tile.minY)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    static func tiles(size: CGSize, radius: CGFloat) -> [CGRect] {
        let edge: CGFloat = 24
        let corner = min(max(radius + edge, edge), min(size.width, size.height) / 2)
        let w = size.width, h = size.height
        return [
            CGRect(x: 0, y: 0, width: corner, height: corner),
            CGRect(x: w - corner, y: 0, width: corner, height: corner),
            CGRect(x: 0, y: h - corner, width: corner, height: corner),
            CGRect(x: w - corner, y: h - corner, width: corner, height: corner),
            CGRect(x: corner, y: 0, width: max(0, w - 2 * corner), height: edge),
            CGRect(x: corner, y: h - edge, width: max(0, w - 2 * corner), height: edge),
            CGRect(x: 0, y: corner, width: edge, height: max(0, h - 2 * corner)),
            CGRect(x: w - edge, y: corner, width: edge, height: max(0, h - 2 * corner))
        ]
    }
}
