import SwiftUI

// The companion's motion: the Vine D growing on the splash, fireflies drifting, and cards
// arriving in a quick cascade. Everything settles at once under Reduce Motion.

extension RGBA {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// Dante's mark (`Logo`), as the Mac's `DanteLogo` draws it: the stalk rises, the vine grows
/// round into the bowl and curls, leaves unfold and sway, fireflies blink.
struct VineLogo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat
    /// When it started growing; the entrance takes 2.6 s from here.
    var since: Date

    static let entrance = 2.6

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            Canvas { canvas, _ in draw(in: &canvas, at: context.date) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func draw(in canvas: inout GraphicsContext, at date: Date) {
        let elapsed = reduceMotion ? Self.entrance : max(0, date.timeIntervalSince(since))
        let clock = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
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
            let grows = leaf.along.map { 0.5 + 1.1 * $0 } ?? 0.7
            // A little overshoot as each leaf unfolds.
            let open = spring(min(1, max(0, elapsed - grows) / 0.6))
            guard open > 0 else { continue }
            let sway = -5 * cos(2 * .pi * (clock - leaf.delay) / 4.8)
            var context = canvas
            context.translateBy(x: leaf.x, y: leaf.y)
            context.rotate(by: .degrees(leaf.angle + sway))
            context.scaleBy(x: leaf.size / 120 * open, y: leaf.size / 120 * open)
            context.fill(shape, with: .linearGradient(gradient(leaf.light ? Logo.lightLeaf : Logo.darkLeaf),
                                                      startPoint: CGPoint(x: 0, y: -22), endPoint: CGPoint(x: 120, y: 22)))
            var rib = Path()
            rib.move(to: CGPoint(x: 8, y: 0))
            rib.addLine(to: CGPoint(x: 110, y: 0))
            context.stroke(rib, with: .color(Logo.midrib.color), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
        for fly in Logo.fireflies {
            let lit = min(1, max(0, elapsed - 2 - fly.delay * 0.2) / 0.4)
            let blink = 0.625 - 0.375 * cos(2 * .pi * (clock - fly.delay) / 3.2)
            canvas.opacity = blink * lit
            let centre = CGPoint(x: fly.x, y: fly.y)
            canvas.fill(circle(centre, fly.radius * 1.6), with: .radialGradient(gradient(Logo.firefly), center: centre, startRadius: 0, endRadius: fly.radius * 1.6))
        }
        canvas.opacity = 1
    }

    private func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    private func spring(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        return 1 - exp(-6 * t) * cos(9 * t)
    }

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

/// Warm specks of light drifting upward and blinking, like the logo's fireflies.
struct Fireflies: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var count = 36
    var brightness = 1.0

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            Canvas { canvas, size in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let glow = Gradient(stops: Logo.firefly.map { Gradient.Stop(color: $0.1.color, location: $0.0) })
                for index in 0..<count {
                    // Each fly has its own fixed path from a seeded number.
                    let seed = Double(index) * 12.9898
                    let r1 = fract(sin(seed) * 43758.5453), r2 = fract(sin(seed * 1.7) * 24634.6345), r3 = fract(sin(seed * 2.3) * 12345.678)
                    let speed = 0.012 + r3 * 0.02
                    let y = (1 - fract(r2 + time * speed)) * (size.height + 80) - 40
                    let x = r1 * size.width + sin(time * (0.3 + r3 * 0.4) + seed) * 30
                    let radius = 3 + r3 * 7
                    let blink = 0.35 + 0.65 * pow(0.5 + 0.5 * sin(time * (0.8 + r1 * 1.4) + seed), 3)
                    canvas.opacity = blink * brightness
                    let centre = CGPoint(x: x, y: y)
                    canvas.fill(Path(ellipseIn: CGRect(x: x - radius * 3, y: y - radius * 3, width: radius * 6, height: radius * 6)),
                                with: .radialGradient(glow, center: centre, startRadius: 0, endRadius: radius * 3))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func fract(_ x: Double) -> Double { x - floor(x) }
}

/// The launch: forest night, fireflies, the Vine D growing, the name, then the connection.
/// It hands over once the Mac answers (or after a few seconds without it) by blooming out.
struct SplashView: View {
    let connection: CompanionConnection
    let done: () -> Void
    @State private var since = Date.now
    @State private var nameShown = false
    @State private var leaving = false

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                LinearGradient(colors: Logo.forest.map(\.color), startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Logo.tileLight.color, .clear], center: .init(x: 0.5, y: 0.42), startRadius: 0, endRadius: side * 0.7)
                Fireflies(count: 44)
                VStack(spacing: side * 0.03) {
                    VineLogo(size: side * 0.42, since: since)
                        .scaleEffect(leaving ? 1.6 : 1)
                        .blur(radius: leaving ? 12 : 0)
                    HStack(spacing: 0) {
                        ForEach(Array("Dante".enumerated()), id: \.offset) { index, letter in
                            Text(String(letter))
                                .opacity(nameShown ? 1 : 0)
                                .offset(y: nameShown ? 0 : 14)
                                .blur(radius: nameShown ? 0 : 6)
                                .animation(.spring(duration: 0.7, bounce: 0.35).delay(Double(index) * 0.07), value: nameShown)
                        }
                    }
                    .font(.system(size: side * 0.075, weight: .semibold, design: .rounded))
                    .tracking(side * 0.004)
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.92, green: 1, blue: 0.75), Color(red: 0.56, green: 0.83, blue: 0.35)],
                                                    startPoint: .top, endPoint: .bottom))
                    Text(status).font(.headline).foregroundStyle(.white.opacity(nameShown ? 0.6 : 0))
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.4), value: status)
                }
                .opacity(leaving ? 0 : 1)
            }
            .ignoresSafeArea()
        }
        .opacity(leaving ? 0 : 1)
        .task {
            try? await Task.sleep(for: .seconds(1.6))
            nameShown = true
            // At least the whole entrance; then as soon as the Mac answers, or after 5 s.
            try? await Task.sleep(for: .seconds(1.2))
            let started = Date.now
            while connection.status != .connected, connection.pairing != nil, Date.now.timeIntervalSince(started) < 2.2 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            withAnimation(.easeIn(duration: 0.55)) { leaving = true }
            try? await Task.sleep(for: .seconds(0.55))
            done()
        }
        .statusBarHidden()
    }

    private var status: String {
        guard let pairing = connection.pairing else { return "Your Mac, in your hand" }
        return connection.status == .connected ? "Connected to \(pairing.name)" : "Finding \(pairing.name)…"
    }
}

/// Cards and rows arrive in a cascade: up, into focus, a hair larger to their size.
struct Arrive: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 22)
            .scaleEffect(shown ? 1 : 0.97, anchor: .top)
            .blur(radius: shown ? 0 : 5)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true; return }
                withAnimation(.spring(duration: 0.6, bounce: 0.22).delay(min(Double(index), 10) * 0.055)) { shown = true }
            }
    }
}

extension View {
    func arrive(_ index: Int = 0) -> some View { modifier(Arrive(index: index)) }
}

/// A status dot that sends out a ring while something is under way or wrong.
struct PulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    var size: CGFloat = 10
    var pulsing = true
    @State private var out = false

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background {
                if pulsing, !reduceMotion {
                    Circle().stroke(color, lineWidth: 2)
                        .scaleEffect(out ? 2.6 : 1)
                        .opacity(out ? 0 : 0.7)
                        .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { out = true } }
                }
            }
    }
}
