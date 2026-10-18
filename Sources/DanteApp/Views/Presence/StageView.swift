import AppKit
import DanteKit
import SwiftUI

/// The Stage: Dante full screen, Jarvis style, for this display, a second one or a TV.
/// The orb in the middle inside turning HUD rings, what Claude is saying under it, and the
/// projects and agents at the sides. Opened from the panel's orb, the menu bar menu, or by
/// voice ("full screen"); Esc, the voice ("minimise") or leaving full screen closes it.
@MainActor
final class StageController: NSObject, NSWindowDelegate {
    static let shared = StageController()

    private var window: StageWindow?
    private var activity: NSObjectProtocol?
    private var keys: Any?
    private var cursorTimer: Timer?
    private var lastPointer = NSPoint.zero
    private var pointerStill: Date = .now
    private var closing = false

    var isOpen: Bool { window != nil }

    func toggle() { isOpen ? close() : open() }

    /// Opens on `screen`, else the one the pointer is on (where you just clicked).
    func open(on screen: NSScreen? = nil) {
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = screen ?? NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let window = StageWindow(contentRect: screen.frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false, screen: screen)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.dark.ground.nsColor
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.title = "Stage"
        window.contentView = NSHostingView(rootView:
            StageView(model: PresenceController.shared.model)
                .environment(\.theme, Theme.dark)
        )
        window.setFrame(screen.frame, display: false)
        window.delegate = self
        self.window = window
        closing = false
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)

        // A TV shouldn't go to sleep under it, and the pointer hides when it's still.
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Showing the Stage")
        lastPointer = pointer
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { StageController.shared.hidePointerIfStill() }
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let key = event.keyCode, window = event.windowNumber
            let handled = MainActor.assumeIsolated { StageController.shared.handle(key: key, window: window) }
            return handled ? nil : event
        }
    }

    /// Leaves full screen, then hides the window.
    func close() {
        guard let window, !closing else { return }
        closing = true
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            finish()
        }
    }

    /// Esc leaves, Space talks, Return approves what's waiting.
    private func handle(key: UInt16, window number: Int) -> Bool {
        guard let window, window.windowNumber == number else { return false }
        switch Int(key) {
        case 53:
            close()
        case 49:
            VoiceController.shared.toggle()
        case 36, 76:
            guard let session = StageView.waitingSession, let claude = session.claude else { return false }
            for tool in claude.pendingApprovals { claude.approve(tool.id) }
        default:
            return false
        }
        return true
    }

    private func hidePointerIfStill() {
        let pointer = NSEvent.mouseLocation
        if pointer != lastPointer {
            lastPointer = pointer
            pointerStill = .now
        } else if Date.now.timeIntervalSince(pointerStill) > 3, window?.isKeyWindow == true {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // Leaving full screen any other way (the green button, ⌃⌘F, a gesture) leaves the Stage too.
    func windowDidExitFullScreen(_ notification: Notification) { finish() }

    func windowWillClose(_ notification: Notification) { tearDown() }

    private func finish() {
        window?.orderOut(nil)
        tearDown()
    }

    private func tearDown() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        if let keys { NSEvent.removeMonitor(keys) }
        activity = nil
        keys = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        window?.delegate = nil
        window = nil
        closing = false
    }
}

/// The Stage's window: takes keys, and Esc reaches it even when SwiftUI doesn't pass it on.
final class StageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { StageController.shared.close() }
}

struct StageView: View {
    @Environment(\.theme) private var theme
    let model: PresenceModel
    @State private var tally = StageTally()

    /// The window with something waiting for an answer, if any.
    @MainActor static var waitingSession: Session? {
        Sessions.all.first { $0.claude?.pendingApprovals.isEmpty == false }
    }

    /// The project the caption follows: one waiting, else one working, else the frontmost.
    private var focus: Session? {
        Self.waitingSession
            ?? Sessions.all.first { $0.claude?.state == .working }
            ?? ActiveProject.shared.session
            ?? Sessions.all.first { $0.workspace != nil }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let unit = max(0.5, min(size.width / 1920, size.height / 1080))
            let orbSide = size.height * 0.62
            let centre = CGPoint(x: size.width / 2, y: size.height * 0.45)
            ZStack {
                StageBackdrop(tint: tint, unit: unit)
                HUDRings(tint: tint, warning: theme.amber.color, alarm: theme.red.color, faint: theme.text3.color,
                         intensity: model.vitality.intensity, usage: model.windowShare, unit: unit)
                    .frame(width: orbSide * HUDRings.frameScale, height: orbSide * HUDRings.frameScale)
                    .position(centre)
                // The large orb sits 8% of its frame below the frame's centre, to leave room
                // for its flames; lift the frame so the orb itself is in the rings.
                OrbRepresentable(size: .large)
                    .frame(width: orbSide, height: orbSide)
                    .position(x: centre.x, y: centre.y - orbSide * 0.08)
                StageCorners()
                    .stroke(theme.line2.color, lineWidth: 1.5)
                    .padding(28 * unit)
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        identity(unit)
                        Spacer(minLength: 40)
                        clock(unit)
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom) {
                        projects(unit)
                            .frame(width: 440 * unit, alignment: .leading)
                        Spacer(minLength: 24)
                        caption(unit)
                            .frame(maxWidth: 900 * unit)
                        Spacer(minLength: 24)
                        agents(unit)
                            .frame(width: 440 * unit, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 72 * unit)
                .padding(.vertical, 64 * unit)
            }
        }
        .background(theme.ground.color)
        .ignoresSafeArea()
        .task {
            let ledger = AgentLedger.standard
            while !Task.isCancelled {
                let start = Calendar.current.startOfDay(for: .now)
                tally = await Task.detached(priority: .utility) { StageTally(jobs: ledger.jobs(since: start), since: start) }.value
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var tint: Color { color(model.mood) }

    private func color(_ mood: PresenceMood) -> Color {
        switch mood {
        case .needsYou: theme.amber.color
        case .done: theme.green.color
        case .trouble: theme.red.color
        case .asleep: theme.text3.color
        case .idle, .thinking, .acting, .listening: theme.accent.color
        }
    }

    // MARK: Corners

    private func identity(_ unit: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8 * unit) {
            HStack(spacing: 10 * unit) {
                ClaudeSparkIcon(size: 22 * unit, isWorking: model.mood == .acting || model.mood == .thinking)
                Text("DANTE")
                    .font(.dante(size: 15 * unit, weight: .semibold))
                    .tracking(6 * unit)
                    .foregroundStyle(theme.text3.color)
            }
            Text(model.mood.title)
                .font(.dante(size: 52 * unit, weight: .semibold))
                .foregroundStyle(theme.text.color)
                .contentTransition(.opacity)
            Text(model.presence.line)
                .font(.dante(size: 21 * unit))
                .foregroundStyle(theme.text2.color)
                .lineLimit(2)
                .frame(maxWidth: 560 * unit, alignment: .leading)
        }
        .animation(.easeOut(duration: 0.4), value: model.mood)
    }

    private func clock(_ unit: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 6 * unit) {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .trailing, spacing: 4 * unit) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.dante(size: 64 * unit, weight: .light, design: .monospaced))
                        .foregroundStyle(theme.text.color)
                    Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.dante(size: 19 * unit))
                        .foregroundStyle(theme.text2.color)
                }
            }
            if let share = model.windowShare {
                let resets = model.usageResets.map { " · resets \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
                Text("Usage \(Int((share * 100).rounded()))% of your busiest window\(resets)")
                    .font(.dante(size: 15 * unit))
                    .foregroundStyle(share > 0.85 ? theme.amber.color : theme.text3.color)
            }
        }
    }

    private func heading(_ title: String, _ unit: CGFloat) -> some View {
        Text(title)
            .font(.dante(size: 13 * unit, weight: .semibold))
            .tracking(4 * unit)
            .foregroundStyle(theme.text3.color)
    }

    private func projects(_ unit: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14 * unit) {
            heading("PROJECTS", unit)
            if model.presence.sources.isEmpty {
                Text("No project open")
                    .font(.dante(size: 18 * unit))
                    .foregroundStyle(theme.text3.color)
            }
            ForEach(model.presence.sources.prefix(5)) { source in
                HStack(alignment: .firstTextBaseline, spacing: 12 * unit) {
                    Circle()
                        .fill(color(source.mood))
                        .frame(width: 10 * unit, height: 10 * unit)
                    VStack(alignment: .leading, spacing: 2 * unit) {
                        Text(source.project)
                            .font(.dante(size: 20 * unit, weight: .medium))
                            .foregroundStyle(theme.text.color)
                        Text(source.status)
                            .font(.dante(size: 15 * unit))
                            .foregroundStyle(theme.text3.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func agents(_ unit: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 14 * unit) {
            heading("AGENTS", unit)
            if model.satellites.isEmpty {
                Text("Claude is working alone")
                    .font(.dante(size: 18 * unit))
                    .foregroundStyle(theme.text3.color)
            }
            ForEach(model.satellites.prefix(Constellation.limit)) { satellite in
                HStack(spacing: 12 * unit) {
                    Text(satellite.title)
                        .font(.dante(size: 18 * unit, weight: .medium))
                        .foregroundStyle(theme.text.color)
                        .lineLimit(1)
                    if case .local = satellite.kind {
                        Text("on this Mac")
                            .font(.dante(size: 14 * unit))
                            .foregroundStyle(theme.text3.color)
                    }
                    Circle()
                        .fill(satellite.color.color)
                        .frame(width: 10 * unit, height: 10 * unit)
                        .shadow(color: satellite.color.color, radius: 6 * unit)
                }
            }
            if tally.localJobs + tally.claudeJobs > 0 {
                VStack(alignment: .trailing, spacing: 4 * unit) {
                    Text("Today: \(tally.localJobs) on this Mac · \(tally.claudeJobs) with Claude")
                    if tally.tokensKeptLocal > 0 {
                        Text("\(tally.tokensKeptLocal.formatted(.number.notation(.compactName))) tokens kept local")
                    }
                }
                .font(.dante(size: 15 * unit))
                .foregroundStyle(theme.text3.color)
                .padding(.top, 6 * unit)
            }
        }
    }

    // MARK: The caption

    private func caption(_ unit: CGFloat) -> some View {
        let voice = VoiceController.shared
        return VStack(spacing: 18 * unit) {
            if voice.state == .listening {
                HStack(spacing: 14 * unit) {
                    VoiceLevel(level: voice.level, tint: tint, unit: unit)
                    Text(voice.heard.isEmpty ? "Listening…" : "“\(voice.heard)”")
                        .font(.dante(size: 30 * unit, weight: .medium))
                        .foregroundStyle(theme.text.color)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            } else if let session = Self.waitingSession, let claude = session.claude, let tool = claude.pendingApprovals.first {
                let what = [tool.verb, tool.target(in: session.workspace?.url ?? claude.root)].filter { !$0.isEmpty }.joined(separator: " ")
                VStack(spacing: 16 * unit) {
                    Text("Claude wants to \(what.prefix(1).lowercased() + what.dropFirst())")
                        .font(.dante(size: 28 * unit, weight: .medium))
                        .foregroundStyle(theme.text.color)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    HStack(spacing: 14 * unit) {
                        Button("Decline") { for tool in claude.pendingApprovals { claude.decline(tool.id) } }
                            .buttonStyle(StageButtonStyle(unit: unit))
                        Button("Approve  ⏎") { for tool in claude.pendingApprovals { claude.approve(tool.id) } }
                            .buttonStyle(StageButtonStyle(primary: true, unit: unit))
                    }
                }
            } else if let line = spokenLine {
                Text(line)
                    .font(.dante(size: 26 * unit))
                    .foregroundStyle(theme.text.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .id(line)
                    .transition(.opacity)
            }
            Text("Space to talk · Esc to leave")
                .font(.dante(size: 14 * unit))
                .tracking(1 * unit)
                .foregroundStyle(theme.text3.color)
        }
        .animation(.easeOut(duration: 0.25), value: spokenLine)
        .animation(.easeOut(duration: 0.25), value: voice.state)
    }

    /// The end of Claude's latest words in the project followed, or what it's running.
    private var spokenLine: String? {
        guard let claude = focus?.claude else { return nil }
        let reply = claude.items.last { if case .assistant = $0.content { true } else { false } }
        if case .assistant(let text)? = reply?.content, !text.isEmpty { return StageCaption.tail(of: text) }
        return nil
    }
}

/// The voice's loudness as five bars.
private struct VoiceLevel: View {
    var level: Double
    var tint: Color
    var unit: CGFloat

    var body: some View {
        HStack(spacing: 4 * unit) {
            ForEach(0..<5, id: \.self) { index in
                let weight = [0.5, 0.8, 1, 0.8, 0.5][index]
                Capsule()
                    .fill(tint)
                    .frame(width: 5 * unit, height: (8 + 34 * level * weight) * unit)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

private struct StageButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var primary = false
    var unit: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dante(size: 19 * unit, weight: .semibold))
            .foregroundStyle(primary ? theme.onAccent.color : theme.text.color)
            .padding(.horizontal, 28 * unit)
            .padding(.vertical, 12 * unit)
            .background(primary ? theme.accent.color : theme.raised.color, in: Capsule())
            .overlay(Capsule().strokeBorder(primary ? theme.accent.color : theme.line2.color))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: Decoration

/// A glow behind the orb and a faint grid fading out towards the edges.
private struct StageBackdrop: View {
    @Environment(\.theme) private var theme
    var tint: Color
    var unit: CGFloat

    var body: some View {
        ZStack {
            theme.ground.color
            Canvas { context, size in
                let step = 64 * unit
                var grid = Path()
                var x: CGFloat = size.width / 2 - (size.width / 2 / step).rounded(.down) * step
                while x < size.width {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                var y: CGFloat = size.height * 0.45 - (size.height * 0.45 / step).rounded(.down) * step
                while y < size.height {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                context.stroke(grid, with: .color(theme.line.color), lineWidth: 1)
            }
            .mask(RadialGradient(colors: [.white.opacity(0.9), .clear], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 900 * unit))
            RadialGradient(colors: [tint.opacity(0.16), .clear], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: 620 * unit)
                .animation(.easeInOut(duration: 1.2), value: tint)
        }
    }
}

/// Brackets in the four corners, like a viewfinder.
private struct StageCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * 0.05
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
        }
        return path
    }
}

/// The rings around the orb: a turning scale, counter-turning arcs, a radar sweep that
/// speeds up with the work, and two gauges: load on the left, the usage window on the right.
private struct HUDRings: View {
    var tint: Color
    var warning: Color
    var alarm: Color
    var faint: Color
    var intensity: Double
    var usage: Double?
    var unit: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The rings' outer edge is this share of the frame's half-width; the gauges and their
    /// labels sit outside it, still inside the frame (a Canvas clips to its frame).
    static let ringShare: CGFloat = 0.74
    /// The frame for an orb of side 1: its outer ring just clears the satellites' orbits.
    static let frameScale: CGFloat = 1.06 / ringShare

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(in: &context, size: size, t: t)
            }
        }
    }

    private func point(_ centre: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
    }

    private func arc(_ centre: CGPoint, _ radius: CGFloat, from start: Double, to end: Double) -> Path {
        var path = Path()
        path.addArc(center: centre, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        return path
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, t: Double) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = min(size.width, size.height) / 2 * Self.ringShare
        let work = min(1, max(0, intensity))

        // The scale: 180 ticks, every fifteenth long, turning slowly (faster with work).
        let spin = t * (0.03 + 0.12 * work)
        var minor = Path(), major = Path()
        for index in 0..<180 {
            let angle = Double(index) / 180 * 2 * .pi + spin
            let long = index % 15 == 0
            if long {
                major.move(to: point(centre, r * 0.925, angle))
                major.addLine(to: point(centre, r * 0.975, angle))
            } else {
                minor.move(to: point(centre, r * 0.952, angle))
                minor.addLine(to: point(centre, r * 0.975, angle))
            }
        }
        context.stroke(minor, with: .color(tint.opacity(0.25)), lineWidth: max(1, 1 * unit))
        context.stroke(major, with: .color(tint.opacity(0.7)), lineWidth: max(1.5, 2 * unit))
        context.stroke(arc(centre, r * 0.995, from: 0, to: 2 * .pi), with: .color(tint.opacity(0.12)), lineWidth: 1)

        // Counter-turning arcs.
        let counter = -t * (0.08 + 0.3 * work)
        for index in 0..<3 {
            let start = counter + Double(index) * 2 * .pi / 3
            context.stroke(arc(centre, r * 0.885, from: start, to: start + 1.25),
                           with: .color(tint.opacity(0.5)), style: StrokeStyle(lineWidth: max(2, 3 * unit), lineCap: .round))
        }
        context.stroke(arc(centre, r * 0.86, from: 0, to: 2 * .pi), with: .color(tint.opacity(0.1)), lineWidth: 1)

        // The sweep: a fading wedge, like radar.
        let sweep = t * (0.5 + 1.8 * work)
        let slices = 28
        let span = 0.9
        for index in 0..<slices {
            let a0 = sweep - span * Double(index + 1) / Double(slices)
            let a1 = sweep - span * Double(index) / Double(slices)
            var wedge = Path()
            wedge.addArc(center: centre, radius: r * 0.905, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            wedge.addArc(center: centre, radius: r * 0.865, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
            wedge.closeSubpath()
            context.fill(wedge, with: .color(tint.opacity(0.32 * (1 - Double(index) / Double(slices)))))
        }

        // Gauges: load on the left, the usage window on the right, each a 100° arc.
        gauge(&context, centre: centre, radius: r * 1.06, middle: .pi, value: work, color: tint, label: "LOAD", mirrored: true)
        if let usage {
            let color = usage > 0.95 ? alarm : usage > 0.8 ? warning : tint
            gauge(&context, centre: centre, radius: r * 1.06, middle: 0, value: min(1, usage), color: color, label: "USAGE", mirrored: false)
        }
    }

    private func gauge(_ context: inout GraphicsContext, centre: CGPoint, radius: CGFloat, middle: Double, value: Double,
                       color: Color, label: String, mirrored: Bool) {
        let half = 50 * Double.pi / 180
        // Both fill upwards from the bottom of their arc.
        let bottom = mirrored ? middle - half : middle + half
        let top = mirrored ? middle + half : middle - half
        let track = arc(centre, radius, from: min(bottom, top), to: max(bottom, top))
        context.stroke(track, with: .color(faint.opacity(0.25)), style: StrokeStyle(lineWidth: max(3, 5 * unit), lineCap: .round))
        if value > 0.005 {
            let end = bottom + (top - bottom) * value
            let fill = arc(centre, radius, from: min(bottom, end), to: max(bottom, end))
            context.stroke(fill, with: .color(color), style: StrokeStyle(lineWidth: max(3, 5 * unit), lineCap: .round))
        }
        let text = Text("\(label) \(Int((value * 100).rounded()))%")
            .font(.dante(size: 12 * unit, weight: .semibold))
            .tracking(2 * unit)
            .foregroundStyle(color.opacity(0.85))
        let at = point(centre, radius + 26 * unit, top + (mirrored ? 0.12 : -0.12))
        context.draw(text, at: at, anchor: mirrored ? .trailing : .leading)
    }
}
