import SwiftUI

/// The ground behind every page, in the chosen look: flat colour for the plain ones, a slow
/// living scene for the rest. It fades across when the look changes.
struct LookBackdrop: View {
    /// A particular look (the settings' previews); the chosen one otherwise.
    var look: Look?
    /// Previews are small, so their scenes are drawn smaller.
    var scale: CGFloat = 1

    var body: some View {
        let shown = look ?? Looks.shared.look
        ZStack {
            scene(shown).id(shown).transition(.opacity)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func scene(_ look: Look) -> some View {
        let colors = look.colors
        switch look {
        case .classic, .paper, .graphite: colors.background
        case .vine: VineScene(colors: colors, scale: scale)
        case .tide: TideScene(colors: colors, scale: scale)
        case .dusk: DuskScene(colors: colors, scale: scale)
        case .aurora: AuroraScene(colors: colors, scale: scale)
        }
    }
}

/// The forest: green light drifting and fireflies.
private struct VineScene: View {
    let colors: LookColors
    let scale: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Drift { t, size in
            ZStack {
                LinearGradient(colors: [colors.background, colors.accentTint], startPoint: .top, endPoint: .bottom)
                Circle().fill(colors.accent.opacity(scheme == .dark ? 0.22 : 0.14)).frame(width: size.width * 0.8).blur(radius: 90 * scale)
                    .position(x: size.width * (0.22 + 0.12 * sin(t / 23)), y: size.height * (0.25 + 0.1 * cos(t / 29)))
                Circle().fill(Color(red: 0.95, green: 0.82, blue: 0.4).opacity(scheme == .dark ? 0.12 : 0.16)).frame(width: size.width * 0.55)
                    .blur(radius: 100 * scale)
                    .position(x: size.width * (0.8 + 0.08 * cos(t / 31)), y: size.height * (0.75 + 0.1 * sin(t / 19)))
            }
        } overlay: {
            Fireflies(count: scale < 1 ? 8 : 26, brightness: scheme == .dark ? 0.8 : 0.45)
        }
    }
}

/// Deep water: layered waves rolling along the bottom and bubbles rising.
private struct TideScene: View {
    let colors: LookColors
    let scale: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Drift { t, size in
            ZStack {
                LinearGradient(colors: [colors.background, colors.accentTint], startPoint: .top, endPoint: .bottom)
                Canvas { canvas, size in
                    for layer in 0..<4 {
                        let depth = Double(layer)
                        var wave = Path()
                        let base = size.height * (0.62 + 0.09 * depth)
                        let amplitude = size.height * (0.025 + 0.008 * depth)
                        let length = size.width * (0.7 + 0.25 * depth)
                        wave.move(to: CGPoint(x: 0, y: size.height))
                        for x in stride(from: 0, through: size.width, by: 6) {
                            let phase = t * (0.35 + 0.12 * depth) + depth * 1.7
                            let y = base + amplitude * sin(2 * .pi * x / length + phase) + amplitude * 0.4 * sin(2 * .pi * x / (length * 0.37) - phase * 1.3)
                            wave.addLine(to: CGPoint(x: x, y: y))
                        }
                        wave.addLine(to: CGPoint(x: size.width, y: size.height))
                        wave.closeSubpath()
                        canvas.fill(wave, with: .color(colors.accent.opacity((scheme == .dark ? 0.1 : 0.07) + 0.03 * depth)))
                    }
                }
            }
        } overlay: {
            Motes(count: scale < 1 ? 6 : 22, color: colors.accent, rising: true, ring: true, brightness: scheme == .dark ? 0.6 : 0.4)
        }
    }
}

/// A low sun breathing behind the page and embers floating up.
private struct DuskScene: View {
    let colors: LookColors
    let scale: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Drift { t, size in
            ZStack {
                LinearGradient(colors: [colors.background, colors.accentTint, colors.accent.opacity(scheme == .dark ? 0.35 : 0.22)],
                               startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.78, blue: 0.45), colors.accent.opacity(0.6), .clear],
                                         center: .center, startRadius: 0, endRadius: size.width * 0.35))
                    .frame(width: size.width * 0.7, height: size.width * 0.7)
                    .scaleEffect(1 + 0.04 * sin(t / 3))
                    .opacity(scheme == .dark ? 0.55 : 0.4)
                    .blur(radius: 30 * scale)
                    .position(x: size.width * (0.7 + 0.03 * sin(t / 40)), y: size.height * (0.92 - 0.03 * sin(t / 27)))
            }
        } overlay: {
            Motes(count: scale < 1 ? 7 : 24, color: Color(red: 1, green: 0.55, blue: 0.25), rising: true, ring: false, brightness: scheme == .dark ? 0.9 : 0.6)
        }
    }
}

/// Curtains of light rippling across the top, with stars at night.
private struct AuroraScene: View {
    let colors: LookColors
    let scale: CGFloat
    @Environment(\.colorScheme) private var scheme

    private static let bands: [(Color, Double, Double)] = [
        (Color(red: 0.25, green: 0.95, blue: 0.65), 0.28, 0),
        (Color(red: 0.45, green: 0.45, blue: 1), 0.38, 2.1),
        (Color(red: 0.85, green: 0.4, blue: 0.95), 0.2, 4.3),
    ]

    var body: some View {
        Drift { t, size in
            ZStack {
                LinearGradient(colors: [colors.accentTint, colors.background], startPoint: .top, endPoint: .bottom)
                Canvas { canvas, size in
                    for (colour, height, offset) in Self.bands {
                        var band = Path()
                        let thickness = size.height * 0.16
                        var top: [CGPoint] = []
                        for x in stride(from: -20, through: size.width + 20, by: 8) {
                            let y = size.height * height + size.height * 0.06 * sin(x / size.width * 5 + t * 0.25 + offset)
                                + size.height * 0.025 * sin(x / size.width * 13 - t * 0.4 + offset)
                            top.append(CGPoint(x: x, y: y))
                        }
                        band.move(to: top[0])
                        for point in top.dropFirst() { band.addLine(to: point) }
                        for point in top.reversed() {
                            band.addLine(to: CGPoint(x: point.x, y: point.y + thickness * (0.7 + 0.3 * sin(point.x / 90 + t * 0.3 + offset))))
                        }
                        band.closeSubpath()
                        canvas.fill(band, with: .linearGradient(Gradient(colors: [colour.opacity(0), colour.opacity(0.55), colour.opacity(0)]),
                                                                startPoint: CGPoint(x: 0, y: size.height * height - thickness * 0.2),
                                                                endPoint: CGPoint(x: 0, y: size.height * height + thickness * 1.1)))
                    }
                }
                .blur(radius: 28 * scale)
                .opacity(scheme == .dark ? 0.9 : 0.5)
            }
        } overlay: {
            if scheme == .dark { Motes(count: scale < 1 ? 14 : 60, color: .white, rising: false, ring: false, brightness: 0.7, size: 0.35) }
        }
    }
}

/// A full-size scene redrawn about 24 times a second, standing still under Reduce Motion.
private struct Drift<Scene: View, Overlay: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder let scene: (Double, CGSize) -> Scene
    @ViewBuilder let overlay: () -> Overlay

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { context in
                scene(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000), geometry.size)
            }
            .drawingGroup()
            overlay()
        }
    }
}

/// Specks of light: rising embers and bubbles, or still twinkling stars.
struct Motes: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var count: Int
    var color: Color
    var rising = true
    var ring = false
    var brightness = 1.0
    var size = 1.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { context in
            Canvas { canvas, area in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)
                for index in 0..<count {
                    let seed = Double(index) * 12.9898
                    let r1 = fract(sin(seed) * 43758.5453), r2 = fract(sin(seed * 1.7) * 24634.6345), r3 = fract(sin(seed * 2.3) * 12345.678)
                    let y = rising ? (1 - fract(r2 + time * (0.015 + r3 * 0.025))) * (area.height + 60) - 30 : r2 * area.height
                    let x = r1 * area.width + (rising ? sin(time * (0.4 + r3 * 0.5) + seed) * 24 : 0)
                    let radius = (1.5 + r3 * 4) * size
                    let blink = 0.3 + 0.7 * pow(0.5 + 0.5 * sin(time * (0.7 + r1 * 1.6) + seed), 2)
                    canvas.opacity = blink * brightness
                    let dot = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    if ring {
                        canvas.stroke(dot, with: .color(color), lineWidth: 1.2)
                    } else {
                        let glow = Path(ellipseIn: CGRect(x: x - radius * 3, y: y - radius * 3, width: radius * 6, height: radius * 6))
                        canvas.fill(glow, with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: CGPoint(x: x, y: y),
                                                               startRadius: 0, endRadius: radius * 3))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func fract(_ x: Double) -> Double { x - floor(x) }
}

/// The new look sweeps in: a ring of its accent opens from the middle and fades.
struct LookWash: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opening = false
    @State private var visible = false

    func body(content: Content) -> some View {
        let looks = Looks.shared
        content
            .fontDesign(looks.look.font)
            .preferredColorScheme(looks.appearance.scheme)
            .overlay {
                if visible {
                    GeometryReader { geometry in
                        let reach = hypot(geometry.size.width, geometry.size.height)
                        Circle()
                            .strokeBorder(Palette.accent.opacity(0.5), lineWidth: 60)
                            .background(Circle().fill(Palette.accentTint.opacity(0.35)))
                            .frame(width: reach, height: reach)
                            .scaleEffect(opening ? 1.15 : 0.02)
                            .opacity(opening ? 0 : 1)
                            .blur(radius: 20)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: looks.changes) {
                guard !reduceMotion else { return }
                opening = false
                visible = true
                withAnimation(.easeOut(duration: 0.9)) { opening = true } completion: { visible = false }
            }
    }
}

extension View {
    /// The chosen look's font, light or dark, and its entrance.
    func styledByLook() -> some View { modifier(LookWash()) }

    /// The page's ground in the chosen look.
    func lookBackground() -> some View { background { LookBackdrop().ignoresSafeArea() } }
}

/// Style and settings: the looks as live tiles, light or dark, and mobile data.
struct StyleSettings: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var looks = Looks.shared
    @Bindable private var saver = DataSaver.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    section("Style", "Every page takes it on, here and on the Wall.") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                            ForEach(Array(Look.allCases.enumerated()), id: \.element) { index, look in
                                Button { looks.choose(look) } label: { LookTile(look: look, chosen: looks.look == look) }
                                    .buttonStyle(Pressable())
                                    .arrive(index)
                            }
                        }
                    }
                    section("Light or dark", nil) {
                        Picker("Appearance", selection: $looks.appearance.animation(.easeInOut(duration: 0.6))) {
                            ForEach(Looks.Appearance.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    section("Mobile data", saver.onMobileData
                            ? "You’re on mobile data now. \(saver.usedText) used since opening."
                            : "On Wi‑Fi now. \(saver.usedOnMobile > 0 ? "\(saver.usedText) used on mobile data since opening." : "")") {
                        Picker("On mobile data", selection: $saver.policy) {
                            ForEach(DataSaver.Policy.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text("Asking first holds back the Mac’s live screen, pictures not kept here yet and the Mac’s natural voice (this device’s voice speaks instead), and refreshes pages every five minutes.")
                            .font(.footnote).foregroundStyle(Palette.text3)
                    }
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .lookBackground()
            .navigationTitle("Style and settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .styledByLook()
    }

    private func section<Content: View>(_ title: String, _ note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Palette.text)
            if let note, !note.isEmpty { Text(note).font(.subheadline).foregroundStyle(Palette.text2) }
            content()
        }
    }
}

/// A look as a little live page: its scene, a card with a number and a bar, and its name.
private struct LookTile: View {
    let look: Look
    let chosen: Bool

    var body: some View {
        let colors = look.colors
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LookBackdrop(look: look, scale: 0.4)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(colors.green).frame(width: 7, height: 7)
                        Text("Tests").font(.caption.weight(.medium)).foregroundStyle(colors.text3)
                        Spacer()
                    }
                    Text("212 passed").font(.headline).foregroundStyle(colors.text)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(colors.line)
                            RoundedRectangle(cornerRadius: 3).fill(colors.accent).frame(width: geometry.size.width * 0.72)
                        }
                    }
                    .frame(height: 5)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(colors.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(colors.line))
                .padding(18)
            }
            .frame(height: 140)
            .fontDesign(look.font)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(look.title).font(.headline).foregroundStyle(Palette.text)
                        Text(look.isPlain ? "Plain" : "Moving").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Palette.accentTint))
                            .foregroundStyle(Palette.text2)
                    }
                    Text(look.tagline).font(.caption).foregroundStyle(Palette.text3).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(chosen ? Palette.accent : Palette.text3)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(chosen ? Palette.accent : Palette.line, lineWidth: chosen ? 2.5 : 1))
        .scaleEffect(chosen ? 1.0 : 0.98)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: chosen)
    }
}
