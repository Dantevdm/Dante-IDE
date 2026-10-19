import AppKit
import DanteEditor
import DanteKit
import SwiftUI

/// Where the Stage orb's satellites are, frame by frame: the orb publishes as it draws and the
/// HUD follows, so the labels never lag the shader.
@MainActor
final class SatelliteTrack {
    fileprivate weak var listener: StageHUDView?

    func moved(_ frames: [Constellation.Frame], time: Double) {
        listener?.satellitesMoved(frames, time: time)
    }
}

/// The rings around the Stage's orb and the lines to each agent it has handed work to.
/// Core Animation draws it: the rings turn on the render server at the display's own rate
/// (120 Hz and up), with nothing to do on the main thread but change their pace with the work.
struct StageHUD: NSViewRepresentable {
    struct Style: Equatable {
        var tint: NSColor
        var warning: NSColor
        var alarm: NSColor
        var faint: NSColor
        var text: NSColor
    }

    var style: Style
    var intensity: Double
    var usage: Double?
    var unit: CGFloat
    /// The orb's centre, in this view's coordinates (top-left origin).
    var centre: CGPoint
    /// Points per shader unit: half the orb view's side.
    var orbScale: CGFloat
    /// The rings' outer edge.
    var ringRadius: CGFloat
    /// Room for a label beside the rings for each agent at work (not in a narrow window).
    var callouts: Bool
    var track: SatelliteTrack
    var reduceMotion: Bool

    func makeNSView(context: Context) -> StageHUDView {
        let view = StageHUDView()
        track.listener = view
        return view
    }

    func updateNSView(_ view: StageHUDView, context: Context) {
        track.listener = view
        view.update(self)
    }
}

final class StageHUDView: NSView {
    private var config: StageHUD?
    private var geometryKey: [CGFloat] = []

    // The rings: each turning part is a layer the size of the rings, centred on the orb.
    private let scaleSpin = CALayer(), minor = CAShapeLayer(), major = CAShapeLayer()
    private let outer = CAShapeLayer(), inner = CAShapeLayer()
    private let counterSpin = CALayer(), arcs = CAShapeLayer()
    private let sweep = CALayer()
    /// The sweep's fading wedge, as slices from bright at the leading edge to clear.
    private let slices = (0..<28).map { _ in CAShapeLayer() }
    private let loadTrack = CAShapeLayer(), loadFill = CAShapeLayer(), loadLabel = CATextLayer()
    private let usageTrack = CAShapeLayer(), usageFill = CAShapeLayer(), usageLabel = CATextLayer()
    private let flowLayer = CALayer()
    private var flows: [String: Flow] = [:]

    /// The work shown in the rings' pace, eased towards the latest.
    private var shownWork = 0.0
    private var targetWork = 0.0
    private var ramp: Timer?

    /// Turns per second at rest; work speeds each up by its factor.
    private static let scalePeriod = 2 * Double.pi / 0.03, counterPeriod = 2 * Double.pi / 0.08, sweepPeriod = 2 * Double.pi / 0.5
    private static let scaleGain = 4.0, counterGain = 3.75, sweepGain = 3.6

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        guard let root = layer else { return }
        for spin in [scaleSpin, counterSpin] { root.addSublayer(spin) }
        scaleSpin.addSublayer(minor)
        scaleSpin.addSublayer(major)
        counterSpin.addSublayer(arcs)
        for shape in [outer, inner, loadTrack, loadFill, usageTrack, usageFill] { root.addSublayer(shape) }
        root.addSublayer(sweep)
        root.addSublayer(loadLabel)
        root.addSublayer(usageLabel)
        root.addSublayer(flowLayer)
        for slice in slices { sweep.addSublayer(slice) }
        for shape in [minor, major, outer, inner, arcs, loadTrack, loadFill, usageTrack, usageFill] {
            shape.fillColor = nil
        }
        for cap in [arcs, loadTrack, loadFill, usageTrack, usageFill] { cap.lineCap = .round }
        for label in [loadLabel, usageLabel] { label.isWrapped = false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for label in [loadLabel, usageLabel] { label.contentsScale = scale }
        for flow in flows.values { flow.scale(scale) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations don't survive a layer leaving its window.
        if window != nil { startSpinning() }
    }

    // MARK: Updates from SwiftUI

    func update(_ new: StageHUD) {
        let old = config
        config = new
        let key = [new.centre.x, new.centre.y, new.ringRadius, new.unit, new.orbScale]
        let reshaped = key != geometryKey
        if reshaped {
            geometryKey = key
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            buildRings(new)
            CATransaction.commit()
        }
        if reshaped || old?.style != new.style || old?.usage != new.usage || old?.intensity != new.intensity {
            // Colours and gauges ease over a moment, as the mood does in the orb.
            CATransaction.begin()
            CATransaction.setAnimationDuration(reshaped ? 0 : 0.9)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            paint(new)
            CATransaction.commit()
        }
        if old?.reduceMotion != new.reduceMotion || old == nil { startSpinning() }
        let work = min(1, max(0, new.intensity))
        if work != targetWork {
            targetWork = work
            startRamp()
        }
    }

    private func buildRings(_ config: StageHUD) {
        let c = config.centre, r = config.ringRadius, u = config.unit
        let side = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
        let local = CGPoint(x: r, y: r)
        for spin in [scaleSpin, counterSpin] {
            spin.bounds = side
            spin.position = c
        }
        for shape in [minor, major, arcs] { shape.frame = side }

        // The scale: 180 ticks, every fifteenth long.
        let small = CGMutablePath(), long = CGMutablePath()
        for index in 0..<180 {
            let angle = Double(index) / 180 * 2 * .pi
            if index % 15 == 0 {
                long.move(to: point(local, r * 0.925, angle))
                long.addLine(to: point(local, r * 0.975, angle))
            } else {
                small.move(to: point(local, r * 0.952, angle))
                small.addLine(to: point(local, r * 0.975, angle))
            }
        }
        minor.path = small
        major.path = long
        minor.lineWidth = max(1, u)
        major.lineWidth = max(1.5, 2 * u)
        outer.path = circle(c, r * 0.995)
        outer.lineWidth = 1
        inner.path = circle(c, r * 0.86)
        inner.lineWidth = 1

        // Three counter-turning arcs.
        let threeArcs = CGMutablePath()
        for index in 0..<3 {
            let start = Double(index) * 2 * .pi / 3
            threeArcs.addPath(arc(local, r * 0.885, from: start, to: start + 1.25))
        }
        arcs.path = threeArcs
        arcs.lineWidth = max(2, 3 * u)

        // The sweep: a wedge fading out over 0.9 radians behind its leading edge, at angle 0.
        sweep.bounds = side
        sweep.position = c
        for (index, slice) in slices.enumerated() {
            let a0 = -0.9 * Double(index + 1) / Double(slices.count), a1 = -0.9 * Double(index) / Double(slices.count)
            let steps = 4
            let outside = (0...steps).map { point(local, r * 0.905, a0 + (a1 - a0) * Double($0) / Double(steps)) }
            let inside = (0...steps).reversed().map { point(local, r * 0.865, a0 + (a1 - a0) * Double($0) / Double(steps)) }
            let wedge = CGMutablePath()
            wedge.addLines(between: outside + inside)
            wedge.closeSubpath()
            slice.frame = side
            slice.path = wedge
        }

        // Gauges either side, each a 100° arc filling upwards.
        let half = 50 * Double.pi / 180
        loadTrack.path = arc(c, r * 1.06, from: .pi - half, to: .pi + half)
        loadFill.path = arc(c, r * 1.06, from: .pi - half, to: .pi + half)
        usageTrack.path = arc(c, r * 1.06, from: half, to: -half)
        usageFill.path = arc(c, r * 1.06, from: half, to: -half)
        for shape in [loadTrack, loadFill, usageTrack, usageFill] { shape.lineWidth = max(3, 5 * u) }
    }

    private func paint(_ config: StageHUD) {
        let style = config.style, tint = style.tint
        minor.strokeColor = tint.withAlphaComponent(0.25).cgColor
        major.strokeColor = tint.withAlphaComponent(0.7).cgColor
        outer.strokeColor = tint.withAlphaComponent(0.12).cgColor
        inner.strokeColor = tint.withAlphaComponent(0.1).cgColor
        arcs.strokeColor = tint.withAlphaComponent(0.5).cgColor
        for (index, slice) in slices.enumerated() {
            slice.fillColor = tint.withAlphaComponent(0.34 * (1 - CGFloat(index) / CGFloat(slices.count))).cgColor
        }

        let work = min(1, max(0, config.intensity))
        loadTrack.strokeColor = style.faint.withAlphaComponent(0.25).cgColor
        loadFill.strokeColor = tint.cgColor
        loadFill.strokeEnd = work
        loadFill.opacity = work > 0.005 ? 1 : 0
        gaugeLabel(loadLabel, "LOAD \(Int((work * 100).rounded()))%", color: tint, config: config, middle: .pi, mirrored: true)

        let usage = config.usage.map { min(1, max(0, $0)) }
        let usageColor = (usage ?? 0) > 0.95 ? style.alarm : (usage ?? 0) > 0.8 ? style.warning : tint
        for shape in [usageTrack, usageFill, usageLabel] { shape.opacity = usage == nil ? 0 : 1 }
        usageTrack.strokeColor = style.faint.withAlphaComponent(0.25).cgColor
        usageFill.strokeColor = usageColor.cgColor
        usageFill.strokeEnd = usage ?? 0
        gaugeLabel(usageLabel, "USAGE \(Int(((usage ?? 0) * 100).rounded()))%", color: usageColor, config: config, middle: 0, mirrored: false)
    }

    private func gaugeLabel(_ label: CATextLayer, _ text: String, color: NSColor, config: StageHUD, middle: Double, mirrored: Bool) {
        let u = config.unit
        let string = NSAttributedString(string: text, attributes: [
            .font: DanteFonts.sans(size: 12 * u, weight: .semibold), .kern: 2 * u,
            .foregroundColor: color.withAlphaComponent(0.85),
        ])
        label.string = string
        label.contentsScale = window?.backingScaleFactor ?? 2
        let size = string.size()
        let half = 50 * Double.pi / 180
        let top = mirrored ? middle + half : middle - half
        let at = point(config.centre, config.ringRadius * 1.06 + 26 * u, top + (mirrored ? 0.12 : -0.12))
        let x = mirrored ? at.x - size.width : at.x
        label.frame = CGRect(x: x, y: at.y - size.height / 2, width: ceil(size.width) + 2, height: ceil(size.height))
    }

    // MARK: Turning

    private func startSpinning() {
        spin(scaleSpin, period: Self.scalePeriod, direction: 1)
        spin(counterSpin, period: Self.counterPeriod, direction: -1)
        spin(sweep, period: Self.sweepPeriod, direction: 1)
        applySpeeds()
    }

    private func spin(_ layer: CALayer, period: Double, direction: Double) {
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = direction * 2 * .pi
        turn.duration = period
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        layer.add(turn, forKey: "spin")
    }

    /// Eases the pace towards the work over about a second, so the rings speed up and slow
    /// down rather than jump.
    private func startRamp() {
        guard ramp == nil else { return }
        ramp = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepRamp() }
        }
    }

    private func stepRamp() {
        shownWork += (targetWork - shownWork) * 0.12
        if abs(targetWork - shownWork) < 0.004 {
            shownWork = targetWork
            ramp?.invalidate()
            ramp = nil
        }
        applySpeeds()
    }

    private func applySpeeds() {
        let calm = config?.reduceMotion == true ? 0.25 : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setSpeed(scaleSpin, (1 + Self.scaleGain * shownWork) * calm)
        setSpeed(counterSpin, (1 + Self.counterGain * shownWork) * calm)
        setSpeed(sweep, (1 + Self.sweepGain * shownWork) * calm)
        CATransaction.commit()
    }

    /// Changes a layer's pace without a jump: its local time carries on from where it is.
    private func setSpeed(_ layer: CALayer, _ speed: Double) {
        guard abs(Double(layer.speed) - speed) > 0.0005 else { return }
        let now = CACurrentMediaTime()
        let local = layer.convertTime(now, from: nil)
        layer.beginTime = now
        layer.timeOffset = local
        layer.speed = Float(speed)
    }

    // MARK: Who's doing what

    /// Called by the orb each frame it draws satellites.
    func satellitesMoved(_ frames: [Constellation.Frame], time: Double) {
        guard let config else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<String>()
        for frame in frames {
            let id = frame.satellite.id
            seen.insert(id)
            let flow = flows[id] ?? {
                let flow = Flow(scale: window?.backingScaleFactor ?? 2)
                flowLayer.addSublayer(flow.layer)
                flows[id] = flow
                return flow
            }()
            flow.place(frame, time: time, config: config)
        }
        for (id, flow) in flows where !seen.contains(id) {
            flow.layer.removeFromSuperlayer()
            flows[id] = nil
        }
        CATransaction.commit()
    }
}

/// One agent at work: a reticle on its satellite, packets running out to it from the orb (and
/// back as it hands its work in), and a line to a label saying who asked it to do what.
@MainActor
private final class Flow {
    let layer = CALayer()
    private let reticle = CAShapeLayer()
    private let packets = (0..<3).map { _ in CAShapeLayer() }
    private let leader = CAShapeLayer()
    private let shelfDot = CAShapeLayer()
    private let heading = CATextLayer()
    private let task = CATextLayer()
    private var labelKey: (heading: String, task: String, unit: CGFloat, right: Bool, color: RGBA)?
    private var headingSize = CGSize.zero
    private var taskSize = CGSize.zero
    /// -1 (label on the left) … 1 (on the right). It follows the satellite round the orb,
    /// fading out and back in on the other side rather than drawing a line across the orb.
    private var side: Double?
    private var lastTime: Double?
    private static let reticleRadius: CGFloat = 10

    init(scale: CGFloat) {
        for sub in [leader, reticle, shelfDot] + packets { layer.addSublayer(sub) }
        layer.addSublayer(heading)
        layer.addSublayer(task)
        reticle.fillColor = nil
        reticle.lineWidth = 1.5
        reticle.lineDashPattern = [5, 4]
        reticle.path = CGPath(ellipseIn: CGRect(x: -Self.reticleRadius, y: -Self.reticleRadius, width: 2 * Self.reticleRadius, height: 2 * Self.reticleRadius), transform: nil)
        reticle.bounds = .zero
        leader.fillColor = nil
        leader.lineJoin = .round
        task.isWrapped = true
        self.scale(scale)
    }

    func scale(_ scale: CGFloat) {
        heading.contentsScale = scale
        task.contentsScale = scale
    }

    func place(_ frame: Constellation.Frame, time: Double, config: StageHUD) {
        let u = config.unit, c = config.centre, s = config.orbScale
        let color = NSColor(srgbRed: frame.color.red, green: frame.color.green, blue: frame.color.blue, alpha: 1)
        // The shader's y runs up from the orb's centre.
        let at = CGPoint(x: c.x + frame.x * s, y: c.y - frame.y * s)
        let radius = max(1, frame.radius * s)
        let visible = smooth(frame.out)
        // Dimmer while it passes behind the orb.
        let front = Float(0.4 + 0.6 * (frame.depth + 1) / 2)

        reticle.position = at
        let size = radius * 1.75 / Self.reticleRadius
        reticle.setAffineTransform(CGAffineTransform(rotationAngle: time * 0.9).scaledBy(x: size, y: size))
        reticle.strokeColor = color.withAlphaComponent(0.85).cgColor
        reticle.lineWidth = max(1, 1.4 * u) / size
        reticle.opacity = Float(visible) * front

        // Packets: out from the orb's edge to the agent while it works, home again as it merges.
        let dx = at.x - c.x, dy = at.y - c.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        let start = CGPoint(x: c.x + dx / length * 0.47 * s, y: c.y + dy / length * 0.47 * s)
        let end = CGPoint(x: at.x - dx / length * radius * 1.2, y: at.y - dy / length * radius * 1.2)
        let reach = max(0, (end.x - start.x) * dx / length + (end.y - start.y) * dy / length)
        for (index, packet) in packets.enumerated() {
            var along = (time * 0.85 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            if frame.returning { along = 1 - along }
            let dot = max(1.5, 2.6 * u)
            packet.path = CGPath(ellipseIn: CGRect(x: -dot, y: -dot, width: 2 * dot, height: 2 * dot), transform: nil)
            packet.fillColor = color.cgColor
            packet.shadowColor = color.cgColor
            packet.shadowRadius = 4 * u
            packet.shadowOpacity = 0.9
            packet.shadowOffset = .zero
            packet.position = CGPoint(x: start.x + (end.x - start.x) * along, y: start.y + (end.y - start.y) * along)
            packet.opacity = reach > 4 ? Float(visible * sin(along * .pi)) * front : 0
        }

        guard config.callouts else {
            for sub in [leader, shelfDot, heading, task] as [CALayer] { sub.opacity = 0 }
            return
        }
        // The label sits beside the rings on the satellite's side, in its orbit's own row.
        let wanted: Double = frame.x > 0.22 ? 1 : frame.x < -0.22 ? -1 : (self.side.map { $0 >= 0 ? 1 : -1 } ?? (frame.x >= 0 ? 1 : -1))
        let dt = lastTime.map { min(0.1, max(0, time - $0)) } ?? 0
        lastTime = time
        var current = self.side ?? wanted
        current += max(-dt * 4, min(dt * 4, wanted - current))
        self.side = current
        let right = current >= 0
        let fade = Float(min(1, abs(current)))
        let row = -0.55 + 0.22 * CGFloat(frame.slot)
        let side: CGFloat = right ? 1 : -1
        let r = config.ringRadius
        let anchor = CGPoint(x: c.x + side * (r * 1.14 + 12 * u), y: c.y + row * r)
        let shelf = CGPoint(x: anchor.x + side * 34 * u, y: anchor.y)
        let line = CGMutablePath()
        line.move(to: CGPoint(x: at.x + (anchor.x - at.x) / max(1, hypot(anchor.x - at.x, anchor.y - at.y)) * radius * 1.75,
                              y: at.y + (anchor.y - at.y) / max(1, hypot(anchor.x - at.x, anchor.y - at.y)) * radius * 1.75))
        line.addLine(to: anchor)
        line.addLine(to: shelf)
        leader.path = line
        leader.strokeColor = color.withAlphaComponent(0.55).cgColor
        leader.lineWidth = max(1, 1.2 * u)
        leader.opacity = Float(visible) * (0.5 + front / 2) * fade
        let dot = 3 * u
        shelfDot.path = CGPath(ellipseIn: CGRect(x: shelf.x - dot, y: shelf.y - dot, width: 2 * dot, height: 2 * dot), transform: nil)
        shelfDot.fillColor = color.cgColor
        shelfDot.opacity = Float(visible) * fade

        let satellite = frame.satellite
        let title = frame.returning
            ? "\(satellite.agent.uppercased())  →  \(satellite.lead.uppercased())"
            : "\(satellite.lead.uppercased())  →  \(satellite.agent.uppercased())"
        let what = frame.returning ? "Done" + (satellite.task.isEmpty ? "" : ": \(satellite.task)") : satellite.task
        if setLabel(title, what, u, right, frame.color, config.style.text) {
            heading.alignmentMode = right ? .left : .right
            task.alignmentMode = right ? .left : .right
        }
        let gap = 12 * u
        let x = right ? shelf.x + gap : shelf.x - gap - max(headingSize.width, taskSize.width)
        let width = max(headingSize.width, taskSize.width)
        heading.frame = CGRect(x: x, y: shelf.y - headingSize.height - 3 * u, width: width, height: headingSize.height)
        task.frame = CGRect(x: x, y: shelf.y + 3 * u, width: width, height: taskSize.height)
        heading.opacity = Float(visible) * fade
        task.opacity = Float(visible) * 0.95 * fade
    }

    /// Sets the label's text when it changed. True when it did.
    private func setLabel(_ title: String, _ what: String, _ u: CGFloat, _ right: Bool, _ color: RGBA, _ text: NSColor) -> Bool {
        if let current = labelKey, current.heading == title, current.task == what, current.unit == u, current.right == right, current.color == color { return false }
        labelKey = (title, what, u, right, color)
        let tint = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        let headingText = NSAttributedString(string: title, attributes: [
            .font: DanteFonts.sans(size: 13 * u, weight: .semibold), .kern: 2.5 * u, .foregroundColor: tint,
        ])
        heading.string = headingText
        headingSize = CGSize(width: ceil(headingText.size().width) + 2, height: ceil(headingText.size().height))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = right ? .left : .right
        paragraph.lineBreakMode = .byWordWrapping
        let taskText = NSAttributedString(string: what, attributes: [
            .font: DanteFonts.sans(size: 17 * u), .foregroundColor: text.withAlphaComponent(0.9), .paragraphStyle: paragraph,
        ])
        task.string = taskText
        let bound = taskText.boundingRect(with: CGSize(width: 340 * u, height: 200 * u), options: [.usesLineFragmentOrigin, .usesFontLeading])
        taskSize = what.isEmpty ? .zero : CGSize(width: ceil(bound.width) + 2, height: ceil(bound.height) + 2)
        return true
    }
}

private func point(_ centre: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
    CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
}

private func circle(_ centre: CGPoint, _ radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
}

/// An arc drawn as short segments from `start` to `end` (either way round), so its direction
/// doesn't depend on whether the layer is flipped.
private func arc(_ centre: CGPoint, _ radius: CGFloat, from start: Double, to end: Double) -> CGPath {
    let path = CGMutablePath()
    let steps = max(8, Int(abs(end - start) / (1.5 * .pi / 180)))
    for step in 0...steps {
        let angle = start + (end - start) * Double(step) / Double(steps)
        let at = point(centre, radius, angle)
        if step == 0 { path.move(to: at) } else { path.addLine(to: at) }
    }
    return path
}

private func smooth(_ value: Double) -> Double {
    let p = min(1, max(0, value))
    return p * p * (3 - 2 * p)
}
