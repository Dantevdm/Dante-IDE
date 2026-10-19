import AppKit
import DanteKit
import SwiftUI

/// The Stage: Dante full screen, Jarvis style, for this display, a second one or a TV, or
/// in a window of any size beside your work. The orb in the middle inside turning HUD rings,
/// lines to each agent it has handed work to, what Claude is saying under it, and the
/// projects and agents at the sides. Opened from the panel's orb, the menu bar menu, or by
/// voice ("full screen"); Esc leaves full screen for the window, and closes the window.
@MainActor
final class StageController: NSObject, NSWindowDelegate {
    static let shared = StageController()

    /// What the Stage's own controls show.
    @MainActor @Observable
    final class Mode {
        var fullScreen = true
        /// Kept above other windows while it's a window.
        var floats = UserDefaults.standard.bool(forKey: "stageFloats") {
            didSet {
                UserDefaults.standard.set(floats, forKey: "stageFloats")
                StageController.shared.applyLevel()
            }
        }
    }

    let mode = Mode()
    private var window: StageWindow?
    private var activity: NSObjectProtocol?
    private var keys: Any?
    private var cursorTimer: Timer?
    private var lastPointer = NSPoint.zero
    private var pointerStill: Date = .now
    private var closing = false
    private static let windowedKey = "stageWindowed"
    private static let frameKey = "stageFrame"

    var isOpen: Bool { window != nil }

    func toggle() { isOpen ? close() : open() }

    /// Opens on `screen`, else the one the pointer is on (where you just clicked); full screen
    /// or in a window as asked, else as it was last time.
    func open(on screen: NSScreen? = nil, fullScreen: Bool? = nil) {
        NSApp.activate()
        let wantsFullScreen = fullScreen ?? !UserDefaults.standard.bool(forKey: Self.windowedKey)
        if let window {
            window.makeKeyAndOrderFront(nil)
            if fullScreen != nil, wantsFullScreen != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            return
        }
        let pointer = NSEvent.mouseLocation
        let asked = screen != nil
        guard let screen = screen ?? NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        let window = StageWindow(contentRect: screen.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false, screen: screen)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.dark.ground.nsColor
        window.minSize = NSSize(width: 300, height: 420)
        window.title = "Stage"
        window.contentView = NSHostingView(rootView:
            StageView(model: PresenceController.shared.model, mode: mode)
                .environment(\.theme, Theme.dark)
        )
        window.setFrame(windowFrame(on: screen, chosen: asked), display: false)
        window.delegate = self
        self.window = window
        closing = false
        mode.fullScreen = false
        window.makeKeyAndOrderFront(nil)
        if wantsFullScreen {
            window.toggleFullScreen(nil)
        } else {
            applyLevel()
        }

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

    /// Where the window goes: where it was last time, else a tall window down the right of
    /// the screen, beside whatever you're working on.
    private func windowFrame(on screen: NSScreen, chosen: Bool) -> NSRect {
        if !chosen, let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            if frame.width >= 300, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return frame }
        }
        let visible = screen.visibleFrame
        let width = min(520, visible.width * 0.4), height = visible.height * 0.92
        return NSRect(x: visible.maxX - width - 24, y: visible.midY - height / 2, width: width, height: height)
    }

    /// Full screen, or back to the window.
    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
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

    fileprivate func applyLevel() {
        guard let window else { return }
        window.level = mode.floats && !mode.fullScreen ? .floating : .normal
    }

    /// Esc leaves full screen (and closes the window), Space talks, Return approves what's waiting.
    private func handle(key: UInt16, window number: Int) -> Bool {
        guard let window, window.windowNumber == number else { return false }
        switch Int(key) {
        case 53:
            if window.styleMask.contains(.fullScreen) { toggleFullScreen() } else { close() }
        case 49:
            VoiceController.shared.toggle()
        case 36, 76:
            guard let claude = StageView.waitingSession?.waitingConversation?.claude else { return false }
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
        } else if Date.now.timeIntervalSince(pointerStill) > 3, window?.isKeyWindow == true, mode.fullScreen {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        mode.fullScreen = true
        UserDefaults.standard.set(false, forKey: Self.windowedKey)
        applyLevel()
        // A TV shouldn't go to sleep under it.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Showing the Stage")
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if closing { return finish() }
        mode.fullScreen = false
        UserDefaults.standard.set(true, forKey: Self.windowedKey)
        endActivity()
        applyLevel()
    }

    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let window, !window.styleMask.contains(.fullScreen), !mode.fullScreen else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    func windowWillClose(_ notification: Notification) { tearDown() }

    private func finish() {
        window?.orderOut(nil)
        tearDown()
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func tearDown() {
        endActivity()
        if let keys { NSEvent.removeMonitor(keys) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: PresenceModel
    var mode: StageController.Mode
    @State private var tally = StageTally()
    @State private var track = SatelliteTrack()

    /// The window with something waiting for an answer, if any.
    @MainActor static var waitingSession: Session? {
        Sessions.all.first { $0.waitingConversation != nil }
    }

    /// The project the caption follows: one waiting, else one working, else the frontmost.
    private var focus: Session? {
        Self.waitingSession
            ?? Sessions.all.first { $0.claude?.state == .working }
            ?? ActiveProject.shared.session
            ?? Sessions.all.first { $0.workspace != nil }
    }

    /// Sizes for the Stage at any size: wide (a screen, a TV) with the projects and agents
    /// either side, or narrow (a window beside your work) with everything stacked.
    struct Layout {
        var unit: CGFloat
        var orbSide: CGFloat
        var centre: CGPoint
        var compact: Bool

        init(_ size: CGSize) {
            compact = size.width < max(980, size.height * 1.3)
            if compact {
                unit = max(0.45, min(size.width / 620, size.height / 1000))
                orbSide = max(120, min(size.width * 0.6, size.height * 0.4))
                // Below the heading, which is about 150 units tall plus the title bar.
                centre = CGPoint(x: size.width / 2, y: 36 + 150 * unit + orbSide * 0.62)
            } else {
                unit = max(0.5, min(size.width / 1920, size.height / 1080))
                orbSide = size.height * 0.62
                centre = CGPoint(x: size.width / 2, y: size.height * 0.45)
            }
        }

        /// The rings' outer edge, just clear of the satellites' orbits.
        var ringRadius: CGFloat { orbSide * 0.53 }
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(geometry.size)
            let unit = layout.unit
            ZStack {
                StageBackdrop(tint: tint, centre: UnitPoint(x: 0.5, y: layout.centre.y / max(1, geometry.size.height)), unit: unit)
                // The large orb sits 8% of its frame below the frame's centre, to leave room
                // for its flames; lift the frame so the orb itself is in the rings.
                OrbRepresentable(size: .large, framesPerSecond: 120, track: track)
                    .frame(width: layout.orbSide, height: layout.orbSide)
                    .position(x: layout.centre.x, y: layout.centre.y - layout.orbSide * 0.08)
                StageHUD(style: hudStyle, intensity: model.vitality.intensity, usage: model.windowShare, unit: unit,
                         centre: layout.centre, orbScale: layout.orbSide / 2, ringRadius: layout.ringRadius,
                         callouts: !layout.compact, track: track, reduceMotion: reduceMotion)
                    .allowsHitTesting(false)
                if mode.fullScreen {
                    StageCorners()
                        .stroke(theme.line2.color, lineWidth: 1.5)
                        .padding(28 * unit)
                }
                if layout.compact {
                    compact(layout)
                } else {
                    wide(unit)
                }
                // In the title bar's row, level with the window's own buttons.
                if !mode.fullScreen {
                    windowControls
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
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

    private func wide(_ unit: CGFloat) -> some View {
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

    /// A narrow window: the mood and time on top, the orb, then what's said and who's working.
    private func compact(_ layout: Layout) -> some View {
        let unit = layout.unit
        return VStack(spacing: 0) {
            HStack(alignment: .top) {
                identity(unit)
                Spacer(minLength: 12)
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.dante(size: 40 * unit, weight: .light, design: .monospaced))
                        .foregroundStyle(theme.text.color)
                }
            }
            Spacer(minLength: layout.ringRadius * 2.2)
            caption(unit)
            flows(unit)
                .padding(.top, 22 * unit)
            Spacer(minLength: 0)
            projects(unit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28 * unit)
        .padding(.top, 36 + 12 * unit)
        .padding(.bottom, 24 * unit)
    }

    /// Who handed what to whom, as a list, for a window too narrow for the lines.
    private func flows(_ unit: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * unit) {
            ForEach(model.satellites.prefix(Constellation.limit)) { satellite in
                HStack(alignment: .firstTextBaseline, spacing: 10 * unit) {
                    Circle()
                        .fill(satellite.color.color)
                        .frame(width: 9 * unit, height: 9 * unit)
                        .shadow(color: satellite.color.color, radius: 5 * unit)
                    VStack(alignment: .leading, spacing: 2 * unit) {
                        Text("\(satellite.lead) → \(satellite.agent)".uppercased())
                            .font(.dante(size: 12.5 * unit, weight: .semibold))
                            .tracking(2 * unit)
                            .foregroundStyle(satellite.color.color)
                        if !satellite.task.isEmpty {
                            Text(satellite.task)
                                .font(.dante(size: 16 * unit))
                                .foregroundStyle(theme.text2.color)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.35), value: model.satellites.map(\.id))
    }

    /// Keep on top and full screen, for the Stage in a window.
    private var windowControls: some View {
        HStack(spacing: 4) {
            Button { mode.floats.toggle() } label: {
                Image(systemName: mode.floats ? "pin.fill" : "pin")
                    .frame(width: 26, height: 22)
            }
            .help(mode.floats ? "Stop keeping the Stage above other windows" : "Keep the Stage above other windows")
            Button { StageController.shared.toggleFullScreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 26, height: 22)
            }
            .help("Full screen")
        }
        .buttonStyle(.plain)
        .font(.dante(size: 12, weight: .medium))
        .foregroundStyle(theme.text2.color)
        .padding(.top, 3)
        .padding(.trailing, 8)
    }

    private var hudStyle: StageHUD.Style {
        StageHUD.Style(tint: nsColor(model.mood), warning: theme.amber.nsColor, alarm: theme.red.nsColor,
                       faint: theme.text3.nsColor, text: theme.text.nsColor)
    }

    private func nsColor(_ mood: PresenceMood) -> NSColor {
        switch mood {
        case .needsYou: theme.amber.nsColor
        case .done: theme.green.nsColor
        case .trouble: theme.red.nsColor
        case .asleep: theme.text3.nsColor
        case .idle, .thinking, .acting, .listening: theme.accent.nsColor
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
            } else if let waiting = Self.waitingSession?.waitingConversation, let tool = waiting.claude.pendingApprovals.first {
                let claude = waiting.claude
                let target = tool.target(in: claude.root)
                let what = [tool.verb, waiting.job.map { JobPlan.shortened(target, worktree: $0.worktree) } ?? target].filter { !$0.isEmpty }.joined(separator: " ")
                VStack(spacing: 16 * unit) {
                    if let job = waiting.job {
                        Text(job.title)
                            .font(.dante(size: 18 * unit, weight: .medium))
                            .foregroundStyle(theme.text3.color)
                            .lineLimit(1)
                    }
                    Text("\(claude.engine.title) wants to \(what.prefix(1).lowercased() + what.dropFirst())")
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
            } else if let line = voice.saying {
                Text(line)
                    .font(.dante(size: 30 * unit, weight: .medium))
                    .foregroundStyle(theme.text.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .id(line)
                    .transition(.opacity)
            } else if let line = spokenLine {
                Text(line)
                    .font(.dante(size: 26 * unit))
                    .foregroundStyle(theme.text.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .id(line)
                    .transition(.opacity)
            }
            Text((voice.wakeListening ? "Say “Hey Dante” · " : "") + "Space to talk · " + (mode.fullScreen ? "Esc for a window" : "Esc to close"))
                .font(.dante(size: 14 * unit))
                .tracking(1 * unit)
                .foregroundStyle(theme.text3.color)
        }
        .animation(.easeOut(duration: 0.25), value: spokenLine)
        .animation(.easeOut(duration: 0.2), value: voice.saying)
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
    /// Where the orb is, for the glow and the grid's fade.
    var centre = UnitPoint(x: 0.5, y: 0.45)
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
                var y: CGFloat = size.height * centre.y - (size.height * centre.y / step).rounded(.down) * step
                while y < size.height {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                context.stroke(grid, with: .color(theme.line.color), lineWidth: 1)
            }
            .mask(RadialGradient(colors: [.white.opacity(0.9), .clear], center: centre, startRadius: 0, endRadius: 900 * unit))
            RadialGradient(colors: [tint.opacity(0.16), .clear], center: centre, startRadius: 0, endRadius: 620 * unit)
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
