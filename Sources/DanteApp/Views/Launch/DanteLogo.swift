import DanteKit
import SwiftUI

/// Dante's mark, the Vine D (`Logo`): a stalk rises, a vine grows from its tip round into the
/// bowl and curls into a tendril, leaves unfold along it and sway, and fireflies blink inside.
/// Drawn in the app icon's 1024 grid, cropped to the glyph.
struct DanteLogo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat
    /// The leaves sway and the fireflies blink.
    var turns = true
    /// Flipping this from false to true plays the entrance: the stalk and vine grow, the leaves unfold.
    var drawn = true
    @State private var since = Date.distantPast
    @State private var entering = false

    private static let entrance = 2.6

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !turns && !entering)) { context in
            Canvas { canvas, _ in
                draw(in: &canvas, at: context.date)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: drawn, initial: true) { _, drawn in
            since = drawn ? .now : .distantFuture
        }
        .task(id: since) {
            entering = true
            try? await Task.sleep(for: .seconds(Self.entrance))
            if !Task.isCancelled { entering = false }
        }
        .accessibilityHidden(true)
    }

    private func draw(in canvas: inout GraphicsContext, at date: Date) {
        let elapsed = reduceMotion ? Self.entrance : max(0, date.timeIntervalSince(since))
        let clock = reduceMotion || !turns ? 0 : date.timeIntervalSinceReferenceDate
        let stalkGrown = ease(min(1, elapsed / 0.8))
        let vineGrown = ease(min(1, max(0, elapsed - 0.5) / 1.1))
        let tendrilGrown = ease(min(1, max(0, elapsed - 1.5) / 0.5))

        canvas.scaleBy(x: size / 744, y: size / 744)
        canvas.translateBy(x: -140, y: -140)

        canvas.opacity = vineGrown
        canvas.fill(circle(Logo.glowCentre, Logo.glowRadius),
                    with: .radialGradient(gradient(Logo.sunlight), center: Logo.glowCentre, startRadius: 0, endRadius: Logo.glowRadius))
        canvas.opacity = 1

        canvas.stroke(path([Logo.stalk]).trimmedPath(from: 0, to: stalkGrown),
                      with: .linearGradient(gradient(Logo.stalkColours), startPoint: CGPoint(x: 0, y: 250), endPoint: CGPoint(x: 0, y: 810)),
                      style: StrokeStyle(lineWidth: Logo.stalkWidth, lineCap: .round))
        let bounds = Logo.vineBounds
        canvas.stroke(path(Logo.vine).trimmedPath(from: 0, to: vineGrown),
                      with: .linearGradient(gradient(Logo.vineColours), startPoint: bounds.origin, endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)),
                      style: StrokeStyle(lineWidth: Logo.vineWidth, lineCap: .round))
        if tendrilGrown > 0 {
            canvas.stroke(path(Logo.tendril).trimmedPath(from: 0, to: tendrilGrown), with: .color(Logo.tendrilColour.color),
                          style: StrokeStyle(lineWidth: Logo.tendrilWidth, lineCap: .round))
        }

        let shape = path(Logo.leafShape)
        for leaf in Logo.leaves {
            // A leaf unfolds once the vine has grown past it (the tip's once the stalk is up).
            let grows = leaf.along.map { 0.5 + 1.1 * $0 } ?? 0.7
            let open = ease(min(1, max(0, elapsed - grows) / 0.5))
            guard open > 0 else { continue }
            let sway = -5 * cos(2 * .pi * (clock - leaf.delay) / 4.8)
            var context = canvas
            context.translateBy(x: leaf.x, y: leaf.y)
            context.rotate(by: .degrees(leaf.angle + (turns ? sway : 0)))
            context.scaleBy(x: leaf.size / 120 * open, y: leaf.size / 120 * open)
            context.fill(shape, with: .linearGradient(gradient(leaf.light ? Logo.lightLeaf : Logo.darkLeaf),
                                                      startPoint: CGPoint(x: 0, y: -22), endPoint: CGPoint(x: 120, y: 22)))
            var rib = Path()
            rib.move(to: CGPoint(x: 8, y: 0))
            rib.addLine(to: CGPoint(x: 110, y: 0))
            context.stroke(rib, with: .color(Logo.midrib.color), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }

        // Fireflies: steady at rest, blinking while agents work.
        guard size >= 48 else { return }
        for fly in Logo.fireflies {
            let blink = turns && !reduceMotion ? 0.625 - 0.375 * cos(2 * .pi * (clock - fly.delay) / 3.2) : 0.7
            canvas.opacity = blink * vineGrown
            let centre = CGPoint(x: fly.x, y: fly.y)
            canvas.fill(circle(centre, fly.radius), with: .radialGradient(gradient(Logo.firefly), center: centre, startRadius: 0, endRadius: fly.radius))
        }
        canvas.opacity = 1
    }

    private func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    private func circle(_ centre: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }

    private func path(_ curves: [Logo.Curve]) -> Path {
        var path = Path()
        path.move(to: curves[0].start)
        for curve in curves { path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2) }
        return path
    }

    private func gradient(_ stops: [(Double, RGBA)]) -> Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: $0.1.color, location: $0.0) })
    }
}
