import DanteKit
import SwiftUI

/// Dante's mark, the Obelisk D: an obelisk with a gilded tip is the stem and a gold ring is the
/// bowl, 36 decan marks turning inside it, Orion's belt in the middle and a glint running round
/// while agents work. Drawn in the app icon's 1024 grid (scripts/make_icon.swift), cropped to
/// the glyph.
struct DanteLogo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat
    /// The glint runs and the decans turn.
    var turns = true
    /// Flipping this from false to true plays the entrance: the obelisk rises and the ring draws round.
    var drawn = true
    @State private var since = Date.distantPast
    @State private var entering = false

    private static let ring = CGPoint(x: 523, y: 512)
    private static let entrance = 1.6

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
        let still = reduceMotion
        let elapsed = still ? Self.entrance : max(0, date.timeIntervalSince(since))
        let clock = still || !turns ? 0 : date.timeIntervalSinceReferenceDate
        let rise = ease(min(1, elapsed / 0.9))
        let sweep = ease(min(1, max(0, elapsed - 0.25) / 1.1))
        let detail = size >= 48
        let ring = Self.ring

        canvas.scaleBy(x: size / 744, y: size / 744)
        canvas.translateBy(x: -140, y: -140)

        // The warm light the ring sits in.
        canvas.opacity = 0.45 * sweep
        canvas.fill(circle(ring, 320), with: glow(at: ring, radius: 320))
        canvas.opacity = 1

        if detail {
            var decans = Path()
            let turn = -clock / 80 * 2 * .pi
            for index in 0..<36 {
                let angle = Double(index) / 36 * 2 * .pi + turn
                decans.move(to: point(ring, 178, angle))
                decans.addLine(to: point(ring, 198, angle))
            }
            canvas.opacity = sweep
            canvas.stroke(decans, with: .color(LogoColors.decan.color), lineWidth: 5)
            canvas.opacity = 1
        }

        // The ring draws itself round from the top.
        var bowl = Path()
        bowl.addArc(center: ring, radius: 238, startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
        canvas.stroke(bowl.trimmedPath(from: 0, to: sweep), with: gradient(LogoColors.gold, from: CGPoint(x: ring.x - 261, y: ring.y - 261),
                                                                          to: CGPoint(x: ring.x + 261, y: ring.y + 261)),
                      style: StrokeStyle(lineWidth: 46, lineCap: sweep < 1 ? .round : .butt))

        // The glint: still at the lower right, or running round once a turn is under way.
        let start = turns && !still ? clock.truncatingRemainder(dividingBy: 7) / 7 * 2 * .pi : 0.7
        var glint = Path()
        glint.addArc(center: ring, radius: 238, startAngle: .radians(start), endAngle: .radians(start + 0.25), clockwise: false)
        let shine = max(0, min(1, (elapsed - 1.2) / 0.4))
        canvas.drawLayer { layer in
            layer.opacity = 0.9 * shine
            layer.addFilter(.blur(radius: 14))
            layer.stroke(glint, with: .color(LogoColors.glint.color), style: StrokeStyle(lineWidth: 46, lineCap: .round))
        }
        canvas.opacity = 0.9 * shine
        canvas.stroke(glint, with: .color(LogoColors.glint.color), style: StrokeStyle(lineWidth: 30, lineCap: .round))
        canvas.opacity = 1

        if detail {
            for (index, star) in [(483.0, 566.0, 11.0), (521, 524, 9), (563, 484, 11)].enumerated() {
                canvas.opacity = sweep * (0.75 + 0.25 * sin(clock * 1.7 + Double(index) * 2.1))
                canvas.fill(circle(CGPoint(x: star.0, y: star.1), star.2), with: .color(LogoColors.star.color))
            }
            canvas.opacity = 1
        }

        // The obelisk rises into place, its tip catching the light.
        canvas.translateBy(x: 0, y: (1 - rise) * 70)
        canvas.opacity = rise
        let tip = CGPoint(x: 285, y: 262), foot = CGPoint(x: 285, y: 760)
        canvas.fill(circle(tip, 80), with: glow(at: tip, radius: 80))
        canvas.fill(shape([CGPoint(x: 237, y: 760), foot, CGPoint(x: 285, y: 334), CGPoint(x: 251, y: 334)]),
                    with: gradient(LogoColors.gold, from: tip, to: foot))
        canvas.fill(shape([foot, CGPoint(x: 333, y: 760), CGPoint(x: 319, y: 334), CGPoint(x: 285, y: 334)]),
                    with: gradient(LogoColors.shade, from: tip, to: foot))
        canvas.fill(shape([CGPoint(x: 251, y: 334), CGPoint(x: 285, y: 334), tip]), with: .color(LogoColors.tipLit.color))
        canvas.fill(shape([CGPoint(x: 285, y: 334), CGPoint(x: 319, y: 334), tip]), with: .color(LogoColors.tipShade.color))
        if detail {
            var carving = Path()
            for (y, height) in [(392.0, 26.0), (452, 12), (498, 40), (572, 18), (624, 30)] {
                carving.addRoundedRect(in: CGRect(x: 262, y: y, width: 12, height: height), cornerSize: CGSize(width: 3, height: 3))
            }
            canvas.fill(carving, with: .color(LogoColors.carving.color))
        }
    }

    private func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    private func point(_ centre: CGPoint, _ radius: Double, _ angle: Double) -> CGPoint {
        CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
    }

    private func circle(_ centre: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
    }

    private func shape(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    private func gradient(_ stops: [(Double, RGBA)], from start: CGPoint, to end: CGPoint) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: stops.map { Gradient.Stop(color: $0.1.color, location: $0.0) }), startPoint: start, endPoint: end)
    }

    private func glow(at centre: CGPoint, radius: Double) -> GraphicsContext.Shading {
        .radialGradient(Gradient(stops: [.init(color: LogoColors.glow.color.opacity(0.9), location: 0),
                                         .init(color: LogoColors.glowEdge.color.opacity(0.3), location: 0.45),
                                         .init(color: LogoColors.glowEdge.color.opacity(0), location: 1)]),
                        center: centre, startRadius: 0, endRadius: radius)
    }
}
