import SwiftUI

/// The scenes behind the splash and the screensaver. Each draws itself from nothing: the
/// garden grows, roads are laid and traffic starts, the city rises floor by floor, the
/// lighthouse is built, constellations join up, dunes rise and a caravan crosses, a circuit
/// board is traced out and lights up. `build` is how long that takes (a few seconds for the
/// splash, ten minutes for the screensaver); after it the scene keeps living. Every scene
/// follows the real time of day: light by day, glowing at dusk and night.
enum Dream: String, CaseIterable, Identifiable, Sendable {
    case garden, transit, city, harbour, stars, dunes, circuit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .garden: "Garden"
        case .transit: "Transit"
        case .city: "City"
        case .harbour: "Harbour"
        case .stars: "Stars"
        case .dunes: "Dunes"
        case .circuit: "Circuit"
        }
    }

    var tagline: String {
        switch self {
        case .garden: "Vines climb, leaves open and flowers bloom"
        case .transit: "Roads are laid, then cars and trains stream along them"
        case .city: "A skyline rises floor by floor and the windows light up"
        case .harbour: "A lighthouse is built and its beam sweeps the water"
        case .stars: "Stars come out and join into constellations"
        case .dunes: "Dunes rise and shift, and a caravan crosses"
        case .circuit: "A board is traced out and pulses run along it"
        }
    }
}

/// A scene, drawn about 30 times a second. `start` is when it began building.
struct DreamCanvas: View {
    let dream: Dream
    var start: Date = .now
    var build: Double = 600
    /// 0 for day, 1 for night; nil follows the clock.
    var night: Double?
    /// Fewer specks for small previews.
    var small = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            Canvas { canvas, size in
                let elapsed = max(0, context.date.timeIntervalSince(start))
                let growth = reduceMotion ? 1 : min(1, elapsed / max(build, 0.1))
                let scene = Scene(size: size, growth: growth, time: reduceMotion ? 0 : elapsed, night: night ?? DreamSky.forced ?? DreamSky.night(at: context.date), small: small)
                switch dream {
                case .garden: scene.garden(&canvas)
                case .transit: scene.transit(&canvas)
                case .city: scene.city(&canvas)
                case .harbour: scene.harbour(&canvas)
                case .stars: scene.stars(&canvas)
                case .dunes: scene.dunes(&canvas)
                case .circuit: scene.circuit(&canvas)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// How dark it is outside: 0 from 07:00 to 17:00, 1 from 19:30 to 05:00, easing between.
enum DreamSky {
    /// `DANTE_NIGHT=0` or `1` fixes the time of day, for checking scenes (DEBUG only).
    static let forced: Double? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["DANTE_NIGHT"].flatMap(Double.init)
        #else
        nil
        #endif
    }()

    static func night(at date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60
        if hour >= 7, hour <= 17 { return 0 }
        if hour >= 19.5 || hour <= 5 { return 1 }
        if hour > 17 { return smooth((hour - 17) / 2.5) }
        return 1 - smooth((hour - 5) / 2)
    }

    static func smooth(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        return v * v * (3 - 2 * v)
    }
}

/// A colour that mixes with another, for day and night.
private struct Tone {
    var r, g, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { (self.r, self.g, self.b) = (r, g, b) }
    func mix(_ other: Tone, _ amount: Double) -> Tone {
        Tone(r + (other.r - r) * amount, g + (other.g - g) * amount, b + (other.b - b) * amount)
    }
    func color(_ opacity: Double = 1) -> Color { Color(red: r, green: g, blue: b, opacity: opacity) }
}

/// The same numbers every time for the same seed, so a scene is stable from frame to frame.
private struct Seeded {
    var state: UInt64
    init(_ seed: Int) { state = UInt64(bitPattern: Int64(seed)) &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    mutating func between(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
}

private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
private func fract(_ x: Double) -> Double { x - floor(x) }
private func ease(_ x: Double) -> Double { DreamSky.smooth(x) }
/// How far along a piece is whose turn runs from `from` to `to` of the whole build.
private func stage(_ growth: Double, _ from: Double, _ to: Double) -> Double { clamp((growth - from) / max(to - from, 0.001)) }

private struct Scene {
    let size: CGSize
    let growth: Double
    let time: Double
    let night: Double
    let small: Bool

    var w: Double { size.width }
    var h: Double { size.height }
    var unit: Double { min(w, h) / 800 }

    // MARK: Shared pieces

    func sky(_ canvas: inout GraphicsContext, day: (Tone, Tone), dark: (Tone, Tone)) {
        let top = day.0.mix(dark.0, night), bottom = day.1.mix(dark.1, night)
        canvas.fill(Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(Gradient(colors: [top.color(), bottom.color()]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
    }

    func glow(_ canvas: inout GraphicsContext, _ centre: CGPoint, _ radius: Double, _ tone: Tone, _ strength: Double) {
        guard strength > 0.001 else { return }
        canvas.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(Gradient(colors: [tone.color(strength), tone.color(strength * 0.35), tone.color(0)]),
                                          center: centre, startRadius: 0, endRadius: radius))
    }

    /// The sun by day and the moon by night, on a slow arc.
    func sunAndMoon(_ canvas: inout GraphicsContext, height: Double) {
        let arc = fract(time / 1_800)
        let x = w * (0.15 + 0.7 * arc), y = h * height - sin(arc * .pi) * h * 0.12
        let centre = CGPoint(x: x, y: y)
        glow(&canvas, centre, 140 * unit, Tone(1, 0.86, 0.55), 0.5 * (1 - night))
        canvas.fill(Path(ellipseIn: CGRect(x: x - 28 * unit, y: y - 28 * unit, width: 56 * unit, height: 56 * unit)), with: .color(Tone(1, 0.93, 0.7).color(1 - night)))
        glow(&canvas, centre, 90 * unit, Tone(0.85, 0.9, 1), 0.35 * night)
        canvas.fill(Path(ellipseIn: CGRect(x: x - 20 * unit, y: y - 20 * unit, width: 40 * unit, height: 40 * unit)), with: .color(Tone(0.95, 0.96, 1).color(night)))
    }

    /// Twinkling stars, only at night.
    func starfield(_ canvas: inout GraphicsContext, count: Int, below: Double, seed: Int, strength: Double) {
        guard strength > 0.01 else { return }
        var random = Seeded(seed)
        for index in 0..<(small ? count / 3 : count) {
            let x = random.next() * w, y = random.next() * h * below
            let radius = (0.6 + random.next() * 1.6) * max(unit, 0.5)
            let twinkle = 0.45 + 0.55 * pow(0.5 + 0.5 * sin(time * (0.5 + random.next()) + Double(index)), 2)
            canvas.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(.white.opacity(twinkle * strength)))
        }
    }

    /// Specks drifting: fireflies, pollen, sand or embers.
    func motes(_ canvas: inout GraphicsContext, count: Int, tone: Tone, strength: Double, seed: Int, rising: Bool = true, sideways: Double = 0, size: Double = 1) {
        guard strength > 0.01 else { return }
        var random = Seeded(seed)
        for index in 0..<(small ? max(count / 3, 3) : count) {
            let r1 = random.next(), r2 = random.next(), r3 = random.next()
            let drift = time * (0.01 + r3 * 0.02)
            var x = r1 * w + sin(time * (0.3 + r3 * 0.4) + Double(index)) * 30 * unit
            var y = r2 * h
            if rising { y = (1 - fract(r2 + drift)) * (h + 40) - 20 }
            if sideways != 0 { x = fract(r1 + drift * sideways) * (w + 40) - 20 }
            let radius = (2 + r3 * 5) * unit * size
            let blink = 0.3 + 0.7 * pow(0.5 + 0.5 * sin(time * (0.8 + r1 * 1.4) + Double(index)), 3)
            glow(&canvas, CGPoint(x: x, y: y), radius * 3, tone, blink * strength)
        }
    }

    // MARK: Garden

    func garden(_ canvas: inout GraphicsContext) {
        sky(&canvas, day: (Tone(0.84, 0.93, 0.86), Tone(0.97, 0.96, 0.88)), dark: (Tone(0.03, 0.09, 0.05), Tone(0.08, 0.17, 0.09)))
        glow(&canvas, CGPoint(x: w * 0.5, y: h * 1.05), max(w, h) * 0.7, Tone(0.55, 0.8, 0.4), 0.18 + 0.1 * night)
        let stem = Tone(0.18, 0.42, 0.2).mix(Tone(0.33, 0.62, 0.3), night)
        let leafTone = Tone(0.32, 0.62, 0.26).mix(Tone(0.42, 0.74, 0.34), night)
        let petals = [Tone(0.95, 0.55, 0.65), Tone(1, 0.82, 0.35), Tone(0.75, 0.6, 0.95), Tone(1, 0.97, 0.92), Tone(0.98, 0.5, 0.35)]
        let vines = small ? 7 : 11
        var random = Seeded(7)
        for index in 0..<vines {
            let base = (Double(index) + 0.5) / Double(vines) * w + random.between(-0.03, 0.03) * w
            let reach = h * random.between(0.35, 0.82)
            let wiggle = random.between(18, 46) * unit, frequency = random.between(1.6, 3.2), phase = random.next() * 6
            let progress = ease(stage(growth, Double(index) / Double(vines) * 0.25, 0.75 + Double(index) / Double(vines) * 0.15))
            guard progress > 0 else { continue }
            let steps = 70
            let shown = Int(Double(steps) * progress)
            var points: [CGPoint] = []
            for step in 0...max(shown, 1) {
                let along = Double(step) / Double(steps)
                let sway = sin(time * 0.5 + Double(index)) * 8 * unit * along
                points.append(CGPoint(x: base + wiggle * sin(along * frequency * .pi + phase) + sway, y: h - along * reach))
            }
            var path = Path()
            path.addLines(points)
            canvas.stroke(path, with: .color(stem.color()), style: StrokeStyle(lineWidth: 3.2 * unit + 1, lineCap: .round, lineJoin: .round))
            // Leaves open behind the tip, alternating sides.
            for step in stride(from: 4, to: points.count, by: 5) {
                let open = ease(clamp(Double(shown - step) / 6))
                guard open > 0 else { continue }
                let side: Double = step % 10 == 4 ? 1 : -1
                let point = points[step]
                let length = 22 * unit * open, width = 9 * unit * open
                var shape = Path()
                shape.move(to: .zero)
                shape.addQuadCurve(to: CGPoint(x: side * length, y: 0), control: CGPoint(x: side * length * 0.5, y: -width))
                shape.addQuadCurve(to: .zero, control: CGPoint(x: side * length * 0.5, y: width))
                let turn = CGAffineTransform(rotationAngle: side * 0.9 + sin(time * 0.7 + Double(step)) * 0.08)
                    .concatenating(CGAffineTransform(translationX: point.x, y: point.y))
                canvas.fill(shape.applying(turn), with: .color(leafTone.color(0.92)))
            }
            // A flower opens at the tip once the vine is grown.
            let bloom = ease(stage(growth, 0.82 + Double(index % 3) * 0.04, 1))
            if bloom > 0, let tip = points.last {
                let tone = petals[index % petals.count]
                var flower = canvas
                flower.translateBy(x: tip.x, y: tip.y)
                flower.rotate(by: .radians(time * 0.05 + Double(index)))
                for petal in 0..<6 {
                    var leaf = flower
                    leaf.rotate(by: .radians(Double(petal) / 6 * 2 * .pi))
                    leaf.fill(Path(ellipseIn: CGRect(x: 0, y: -5 * unit * bloom, width: 16 * unit * bloom, height: 10 * unit * bloom)), with: .color(tone.color(0.95)))
                }
                flower.fill(Path(ellipseIn: CGRect(x: -4 * unit * bloom, y: -4 * unit * bloom, width: 8 * unit * bloom, height: 8 * unit * bloom)), with: .color(Tone(1, 0.85, 0.3).color()))
                if night > 0.3 { glow(&canvas, tip, 30 * unit * bloom, tone, 0.25 * night) }
            }
        }
        motes(&canvas, count: 34, tone: Tone(1, 0.88, 0.45), strength: night * 0.9 * clamp(growth * 3), seed: 11)
        motes(&canvas, count: 22, tone: Tone(1, 1, 0.9), strength: (1 - night) * 0.35, seed: 12, size: 0.6)
    }

    // MARK: Transit

    func transit(_ canvas: inout GraphicsContext) {
        sky(&canvas, day: (Tone(0.74, 0.86, 0.97), Tone(0.95, 0.94, 0.9)), dark: (Tone(0.04, 0.06, 0.14), Tone(0.13, 0.12, 0.2)))
        sunAndMoon(&canvas, height: 0.3)
        starfield(&canvas, count: 90, below: 0.45, seed: 21, strength: night)
        // Far hills.
        var hills = Path()
        hills.move(to: CGPoint(x: 0, y: h))
        for x in stride(from: 0.0, through: w + 10, by: 10) {
            hills.addLine(to: CGPoint(x: x, y: h * 0.5 + sin(x / w * 5 + 1) * h * 0.04 + sin(x / w * 11) * h * 0.015))
        }
        hills.addLine(to: CGPoint(x: w, y: h))
        canvas.fill(hills, with: .color(Tone(0.62, 0.74, 0.66).mix(Tone(0.08, 0.1, 0.16), night).color()))
        // The railway on its viaduct, with a train every half minute.
        let railY = h * 0.47
        let rail = stage(growth, 0, 0.3)
        let railEnd = w * ease(rail)
        let deck = Tone(0.45, 0.47, 0.5).mix(Tone(0.25, 0.27, 0.35), night)
        if rail > 0 {
            canvas.stroke(Path { $0.move(to: CGPoint(x: 0, y: railY)); $0.addLine(to: CGPoint(x: railEnd, y: railY)) }, with: .color(deck.color()), lineWidth: 4 * unit + 1)
            for x in stride(from: 30.0, through: railEnd, by: 90 * unit + 30) {
                canvas.fill(Path(CGRect(x: x - 3 * unit, y: railY, width: 6 * unit + 1, height: h * 0.04)), with: .color(deck.color(0.8)))
            }
        }
        if rail >= 1 {
            let run = fract(time / 32)
            let length = w * 0.35, front = -length + run * (w + length * 2)
            for car in 0..<6 {
                let x = front - Double(car) * length / 6
                guard x > -length / 6, x < w + 10 else { continue }
                let body = CGRect(x: x - length / 6 + 3, y: railY - 16 * unit - 3, width: length / 6 - 6, height: 15 * unit + 2)
                canvas.fill(Path(roundedRect: body, cornerRadius: 4 * unit), with: .color(Tone(0.85, 0.2, 0.18).mix(Tone(0.3, 0.32, 0.42), night).color()))
                for window in 0..<4 {
                    let pane = CGRect(x: body.minX + 6 + Double(window) * (body.width - 12) / 4, y: body.minY + 3, width: (body.width - 12) / 4 - 4, height: body.height * 0.4)
                    canvas.fill(Path(pane), with: .color(Tone(0.75, 0.88, 0.97).mix(Tone(1, 0.86, 0.5), night).color(0.9)))
                }
            }
        }
        // Three roads, nearest last, laid from the left, then traffic on what's laid.
        let roads: [(Double, Double, Double)] = [(0.6, 7, 0.08), (0.74, 11, 0.14), (0.9, 18, 0.22)]
        for (index, road) in roads.enumerated() {
            let laid = ease(stage(growth, 0.15 + Double(index) * 0.15, 0.55 + Double(index) * 0.12))
            guard laid > 0 else { continue }
            func y(_ x: Double) -> Double { h * road.0 + sin(x / w * 2 * .pi * 0.8 + Double(index)) * h * 0.025 }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y(0)))
            for x in stride(from: 0.0, through: w * laid, by: 8) { path.addLine(to: CGPoint(x: x, y: y(x))) }
            let width = road.1 * unit + 2
            canvas.stroke(path, with: .color(Tone(0.36, 0.37, 0.4).mix(Tone(0.12, 0.13, 0.18), night).color()), style: StrokeStyle(lineWidth: width, lineCap: .round))
            canvas.stroke(path, with: .color(Tone(1, 0.95, 0.75).color(0.7)), style: StrokeStyle(lineWidth: max(1, width * 0.08), dash: [width * 1.4, width * 1.2]))
            if index == 2 {
                // Street lamps along the nearest road, lit at night.
                for x in stride(from: 40.0, through: w * laid, by: 160 * unit + 40) {
                    let top = CGPoint(x: x, y: y(x) - width - 40 * unit)
                    canvas.stroke(Path { $0.move(to: CGPoint(x: x, y: y(x) - width / 2)); $0.addLine(to: top) }, with: .color(deck.color()), lineWidth: 2)
                    glow(&canvas, top, 26 * unit, Tone(1, 0.85, 0.5), 0.6 * night)
                }
            }
            var random = Seeded(31 + index)
            let cars = small ? 3 : 4 + index * 2
            for car in 0..<cars {
                let forward = car % 2 == 0
                let speed = random.between(0.03, 0.07) * (1 + Double(index) * 0.4)
                var along = fract(random.next() + time * speed)
                if !forward { along = 1 - along }
                let x = along * (w + 60) - 30
                guard x < w * laid - 10 else { continue }
                let lane = (forward ? -1.0 : 1.0) * width * 0.22
                let centre = CGPoint(x: x, y: y(x) + lane)
                let length = width * 1.5, height = width * 0.42
                let colours = [Tone(0.2, 0.45, 0.85), Tone(0.95, 0.75, 0.2), Tone(0.9, 0.3, 0.3), Tone(0.95, 0.95, 0.95), Tone(0.3, 0.7, 0.45)]
                let body = CGRect(x: centre.x - length / 2, y: centre.y - height / 2, width: length, height: height)
                canvas.fill(Path(roundedRect: body, cornerRadius: height * 0.4), with: .color(colours[car % colours.count].mix(Tone(0.15, 0.15, 0.2), night * 0.7).color()))
                let head = CGPoint(x: forward ? body.maxX : body.minX, y: centre.y)
                let tail = CGPoint(x: forward ? body.minX : body.maxX, y: centre.y)
                glow(&canvas, head, width * 1.6, Tone(1, 0.97, 0.85), 0.75 * night)
                glow(&canvas, tail, width * 0.8, Tone(1, 0.2, 0.15), 0.8 * night)
            }
        }
    }

    // MARK: City

    func city(_ canvas: inout GraphicsContext) {
        sky(&canvas, day: (Tone(0.62, 0.8, 0.96), Tone(0.95, 0.9, 0.82)), dark: (Tone(0.03, 0.04, 0.12), Tone(0.2, 0.12, 0.22)))
        starfield(&canvas, count: 120, below: 0.6, seed: 41, strength: night)
        sunAndMoon(&canvas, height: 0.28)
        let floor = 11 * unit + 3
        for layer in 0..<2 {
            var random = Seeded(51 + layer)
            var x = -random.between(0, 40) * unit
            var index = 0
            let tone = layer == 0
                ? Tone(0.68, 0.74, 0.82).mix(Tone(0.12, 0.13, 0.24), night)
                : Tone(0.42, 0.47, 0.56).mix(Tone(0.06, 0.07, 0.14), night)
            while x < w {
                let width = random.between(50, 120) * unit + 20
                let floors = Int(random.between(layer == 0 ? 14 : 6, layer == 0 ? 42 : 30) * (h / 900))
                let start = random.next() * 0.45 + Double(layer) * 0.15
                let built = Int(Double(floors) * ease(stage(growth, start, start + 0.4)))
                let ground = h * (layer == 0 ? 0.86 : 0.97)
                if built > 0 {
                    let top = ground - Double(built) * floor
                    canvas.fill(Path(CGRect(x: x, y: top, width: width - 6 * unit, height: ground - top + 2)), with: .color(tone.color()))
                    // Windows: lit at random through the night, a pale glint by day.
                    let columns = max(2, Int(width / (16 * unit + 6)))
                    let pane = (width - 6 * unit) / Double(columns)
                    let shift = Int(time / 18)
                    for storey in 0..<built where storey % 1 == 0 {
                        for column in 0..<columns {
                            var cell = Seeded(index * 7919 + storey * 131 + column * 17 + layer * 3 + shift * (column % 5 == 0 ? 1 : 0))
                            let lit = cell.next() < 0.45
                            let y = ground - Double(storey + 1) * floor + floor * 0.25
                            let rect = CGRect(x: x + Double(column) * pane + pane * 0.22, y: y, width: pane * 0.56, height: floor * 0.5)
                            let day = Tone(0.85, 0.92, 1).color(layer == 0 ? 0.25 : 0.35)
                            canvas.fill(Path(rect), with: lit && night > 0.2 ? .color(Tone(1, 0.84, 0.5).color(0.85 * night)) : .color(day))
                        }
                    }
                    // A crane on a building still going up.
                    if built < floors {
                        let mast = CGPoint(x: x + width * 0.6, y: top)
                        let crane = Tone(0.95, 0.7, 0.15).mix(Tone(0.9, 0.5, 0.2), night)
                        canvas.stroke(Path { path in
                            path.move(to: mast); path.addLine(to: CGPoint(x: mast.x, y: top - 40 * unit))
                            path.move(to: CGPoint(x: mast.x - 30 * unit, y: top - 36 * unit)); path.addLine(to: CGPoint(x: mast.x + 50 * unit, y: top - 36 * unit))
                            let hook = mast.x + 20 * unit + sin(time * 0.4 + Double(index)) * 20 * unit
                            path.move(to: CGPoint(x: hook, y: top - 36 * unit)); path.addLine(to: CGPoint(x: hook, y: top - 14 * unit))
                        }, with: .color(crane.color()), lineWidth: 2)
                        glow(&canvas, CGPoint(x: mast.x, y: top - 40 * unit), 10 * unit, Tone(1, 0.2, 0.2), (0.5 + 0.5 * sin(time * 3)) * 0.8)
                    }
                }
                x += width
                index += 1
            }
        }
        canvas.fill(Path(CGRect(x: 0, y: h * 0.97, width: w, height: h * 0.03 + 2)), with: .color(Tone(0.3, 0.32, 0.36).mix(Tone(0.04, 0.05, 0.1), night).color()))
    }

    // MARK: Harbour

    func harbour(_ canvas: inout GraphicsContext) {
        sky(&canvas, day: (Tone(0.6, 0.8, 0.95), Tone(0.94, 0.9, 0.82)), dark: (Tone(0.02, 0.04, 0.1), Tone(0.1, 0.1, 0.2)))
        starfield(&canvas, count: 130, below: 0.6, seed: 61, strength: night)
        sunAndMoon(&canvas, height: 0.32)
        let horizon = h * 0.62
        let sea = Tone(0.2, 0.5, 0.7).mix(Tone(0.03, 0.08, 0.16), night)
        canvas.fill(Path(CGRect(x: 0, y: horizon, width: w, height: h - horizon)), with: .linearGradient(
            Gradient(colors: [sea.mix(Tone(0.8, 0.9, 0.95), 0.3 * (1 - night)).color(), sea.color()]), startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: h)))
        for row in 0..<(small ? 8 : 16) {
            let depth = Double(row) / 16
            let y = horizon + pow(depth, 1.6) * (h - horizon)
            var line = Path()
            for x in stride(from: 0.0, through: w, by: 10) {
                let wave = sin(x / (40 + depth * 120) + time * (0.6 + depth) + Double(row)) * (1 + depth * 5) * unit
                if x == 0 { line.move(to: CGPoint(x: x, y: y + wave)) } else { line.addLine(to: CGPoint(x: x, y: y + wave)) }
            }
            canvas.stroke(line, with: .color(.white.opacity(0.08 + 0.1 * depth)), lineWidth: 1 + depth)
        }
        // Rocks, then the lighthouse built course by course, then its lamp.
        let base = CGPoint(x: w * 0.76, y: horizon + (h - horizon) * 0.35)
        let rocks = ease(stage(growth, 0, 0.15))
        var rock = Path()
        rock.move(to: CGPoint(x: base.x - 120 * unit, y: base.y + 30 * unit))
        rock.addQuadCurve(to: CGPoint(x: base.x + 130 * unit, y: base.y + 30 * unit), control: CGPoint(x: base.x, y: base.y - 40 * unit * rocks))
        canvas.fill(rock, with: .color(Tone(0.35, 0.33, 0.3).mix(Tone(0.08, 0.08, 0.1), night).color()))
        let tower = ease(stage(growth, 0.1, 0.75))
        let towerHeight = 230 * unit * tower
        let bands = 7
        for band in 0..<bands {
            let low = Double(band) / Double(bands), high = Double(band + 1) / Double(bands)
            guard towerHeight > low * 230 * unit else { break }
            let bottom = base.y - low * 230 * unit, top = base.y - min(high * 230 * unit, towerHeight)
            func half(_ y: Double) -> Double { (28 - 12 * (base.y - y) / (230 * unit)) * unit }
            var shape = Path()
            shape.move(to: CGPoint(x: base.x - half(bottom), y: bottom))
            shape.addLine(to: CGPoint(x: base.x + half(bottom), y: bottom))
            shape.addLine(to: CGPoint(x: base.x + half(top), y: top))
            shape.addLine(to: CGPoint(x: base.x - half(top), y: top))
            shape.closeSubpath()
            let tone = band % 2 == 0 ? Tone(0.96, 0.95, 0.92) : Tone(0.8, 0.18, 0.16)
            canvas.fill(shape, with: .color(tone.mix(Tone(0.25, 0.25, 0.3), night * 0.6).color()))
        }
        let lamp = ease(stage(growth, 0.75, 0.9))
        if lamp > 0 {
            let top = CGPoint(x: base.x, y: base.y - 230 * unit - 14 * unit)
            canvas.fill(Path(CGRect(x: top.x - 16 * unit, y: top.y, width: 32 * unit, height: 14 * unit * lamp)), with: .color(Tone(0.2, 0.22, 0.25).color()))
            canvas.fill(Path { path in
                path.move(to: CGPoint(x: top.x - 20 * unit, y: top.y)); path.addLine(to: CGPoint(x: top.x, y: top.y - 18 * unit * lamp)); path.addLine(to: CGPoint(x: top.x + 20 * unit, y: top.y))
            }, with: .color(Tone(0.8, 0.18, 0.16).color()))
            let light = CGPoint(x: top.x, y: top.y + 7 * unit)
            let beam = stage(growth, 0.9, 1) * (0.25 + 0.75 * night)
            glow(&canvas, light, 50 * unit, Tone(1, 0.92, 0.6), 0.9 * beam)
            // The beam turns: long when it points across the water, short when it faces you.
            let angle = time * 0.6
            for side in [0.0, .pi] {
                let a = angle + side
                let reach = w * 0.9 * abs(cos(a))
                let direction = cos(a) >= 0 ? 1.0 : -1.0
                var cone = Path()
                cone.move(to: light)
                cone.addLine(to: CGPoint(x: light.x + direction * reach, y: light.y - reach * 0.04))
                cone.addLine(to: CGPoint(x: light.x + direction * reach, y: light.y + reach * 0.07))
                cone.closeSubpath()
                canvas.fill(cone, with: .linearGradient(Gradient(colors: [Tone(1, 0.94, 0.7).color(0.55 * beam), Tone(1, 0.94, 0.7).color(0)]),
                                                         startPoint: light, endPoint: CGPoint(x: light.x + direction * reach, y: light.y)))
            }
        }
        // Boats drifting along the horizon.
        var random = Seeded(71)
        for boat in 0..<(small ? 2 : 4) {
            let along = fract(random.next() + time * random.between(0.004, 0.009))
            let x = along * (w * 1.2) - w * 0.1
            let y = horizon + (h - horizon) * random.between(0.08, 0.5) + sin(time * 1.2 + Double(boat)) * 2 * unit
            let scale = (0.6 + (y - horizon) / (h - horizon)) * unit
            canvas.fill(Path { path in
                path.move(to: CGPoint(x: x - 26 * scale, y: y)); path.addLine(to: CGPoint(x: x + 26 * scale, y: y))
                path.addLine(to: CGPoint(x: x + 18 * scale, y: y + 9 * scale)); path.addLine(to: CGPoint(x: x - 18 * scale, y: y + 9 * scale))
            }, with: .color(Tone(0.25, 0.2, 0.18).mix(Tone(0.05, 0.05, 0.08), night).color()))
            canvas.fill(Path { path in
                path.move(to: CGPoint(x: x, y: y - 2)); path.addLine(to: CGPoint(x: x, y: y - 44 * scale)); path.addLine(to: CGPoint(x: x + 22 * scale, y: y - 4))
            }, with: .color(Tone(0.98, 0.97, 0.93).mix(Tone(0.5, 0.52, 0.6), night).color()))
            glow(&canvas, CGPoint(x: x, y: y - 44 * scale), 8 * unit, Tone(1, 0.85, 0.5), 0.8 * night)
        }
        // Gulls by day.
        if night < 0.6 {
            for gull in 0..<(small ? 2 : 5) {
                var random = Seeded(81 + gull)
                let x = fract(random.next() + time * 0.01) * (w + 100) - 50
                let y = h * random.between(0.12, 0.4) + sin(time * 0.5 + Double(gull)) * 10 * unit
                let flap = sin(time * 4 + Double(gull)) * 5 * unit
                canvas.stroke(Path { path in
                    path.move(to: CGPoint(x: x - 10 * unit, y: y - flap)); path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x - 5 * unit, y: y - 6 * unit))
                    path.addQuadCurve(to: CGPoint(x: x + 10 * unit, y: y - flap), control: CGPoint(x: x + 5 * unit, y: y - 6 * unit))
                }, with: .color(Tone(0.25, 0.28, 0.32).color(1 - night)), lineWidth: 1.6)
            }
        }
    }

    // MARK: Stars

    func stars(_ canvas: inout GraphicsContext) {
        sky(&canvas, day: (Tone(0.16, 0.22, 0.44), Tone(0.48, 0.5, 0.7)), dark: (Tone(0.01, 0.02, 0.07), Tone(0.07, 0.06, 0.16)))
        let centre = CGPoint(x: w * 0.5, y: h * 0.55)
        let turn = time * 0.003
        func place(_ x: Double, _ y: Double) -> CGPoint {
            let dx = (x - 0.5) * w * 1.3, dy = (y - 0.5) * h * 1.3
            return CGPoint(x: centre.x + dx * cos(turn) - dy * sin(turn), y: centre.y + dx * sin(turn) + dy * cos(turn))
        }
        // The Milky Way: a faint band across.
        var band = canvas
        band.addFilter(.blur(radius: small ? 10 : 40))
        band.opacity = 0.35 * clamp(growth * 2)
        band.fill(Path { path in
            path.move(to: place(-0.1, 0.25)); path.addLine(to: place(1.1, 0.7)); path.addLine(to: place(1.1, 0.85)); path.addLine(to: place(-0.1, 0.42))
        }, with: .color(Tone(0.75, 0.7, 1).color()))
        var random = Seeded(91)
        let count = small ? 90 : 320
        for index in 0..<count {
            let x = random.next(), y = random.next(), size = random.next()
            let appear = clamp((growth - Double(index) / Double(count) * 0.55) * 8)
            guard appear > 0 else { continue }
            let point = place(x, y)
            let twinkle = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(time * (0.6 + size) + Double(index)), 2)
            let radius = (0.5 + size * size * 2.2) * max(unit, 0.5)
            canvas.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(.white.opacity(twinkle * appear)))
        }
        // Constellations: bright stars joined one line at a time.
        let tones = [Tone(0.7, 0.85, 1), Tone(1, 0.85, 0.6), Tone(0.8, 0.7, 1), Tone(0.6, 1, 0.9)]
        for figure in 0..<(small ? 3 : 7) {
            var random = Seeded(101 + figure)
            let cx = random.between(0.12, 0.88), cy = random.between(0.12, 0.8)
            let points = (0..<Int(random.between(5, 8))).map { _ in place(cx + random.between(-0.1, 0.1), cy + random.between(-0.09, 0.09)) }
            let begin = 0.3 + Double(figure) * 0.08
            let drawn = stage(growth, begin, begin + 0.15) * Double(points.count - 1)
            let tone = tones[figure % tones.count]
            for (index, point) in points.enumerated() where Double(index) <= drawn + 1 && growth > begin {
                glow(&canvas, point, 9 * unit, tone, 0.9)
                canvas.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(.white))
            }
            for index in 0..<(points.count - 1) {
                let part = clamp(drawn - Double(index))
                guard part > 0 else { break }
                let from = points[index], to = points[index + 1]
                canvas.stroke(Path { $0.move(to: from); $0.addLine(to: CGPoint(x: from.x + (to.x - from.x) * part, y: from.y + (to.y - from.y) * part)) },
                              with: .color(tone.color(0.45)), lineWidth: 1.2)
            }
        }
        // A shooting star now and then.
        let streak = fract(time / 23)
        if streak < 0.06 {
            var random = Seeded(Int(time / 23))
            let start = CGPoint(x: random.between(0.1, 0.9) * w, y: random.between(0.05, 0.4) * h)
            let along = streak / 0.06
            let head = CGPoint(x: start.x + along * 260 * unit, y: start.y + along * 120 * unit)
            canvas.stroke(Path { $0.move(to: CGPoint(x: head.x - 80 * unit, y: head.y - 37 * unit)); $0.addLine(to: head) },
                          with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0.9 * (1 - along))]),
                                                startPoint: CGPoint(x: head.x - 80 * unit, y: head.y - 37 * unit), endPoint: head), lineWidth: 2)
        }
    }

    // MARK: Dunes

    func dunes(_ canvas: inout GraphicsContext) {
        sky(&canvas, day: (Tone(0.62, 0.8, 0.95), Tone(0.99, 0.88, 0.7)), dark: (Tone(0.05, 0.05, 0.15), Tone(0.3, 0.17, 0.22)))
        starfield(&canvas, count: 110, below: 0.55, seed: 111, strength: night)
        sunAndMoon(&canvas, height: 0.34)
        let layers = 5
        var ridge: [Double] = []
        for layer in 0..<layers {
            let depth = Double(layer) / Double(layers - 1)
            let rise = ease(stage(growth, depth * 0.45, depth * 0.45 + 0.35))
            guard rise > 0 else { continue }
            let base = h * (0.5 + depth * 0.36) + (1 - rise) * h * 0.25
            let amplitude = h * (0.05 + depth * 0.03)
            let drift = time * 0.004 * (1 + depth)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: h))
            var tops: [Double] = []
            for x in stride(from: 0.0, through: w + 10, by: 8) {
                let y = base - amplitude * (0.6 * sin(x / w * (2.2 + depth) * .pi + Double(layer) * 1.7 + drift)
                                            + 0.4 * sin(x / w * (5.3 + depth * 2) * .pi + Double(layer) + drift * 1.6))
                tops.append(y)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: w + 10, y: h))
            path.closeSubpath()
            let day = Tone(0.96, 0.82, 0.58).mix(Tone(0.82, 0.55, 0.3), depth)
            let dark = Tone(0.32, 0.26, 0.4).mix(Tone(0.14, 0.1, 0.2), depth)
            canvas.fill(path, with: .linearGradient(Gradient(colors: [day.mix(dark, night).color(), day.mix(dark, night).mix(Tone(0.4, 0.25, 0.15), 0.25).color()]),
                                                     startPoint: CGPoint(x: 0, y: base - amplitude), endPoint: CGPoint(x: 0, y: h)))
            if layer == 2 { ridge = tops }
        }
        // A caravan along the middle ridge once the dunes are up.
        let caravan = stage(growth, 0.6, 0.75)
        if caravan > 0, !ridge.isEmpty {
            let lead = fract(time / 260) * (w * 1.3) - w * 0.15
            for camel in 0..<(small ? 3 : 5) {
                let x = lead - Double(camel) * 46 * unit
                guard x > 0, x < w else { continue }
                let index = min(max(Int(x / 8), 0), ridge.count - 1)
                let y = ridge[index]
                let step = sin(time * 3 + Double(camel)) * 3 * unit
                let shade = Tone(0.25, 0.16, 0.1).mix(Tone(0.06, 0.04, 0.08), night).color(caravan)
                canvas.fill(Path(ellipseIn: CGRect(x: x - 14 * unit, y: y - 24 * unit, width: 28 * unit, height: 12 * unit)), with: .color(shade))
                canvas.fill(Path(ellipseIn: CGRect(x: x - 7 * unit, y: y - 31 * unit, width: 12 * unit, height: 10 * unit)), with: .color(shade))
                canvas.stroke(Path { path in
                    path.move(to: CGPoint(x: x + 12 * unit, y: y - 20 * unit)); path.addLine(to: CGPoint(x: x + 19 * unit, y: y - 32 * unit))
                    for leg in [-9.0, -4, 5, 10] {
                        path.move(to: CGPoint(x: x + leg * unit, y: y - 14 * unit)); path.addLine(to: CGPoint(x: x + leg * unit + (leg > 0 ? step : -step), y: y))
                    }
                }, with: .color(shade), lineWidth: 2.2 * unit + 0.5)
            }
        }
        motes(&canvas, count: 40, tone: Tone(1, 0.9, 0.7), strength: 0.35, seed: 121, rising: false, sideways: 6, size: 0.5)
    }

    // MARK: Circuit

    func circuit(_ canvas: inout GraphicsContext) {
        sky(&canvas, day: (Tone(0.88, 0.95, 0.91), Tone(0.8, 0.9, 0.85)), dark: (Tone(0.01, 0.06, 0.06), Tone(0.02, 0.1, 0.09)))
        let grid = 26 * unit + 8
        let dot = Tone(0.6, 0.75, 0.68).mix(Tone(0.1, 0.25, 0.22), night)
        for x in stride(from: grid / 2, through: w, by: grid) {
            for y in stride(from: grid / 2, through: h, by: grid) {
                canvas.fill(Path(CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)), with: .color(dot.color(0.6)))
            }
        }
        let trace = Tone(0.1, 0.48, 0.34).mix(Tone(0.18, 0.78, 0.56), night)
        let pulse = Tone(1, 0.7, 0.2).mix(Tone(0.4, 1, 0.95), night)
        let chip = CGRect(x: w * 0.5 - 70 * unit, y: h * 0.5 - 70 * unit, width: 140 * unit, height: 140 * unit)
        let chipIn = ease(stage(growth, 0, 0.1))
        var random = Seeded(131)
        let count = small ? 18 : 48
        for index in 0..<count {
            // From a pin on the chip's edge, out across the board in right-angle turns.
            let side = index % 4
            let along = random.between(0.12, 0.88)
            var point: CGPoint
            var heading: CGPoint
            switch side {
            case 0: point = CGPoint(x: chip.minX + along * chip.width, y: chip.minY); heading = CGPoint(x: 0, y: -1)
            case 1: point = CGPoint(x: chip.maxX, y: chip.minY + along * chip.height); heading = CGPoint(x: 1, y: 0)
            case 2: point = CGPoint(x: chip.minX + along * chip.width, y: chip.maxY); heading = CGPoint(x: 0, y: 1)
            default: point = CGPoint(x: chip.minX, y: chip.minY + along * chip.height); heading = CGPoint(x: -1, y: 0)
            }
            var points = [point]
            for turn in 0..<Int(random.between(3, 7)) {
                let length = random.between(1, 5).rounded() * grid
                point = CGPoint(x: point.x + heading.x * length, y: point.y + heading.y * length)
                points.append(point)
                // Turn left or right, never back towards the chip.
                let left = random.next() < 0.5
                heading = turn % 2 == 0 ? (left ? CGPoint(x: -heading.y, y: heading.x) : CGPoint(x: heading.y, y: -heading.x)) : [CGPoint(x: 0, y: -1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0)][side]
            }
            let begin = 0.08 + Double(index) / Double(count) * 0.6
            let drawn = ease(stage(growth, begin, begin + 0.2))
            guard drawn > 0 else { continue }
            var path = Path()
            path.addLines(points)
            let shown = path.trimmedPath(from: 0, to: drawn)
            canvas.stroke(shown, with: .color(trace.color(0.85)), style: StrokeStyle(lineWidth: 2.2 * unit + 0.8, lineCap: .round, lineJoin: .round))
            if drawn >= 1, let end = points.last {
                canvas.stroke(Path(ellipseIn: CGRect(x: end.x - 5 * unit, y: end.y - 5 * unit, width: 10 * unit, height: 10 * unit)), with: .color(trace.color()), lineWidth: 2)
                // A pulse running out along the finished trace.
                let period = random.between(3, 8)
                let run = fract(time / period + random.next())
                let total = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
                var left = run * total
                for (from, to) in zip(points, points.dropFirst()) {
                    let length = hypot(to.x - from.x, to.y - from.y)
                    if left <= length {
                        let f = length == 0 ? 0 : left / length
                        glow(&canvas, CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f), 12 * unit + 3, pulse, 0.9)
                        break
                    }
                    left -= length
                }
            } else {
                _ = random.next(); _ = random.next()
            }
        }
        if chipIn > 0 {
            canvas.fill(Path(roundedRect: chip.insetBy(dx: chip.width * (1 - chipIn) / 2, dy: chip.height * (1 - chipIn) / 2), cornerRadius: 10 * unit),
                        with: .color(Tone(0.12, 0.16, 0.16).mix(Tone(0.05, 0.12, 0.12), night).color()))
            glow(&canvas, CGPoint(x: chip.midX, y: chip.midY), 90 * unit, pulse, 0.25 * (0.6 + 0.4 * sin(time * 1.5)) * chipIn)
        }
    }
}
