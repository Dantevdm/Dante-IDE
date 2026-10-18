import AppKit
import DanteKit
import Observation
import SwiftUI

/// What the presence panel shows; the controller keeps it current.
@MainActor
@Observable
final class PresenceModel {
    var presence = Presence.combine([])
    var mood: PresenceMood = .asleep
    var vitality = Vitality()
    /// Sub-agents and local models working now, circling the orb.
    var satellites: [OrbSatellite] = []
    /// The five-hour window so far against the busiest one seen (1 = as busy), when known.
    var windowShare: Double?
    var usageResets: Date?
}

/// Claude's presence in the menu bar: an orb that shows, across every window, whether Claude
/// is resting, thinking, working, waiting for you, finished or in trouble. A click opens a
/// panel with a bigger orb and each project's state; a right click offers to hide it.
@MainActor
final class PresenceController: NSObject {
    static let shared = PresenceController()

    let model = PresenceModel()
    private var statusItem: NSStatusItem?
    private var orb: OrbView?
    private var popover: NSPopover?
    private var tracker = PresenceTracker()
    private var recheck: Timer?
    private var observing = false
    private var pending = false
    private var sessions: [String: Session] = [:]
    private var workRate = WorkRate()
    /// The five-hour window's tiredness, refreshed every couple of minutes and after turns.
    private var fatigue: Double = 0
    private var usageResets: Date?
    private var usageLoaded: Date = .distantPast
    private var loadingUsage = false
    private var vitalityTimer: Timer?
    /// Orbs showing the mood: the menu bar's, the panel's and the Stage's.
    private let watchers = NSHashTable<OrbView>.weakObjects()
    weak var themeStore: ThemeStore?

    /// Called once at launch. Shows or hides the item as the preference changes.
    func install() {
        guard !observing else { return }
        observing = true
        update()
    }

    /// A window opened, closed, or changed project.
    func sessionsChanged() { scheduleUpdate() }

    /// The voice controller started or stopped listening, or the voice got louder.
    func voiceChanged() { scheduleUpdate() }

    /// Registers an orb to show the current mood.
    func attach(_ orb: OrbView) {
        watchers.add(orb)
        orb.mood = model.mood
        orb.vitality = model.vitality
        orb.satellites = model.satellites
    }

    // MARK: Observing the sessions

    private func scheduleUpdate() {
        guard !pending else { return }
        pending = true
        // Coalesced: transcripts change with every streamed word.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = false
                self?.update()
            }
        }
    }

    private func update() {
        let (presence, shows, work) = withObservationTracking {
            (Presence.combine(currentSources()), Preferences.shared.showsPresence, currentWork())
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleUpdate() }
        }
        setVisible(shows)
        let now = Date()
        workRate.record(total: work.tools, at: now)
        let vitality = Vitality(intensity: workRate.intensity(at: now, running: work.running), fatigue: fatigue,
                                exhaustedUntil: work.limitAt.map { usageResets.flatMap { $0 > now ? $0 : nil } ?? $0.addingTimeInterval(3600) })
        apply(vitality.isExhausted(at: now) ? Self.sleeping(presence, until: vitality.exhaustedUntil) : presence, vitality: vitality)
        if model.satellites != work.satellites {
            model.satellites = work.satellites
            for orb in watchers.allObjects { orb.satellites = work.satellites }
        }
        refreshUsageIfDue(now: now)
    }

    /// Out of usage: asleep, saying when it wakes.
    private static func sleeping(_ presence: Presence, until: Date?) -> Presence {
        let time = until.map { " · back at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return Presence(mood: .asleep, line: "Out of Claude usage" + time, sources: presence.sources)
    }

    /// Tool calls made so far, what's running now (sub-agents count double), any usage limit
    /// hit, and the sub-agents and local models at work.
    private func currentWork() -> (tools: Int, running: Int, limitAt: Date?, satellites: [OrbSatellite]) {
        var tools = 0, running = 0
        var limitAt: Date?
        var satellites: [OrbSatellite] = []
        for claude in Sessions.all.flatMap(\.allConversations) {
            if let at = claude.limitReachedAt { limitAt = max(limitAt ?? at, at) }
            for item in claude.items {
                guard case .tool(let tool) = item.content else { continue }
                tools += 1
                if tool.status == .running { running += tool.name == "Task" || tool.name == "Agent" ? 2 : 1 }
            }
            if claude.state == .working {
                satellites += OrbSatellite.running(in: claude.items.compactMap { item -> ToolActivity? in if case .tool(let tool) = item.content { tool } else { nil } })
            }
        }
        return (tools, running, limitAt, satellites)
    }

    private func refreshUsageIfDue(now: Date) {
        let due = now.timeIntervalSince(usageLoaded) > 120 || model.mood == .done && now.timeIntervalSince(usageLoaded) > 20
        guard due, !loadingUsage else { return }
        loadingUsage = true
        Task { [weak self] in
            let usage = await Task.detached(priority: .utility) { ClaudeUsage.load() }.value
            guard let self else { return }
            self.loadingUsage = false
            self.usageLoaded = Date()
            let current = usage.current?.usage.weighted ?? 0
            self.fatigue = Vitality.fatigue(current: current, busiest: usage.busiestWindow?.weighted)
            self.usageResets = usage.current?.resets
            self.model.windowShare = usage.busiestWindow.flatMap { $0.weighted > 0 ? Double(current) / Double($0.weighted) : nil }
            self.model.usageResets = usage.current?.resets
            self.scheduleUpdate()
        }
    }

    private func currentSources() -> [PresenceSource] {
        var sources: [PresenceSource] = []
        var byID: [String: Session] = [:]
        for session in Sessions.all {
            for source in session.presenceSources {
                sources.append(source)
                byID[source.id] = session
            }
        }
        sessions = byID
        return sources
    }

    private func apply(_ presence: Presence, vitality: Vitality) {
        var presence = presence
        var vitality = vitality
        // While you speak, the orb listens: it brightens and swells with your voice.
        let voice = VoiceController.shared
        if voice.state == .listening {
            presence = Presence(mood: .listening, line: voice.heard.isEmpty ? "Go ahead" : "“\(voice.heard)”", sources: presence.sources)
            vitality.intensity = voice.level
            vitality.fatigue = 0
        } else if voice.isSpeaking {
            // While Dante reads a reply out, the orb pulses with each word.
            vitality.intensity = max(vitality.intensity, voice.level)
        }
        model.presence = presence
        if model.vitality != vitality { model.vitality = vitality }
        for orb in watchers.allObjects { orb.vitality = vitality }
        // Intensity fades as the last minute's work ages, so look again while there's any.
        vitalityTimer?.invalidate()
        vitalityTimer = vitality.intensity > 0 ? Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        } : nil
        let (mood, until) = tracker.mood(for: presence, at: Date())
        if model.mood != mood { model.mood = mood }
        for orb in watchers.allObjects { orb.mood = mood }
        statusItem?.button?.toolTip = "\(mood.title) · \(presence.line)"
        recheck?.invalidate()
        recheck = nil
        if let until {
            recheck = Timer.scheduledTimer(withTimeInterval: max(0.05, until.timeIntervalSinceNow + 0.05), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    // MARK: The status item

    private func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusBar.system.thickness + 6)
            if let button = item.button {
                let orb = OrbView(size: .menuBar, mood: model.mood)
                orb.frame = button.bounds
                orb.autoresizingMask = [.width, .height]
                button.addSubview(orb)
                button.target = self
                button.action = #selector(clicked)
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.setAccessibilityLabel("Claude")
                attach(orb)
                orb.wake()
                self.orb = orb
            }
            statusItem = item
        } else if !visible, let item = statusItem {
            popover?.close()
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            orb = nil
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Dante", action: #selector(showDante), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let talk = NSMenuItem(title: "Talk to Claude  \(VoiceController.keyLabel)", action: #selector(talk), keyEquivalent: "")
        talk.target = self
        menu.addItem(talk)
        // The Stage, on any screen: a TV shows up here once it's connected or AirPlayed to.
        let screens = NSScreen.screens
        if screens.count > 1 {
            let stage = NSMenuItem(title: "Open Stage", action: nil, keyEquivalent: "")
            let choices = NSMenu()
            for (index, screen) in screens.enumerated() {
                let item = NSMenuItem(title: "On \(screen.localizedName)", action: #selector(openStageOnScreen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                choices.addItem(item)
            }
            stage.submenu = choices
            menu.addItem(stage)
        } else {
            let stage = NSMenuItem(title: StageController.shared.isOpen ? "Leave Stage" : "Open Stage", action: #selector(toggleStage), keyEquivalent: "")
            stage.target = self
            menu.addItem(stage)
        }
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide from Menu Bar", action: #selector(hide), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(NSMenuItem(title: "Quit Dante", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func hide() { Preferences.shared.showsPresence = false }

    @objc private func talk() { VoiceController.shared.toggle() }

    @objc private func toggleStage() { StageController.shared.toggle() }

    @objc private func openStageOnScreen(_ item: NSMenuItem) {
        let screens = NSScreen.screens
        guard screens.indices.contains(item.tag) else { return }
        StageController.shared.close()
        StageController.shared.open(on: screens[item.tag])
    }

    @objc private func showDante() {
        NSApp.activate()
        (Sessions.all.first { $0.window?.isKeyWindow == true } ?? Sessions.all.first)?.window?.makeKeyAndOrderFront(nil)
    }

    private func togglePanel() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let theme = themeStore?.theme ?? ThemeID.dark.theme
        popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        popover.contentViewController = NSHostingController(rootView:
            PresencePanel(model: model, controller: self)
                .environment(\.theme, theme)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
    }

    // MARK: Actions from the panel

    /// The panel's orb was clicked: go full screen.
    func openStage() {
        popover?.performClose(nil)
        StageController.shared.open()
    }

    func show(_ id: String) {
        popover?.performClose(nil)
        guard let session = sessions[id] else { return showDante() }
        // A job's source id is the window's, a slash, and the job's.
        let job = id.split(separator: "/").dropFirst().first.map(String.init)
        session.showJob(job)
        NSApp.activate()
        session.window?.makeKeyAndOrderFront(nil)
    }

    func stop(_ id: String) {
        guard let session = sessions[id] else { return }
        if let job = id.split(separator: "/").dropFirst().first.map(String.init) {
            session.jobs.sessions[job]?.interrupt()
        } else {
            session.claude?.interrupt()
        }
    }
}

extension Session {
    /// The main conversation and every running job's.
    var allConversations: [ClaudeSession] {
        (claude.map { [$0] } ?? []) + jobs.open.compactMap { jobs.sessions[$0.id] }
    }

    /// The window's conversation and each live job's, for the orb.
    var presenceSources: [PresenceSource] {
        guard let main = presenceSource, let workspace else { return [] }
        return [main] + jobs.open.compactMap { job in
            jobs.sessions[job.id].map { Self.presenceSource(for: $0, id: "\(main.id)/\(job.id)", project: "\(workspace.name) · \(job.title)", root: job.worktreeURL) }
        }
    }

    /// This window's Claude session, for the orb. Nil before a folder is open.
    var presenceSource: PresenceSource? {
        guard let workspace else { return nil }
        let id = String(UInt(bitPattern: ObjectIdentifier(self).hashValue), radix: 36)
        guard let claude else { return PresenceSource(id: id, project: workspace.name, claude: .off) }
        return Self.presenceSource(for: claude, id: id, project: workspace.name, root: workspace.url)
    }

    private static func presenceSource(for claude: ClaudeSession, id: String, project: String, root: URL) -> PresenceSource {
        let state: PresenceSource.Claude = switch claude.state {
        case .idle: .idle
        case .working: .working
        case .unavailable(let reason): .unavailable(reason)
        }
        var running: String?
        var last: String?
        var waiting = 0
        for item in claude.items.reversed() {
            guard case .tool(let tool) = item.content else { continue }
            let line = [tool.verb, tool.target(in: root)].filter { !$0.isEmpty }.joined(separator: " ")
            if tool.isAwaitingApproval {
                waiting += 1
                if waiting == 1 { last = line }
            }
            if last == nil { last = line }
            if running == nil, tool.status == .running { running = line }
            if waiting == 0, last != nil, running != nil || claude.state != .working { break }
        }
        return PresenceSource(id: id, project: project, claude: state, waiting: waiting, running: running, last: last)
    }
}
