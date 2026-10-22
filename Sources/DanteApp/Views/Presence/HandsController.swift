import AppKit
import Carbon.HIToolbox
import DanteKit
import SwiftUI

/// Hands' kill switch, always within reach: a badge floats at the top of the screen whenever the
/// agent has used Hands in the last 20 seconds, with Stop; ⌃⌥⌘. stops it from anywhere, badge or
/// not. Stopping writes `Hands.stopFlag` (the MCP server checks it before each step, and while
/// typing), turns Hands off and stops every conversation that was using them.
@MainActor @Observable
final class HandsController {
    static let shared = HandsController()

    /// Who's using them, for the badge.
    private(set) var agent = "Claude"
    private(set) var lastStep = ""
    private(set) var visible = false

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private weak var users: ClaudeSession?

    static let shortcut = "⌃⌥⌘."
    private static let signature = OSType(0x48414E44) // "HAND"

    func install() {
        // The flag follows the setting, so a server started before a crash or a restart obeys it.
        if Preferences.shared.handsEnabled { Hands.allow() } else { Hands.stop() }
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == HandsController.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { HandsController.shared.stop() } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_Period), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
        // DANTE_HANDS_DEMO=1 shows the badge, to check it without an agent at the keyboard.
        if ProcessInfo.processInfo.environment["DANTE_HANDS_DEMO"] == "1" {
            noteUse(by: "Claude", step: Hands.Tool.typeText.describe(["text": "Meeting notes for Thursday"], done: true), in: nil)
        }
    }

    func setEnabled(_ on: Bool) {
        Preferences.shared.handsEnabled = on
        if on { Hands.allow() } else { Hands.stop() }
        // The MCP server's tools change, so each conversation starts again on its next message.
        Sessions.all.forEach { $0.applyClaudePreferences() }
    }

    /// The agent used (or asks to use) Hands: show the badge.
    func noteUse(by agent: String, step: String, in conversation: ClaudeSession?) {
        self.agent = agent
        lastStep = step
        users = conversation
        show()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// The kill switch.
    func stop() {
        Hands.stop()
        Preferences.shared.handsEnabled = false
        users?.interrupt()
        for session in Sessions.all {
            if let claude = session.claude, claude.state == .working, claude.items.suffix(12).contains(where: Self.usesHands) {
                claude.interrupt()
            }
            session.applyClaudePreferences()
        }
        users = nil
        hideTask?.cancel()
        hide()
        NSSound(named: "Funk")?.play()
    }

    private static func usesHands(_ item: TranscriptItem) -> Bool {
        if case .tool(let tool) = item.content { return Hands.Tool.of(mcpName: tool.name) != nil }
        return false
    }

    // MARK: Badge

    private func show() {
        visible = true
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func hide() {
        visible = false
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 52), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        let theme = PresenceController.shared.themeStore?.theme ?? ThemeID.light.theme
        panel.contentView = NSHostingView(rootView: HandsBadge(controller: self).environment(\.theme, theme))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 10))
    }
}

/// "Claude is using your Mac · Typed “hello” · Stop (⌃⌥⌘.)".
private struct HandsBadge: View {
    @Environment(\.theme) private var theme
    let controller: HandsController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.dante(size: 15, weight: .semibold))
                .foregroundStyle(theme.amber.color)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(controller.agent) is using your Mac").font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color)
                Text(controller.lastStep).font(.dante(size: 11)).foregroundStyle(theme.text2.color).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { controller.stop() } label: {
                Text("Stop  \(HandsController.shortcut)").font(.dante(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(theme.red.color))
                    .foregroundStyle(theme.onAccent.color)
            }
            .buttonStyle(.plain)
            .help("Stops Hands at once and turns them off; turn them on again in Settings › Agents.")
        }
        .padding(.horizontal, 14)
        .frame(width: 420, height: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.amber.color.opacity(0.7), lineWidth: 1.5))
    }
}
