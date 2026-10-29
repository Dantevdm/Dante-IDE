import DanteKit
import SwiftUI

/// The window's ground in the chosen theme: flat colour, or for Vine, Tide, Dusk and Aurora a
/// slow scene (as on the companion) behind the pages, which then leave their own ground clear
/// (`Theme.pageGround`). Cards, panels and the editor stay opaque, so text reads as before.
/// It draws about 15 times a second, only while the window is key and Reduce Motion is off,
/// and cross-fades when the theme changes.
struct ThemeBackdrop: View {
    let theme: Theme
    /// The Settings gallery's tiles draw fewer specks.
    var small = false

    var body: some View {
        ZStack {
            theme.ground.color
            if theme.id.scene != .none {
                SceneCanvas(theme: theme, small: small).id(theme.id).transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension Theme {
    /// A page's own background: clear when a scene moves behind it.
    var pageGround: Color { id.scene == .none ? ground.color : .clear }
}

private struct SceneCanvas: View {
    let theme: Theme
    let small: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var active

    var body: some View {
        let still = reduceMotion || active == .inactive
        TimelineView(.animation(minimumInterval: 1 / 15, paused: still)) { context in
            let time = still ? 40 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)
            Canvas { canvas, size in
                switch theme.id.scene {
                case .vine: vine(&canvas, size, time)
                case .tide: tide(&canvas, size, time)
                case .dusk: dusk(&canvas, size, time)
                case .aurora: aurora(&canvas, size, time)
                case .none: break
                }
            }
        }
        .drawingGroup()
    }

    private var night: Bool { theme.isDark }

    private func wash(_ canvas: inout GraphicsContext, _ size: CGSize, _ colors: [Color]) {
        canvas.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }

    /// A soft round light; a radial gradient rather than a blur, which a full window can't afford.
    private func glow(_ canvas: inout GraphicsContext, at centre: CGPoint, radius: CGFloat, _ color: Color, _ strength: Double) {
        canvas.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(Gradient(colors: [color.opacity(strength), color.opacity(strength * 0.4), color.opacity(0)]),
                                          center: centre, startRadius: 0, endRadius: radius))
    }

    // MARK: Scenes

    /// The forest: green light drifting and fireflies.
    private func vine(_ canvas: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        wash(&canvas, size, [theme.ground.color, theme.accentTint.color])
        let w = size.width, h = size.height
        glow(&canvas, at: CGPoint(x: w * (0.22 + 0.12 * sin(t / 23)), y: h * (0.25 + 0.1 * cos(t / 29))), radius: max(w, h) * 0.5,
             theme.accent.color, night ? 0.24 : 0.14)
        glow(&canvas, at: CGPoint(x: w * (0.8 + 0.08 * cos(t / 31)), y: h * (0.75 + 0.1 * sin(t / 19))), radius: max(w, h) * 0.38,
             Color(red: 0.95, green: 0.82, blue: 0.4), night ? 0.14 : 0.18)
        motes(&canvas, size, t, count: small ? 8 : 30, color: Color(red: 1, green: 0.86, blue: 0.42), rising: true, ring: false,
              brightness: night ? 0.85 : 0.5, scale: 1.4)
    }

    /// Deep water: waves rolling along the bottom and bubbles rising.
    private func tide(_ canvas: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        wash(&canvas, size, [theme.ground.color, theme.accentTint.color])
        for layer in 0..<4 {
            let depth = Double(layer)
            var wave = Path()
            let base = size.height * (0.62 + 0.09 * depth)
            let amplitude = size.height * (0.025 + 0.008 * depth)
            let length = size.width * (0.7 + 0.25 * depth)
            let phase = t * (0.35 + 0.12 * depth) + depth * 1.7
            wave.move(to: CGPoint(x: 0, y: size.height))
            for x in stride(from: 0, through: size.width + 8, by: 8) {
                let y = base + amplitude * sin(2 * .pi * x / length + phase) + amplitude * 0.4 * sin(2 * .pi * x / (length * 0.37) - phase * 1.3)
                wave.addLine(to: CGPoint(x: x, y: y))
            }
            wave.addLine(to: CGPoint(x: size.width + 8, y: size.height))
            wave.closeSubpath()
            canvas.fill(wave, with: .color(theme.accent.color.opacity((night ? 0.1 : 0.07) + 0.03 * depth)))
        }
        motes(&canvas, size, t, count: small ? 6 : 24, color: theme.accent.color, rising: true, ring: true, brightness: night ? 0.6 : 0.4)
    }

    /// A low sun breathing behind the page and embers floating up.
    private func dusk(_ canvas: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        wash(&canvas, size, [theme.ground.color, theme.accentTint.color, theme.accent.color.opacity(night ? 0.35 : 0.22)])
        let radius = size.width * 0.36 * (1 + 0.04 * sin(t / 3))
        let centre = CGPoint(x: size.width * (0.7 + 0.03 * sin(t / 40)), y: size.height * (0.92 - 0.03 * sin(t / 27)))
        canvas.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.78, blue: 0.45).opacity(night ? 0.55 : 0.45),
                                                            theme.accent.color.opacity(night ? 0.3 : 0.22), .clear]),
                                          center: centre, startRadius: 0, endRadius: radius))
        motes(&canvas, size, t, count: small ? 7 : 26, color: Color(red: 1, green: 0.55, blue: 0.25), rising: true, ring: false,
              brightness: night ? 0.9 : 0.6)
    }

    /// Curtains of light rippling across the top, with stars at night.
    private static let bands: [(Color, Double, Double)] = [
        (Color(red: 0.25, green: 0.95, blue: 0.65), 0.2, 0),
        (Color(red: 0.45, green: 0.45, blue: 1), 0.3, 2.1),
        (Color(red: 0.85, green: 0.4, blue: 0.95), 0.12, 4.3),
    ]

    private func aurora(_ canvas: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        wash(&canvas, size, [theme.accentTint.color, theme.ground.color])
        if night { motes(&canvas, size, t, count: small ? 14 : 70, color: .white, rising: false, ring: false, brightness: 0.7, scale: 0.35) }
        var layer = canvas
        layer.addFilter(.blur(radius: small ? 8 : 24))
        layer.opacity = night ? 0.85 : 0.5
        for (colour, height, offset) in Self.bands {
            let thickness = size.height * 0.18
            var top: [CGPoint] = []
            for x in stride(from: -20, through: size.width + 20, by: 12) {
                let y = size.height * height + size.height * 0.06 * sin(x / size.width * 5 + t * 0.25 + offset)
                    + size.height * 0.025 * sin(x / size.width * 13 - t * 0.4 + offset)
                top.append(CGPoint(x: x, y: y))
            }
            var band = Path()
            band.move(to: top[0])
            for point in top.dropFirst() { band.addLine(to: point) }
            for point in top.reversed() {
                band.addLine(to: CGPoint(x: point.x, y: point.y + thickness * (0.7 + 0.3 * sin(point.x / 90 + t * 0.3 + offset))))
            }
            band.closeSubpath()
            layer.fill(band, with: .linearGradient(Gradient(colors: [colour.opacity(0), colour.opacity(0.55), colour.opacity(0)]),
                                                   startPoint: CGPoint(x: 0, y: size.height * height - thickness * 0.2),
                                                   endPoint: CGPoint(x: 0, y: size.height * height + thickness * 1.1)))
        }
    }

    /// Specks of light: rising embers, bubbles or fireflies, or still twinkling stars.
    private func motes(_ canvas: inout GraphicsContext, _ area: CGSize, _ time: Double, count: Int, color: Color,
                       rising: Bool, ring: Bool, brightness: Double, scale: Double = 1) {
        for index in 0..<count {
            let seed = Double(index) * 12.9898
            let r1 = fract(sin(seed) * 43758.5453), r2 = fract(sin(seed * 1.7) * 24634.6345), r3 = fract(sin(seed * 2.3) * 12345.678)
            let y = rising ? (1 - fract(r2 + time * (0.012 + r3 * 0.02))) * (area.height + 60) - 30 : r2 * area.height
            let x = r1 * area.width + (rising ? sin(time * (0.4 + r3 * 0.5) + seed) * 24 : 0)
            let radius = (1.5 + r3 * 4) * scale
            let blink = 0.3 + 0.7 * pow(0.5 + 0.5 * sin(time * (0.7 + r1 * 1.6) + seed), 2)
            var speck = canvas
            speck.opacity = blink * brightness
            if ring {
                speck.stroke(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(color), lineWidth: 1.2)
            } else {
                speck.fill(Path(ellipseIn: CGRect(x: x - radius * 3, y: y - radius * 3, width: radius * 6, height: radius * 6)),
                           with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: CGPoint(x: x, y: y),
                                                 startRadius: 0, endRadius: radius * 3))
            }
        }
    }

    private func fract(_ x: Double) -> Double { x - floor(x) }
}
