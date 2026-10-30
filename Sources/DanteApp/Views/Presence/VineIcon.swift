import AppKit
import DanteKit

/// The menu bar's Dante: the Vine D (`Logo`) as a one-colour glyph in the menu bar's own text
/// colour, with a firefly in the bowl that takes the mood's colour. The leaves sway and the
/// firefly pulses while an agent works or waits; it dims as usage runs low and when asleep.
final class VineIcon: NSView {
    var mood: PresenceMood = .asleep {
        didSet { if mood != oldValue { moodChanged() } }
    }
    /// 0…1, how busy the agents are: the leaves sway faster.
    var intensity: Double = 0
    /// 0…1, the five-hour window's tiredness: the glyph fades a little.
    var fatigue: Double = 0 {
        didSet { if abs(fatigue - oldValue) > 0.05 { needsDisplay = true } }
    }
    private var timer: Timer?
    private var clock: Double = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        moodChanged()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var moves: Bool {
        switch mood {
        case .acting, .thinking, .needsYou, .listening: true
        default: false
        }
    }

    private func moodChanged() {
        needsDisplay = true
        guard window != nil, moves, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        // A gentle 20 fps, only while something is happening.
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock += (1.0 / 20) * (1 + 1.5 * self.intensity)
                // Every redraw goes through the system's menu bar, so none while nobody can see it
                // (screens asleep, a full-screen app hiding the bar): fewer trips through code
                // that has crashed Dante on wake.
                guard self.window?.occlusionState.contains(.visible) == true else { return }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The firefly's colour for a mood; nil when there's nothing to say.
    private var fireflyColour: NSColor? {
        switch mood {
        case .needsYou: .systemPink
        case .acting, .thinking: .systemOrange
        case .listening: .systemBlue
        case .done: .systemGreen
        case .trouble: .systemRed
        case .idle, .asleep: nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let ink = NSColor.labelColor.withAlphaComponent(mood == .asleep ? 0.45 : 1 - 0.35 * fatigue).cgColor
        Self.draw(in: context, rect: bounds.insetBy(dx: 4, dy: 3), ink: ink, firefly: fireflyColour?.cgColor,
                  sway: moves ? clock : nil, pulse: moves ? 0.5 + 0.5 * sin(clock * 2 * .pi / (mood == .needsYou ? 1.2 : 1.8)) : 1)
    }

    /// The glyph's extent in the logo's 1024 grid, leaves included.
    nonisolated static let glyph = CGRect(x: 262, y: 206, width: 534, height: 600)

    /// Draws the Vine D centred in `rect`. `sway` is the clock for the leaves (nil holds them
    /// still); the firefly grows and glows with `pulse` (0…1).
    nonisolated static func draw(in context: CGContext, rect: CGRect, ink: CGColor, firefly: CGColor?, sway: Double?, pulse: Double) {
        let scale = min(rect.width / glyph.width, rect.height / glyph.height)
        context.saveGState()
        context.translateBy(x: rect.midX - glyph.midX * scale, y: rect.midY - glyph.midY * scale)
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(ink)
        context.setFillColor(ink)
        context.setLineCap(.round)
        // Thicker than the icon's strokes: at menu bar size the vine would vanish.
        context.setLineWidth(Logo.stalkWidth * 1.35)
        context.addPath(path([Logo.stalk]))
        context.strokePath()
        context.setLineWidth(Logo.vineWidth * 1.45)
        context.addPath(path(Logo.vine))
        context.strokePath()
        context.setLineWidth(Logo.tendrilWidth * 2.4)
        context.addPath(path(Logo.tendril))
        context.strokePath()

        let leaf = path(Logo.leafShape)
        // Four leaves along the top of the vine, bigger and broader than the icon's: at this
        // size a row of small ones reads as a cog.
        for (index, item) in Logo.leaves.enumerated() where [0, 1, 3, 6].contains(index) {
            let swing = sway.map { -7 * cos(2 * .pi * ($0 - item.delay) / 2.4) } ?? 0
            context.saveGState()
            context.translateBy(x: item.x, y: item.y)
            context.rotate(by: (item.angle + swing) * .pi / 180)
            let size = item.size / 120
            context.scaleBy(x: size * 1.3, y: size * 2.0)
            context.addPath(leaf)
            context.fillPath()
            context.restoreGState()
        }

        if let firefly {
            let centre = CGPoint(x: 518, y: 512)
            let radius = 58 + 22 * pulse
            context.setFillColor(firefly.copy(alpha: 0.28 * pulse) ?? firefly)
            context.fillEllipse(in: CGRect(x: centre.x - radius * 1.45, y: centre.y - radius * 1.45, width: radius * 2.9, height: radius * 2.9))
            context.setFillColor(firefly)
            context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        }
        context.restoreGState()
    }

    private nonisolated static func path(_ curves: [Logo.Curve]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: curves[0].start)
        for curve in curves { path.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2) }
        return path
    }
}
