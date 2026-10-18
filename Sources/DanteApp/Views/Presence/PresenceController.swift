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
    private var monitors: [Any] = []
    private var sessions: [String: Session] = [:]
    /// Orbs that follow the pointer: the menu bar's, the panel's and the Stage's.
    private let watchers = NSHashTable<OrbView>.weakObjects()
    weak var themeStore: ThemeStore?

    /// Called once at launch. Shows or hides the item as the preference changes.
    func install() {
        guard !observing else { return }
        observing = true
        update()
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    /// A window opened, closed, or changed project.
    func sessionsChanged() { scheduleUpdate() }

    /// Registers an orb to follow the pointer and show the current mood.
    func attach(_ orb: OrbView) {
        watchers.add(orb)
        orb.mood = model.mood
        orb.pointer = NSEvent.mouseLocation
    }

    private func pointerMoved() {
        let location = NSEvent.mouseLocation
        for orb in watchers.allObjects where !orb.isPaused { orb.pointer = location }
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
        let (presence, shows) = withObservationTracking {
            (Presence.combine(currentSources()), Preferences.shared.showsPresence)
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleUpdate() }
        }
        setVisible(shows)
        apply(presence)
    }

    private func currentSources() -> [PresenceSource] {
        var sources: [PresenceSource] = []
        var byID: [String: Session] = [:]
        for session in Sessions.all {
            guard let source = session.presenceSource else { continue }
            sources.append(source)
            byID[source.id] = session
        }
        sessions = byID
        return sources
    }

    private func apply(_ presence: Presence) {
        model.presence = presence
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

    func show(_ id: String) {
        popover?.performClose(nil)
        guard let session = sessions[id] else { return showDante() }
        session.showsClaude = true
        NSApp.activate()
        session.window?.makeKeyAndOrderFront(nil)
    }

    func stop(_ id: String) {
        sessions[id]?.claude?.interrupt()
    }
}

extension Session {
    /// This window's Claude session, for the orb. Nil before a folder is open.
    var presenceSource: PresenceSource? {
        guard let workspace else { return nil }
        let id = String(UInt(bitPattern: ObjectIdentifier(self).hashValue), radix: 36)
        guard let claude else { return PresenceSource(id: id, project: workspace.name, claude: .off) }
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
            let line = [tool.verb, tool.target(in: workspace.url)].filter { !$0.isEmpty }.joined(separator: " ")
            if tool.isAwaitingApproval {
                waiting += 1
                if waiting == 1 { last = line }
            }
            if last == nil { last = line }
            if running == nil, tool.status == .running { running = line }
            if waiting == 0, last != nil, running != nil || claude.state != .working { break }
        }
        return PresenceSource(id: id, project: workspace.name, claude: state, waiting: waiting, running: running, last: last)
    }
}
