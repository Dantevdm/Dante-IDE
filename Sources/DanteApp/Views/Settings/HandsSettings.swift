import ApplicationServices
import DanteKit
import SwiftUI

/// Settings › Agents › Hands: lets the agent in charge open apps, find folders and use the
/// keyboard and mouse, with the kill switch's shortcut and whether macOS lets Dante control
/// the Mac yet.
struct HandsSettingsSection: View {
    @Environment(\.theme) private var theme
    @Bindable private var preferences = Preferences.shared
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        SwiftUI.Section {
            Toggle("Let the agent open apps, find folders and use the keyboard and mouse", isOn: Binding(
                get: { preferences.handsEnabled }, set: { HandsController.shared.setEnabled($0) }))
                .help("For the main conversation only, never jobs. Hands follow your approval level: at Everything they go ahead, below it each keystroke, click and screenshot asks. Hands never act in Dante, terminals, System Settings or password apps, and the kill switch stops them at once.")
            if preferences.handsEnabled {
                Toggle("Ask before every keystroke and click", isOn: $preferences.handsAsksEachStep)
                    .help("On: every keyboard, mouse, screen and Outlook step waits for you, even at Everything. Off: they follow the approval level.")
                    .onChange(of: preferences.handsAsksEachStep) { Sessions.all.forEach { $0.applyClaudePreferences() } }
                LabeledContent("Kill switch") {
                    Text("\(HandsController.shortcut) anywhere, or Stop on the badge").foregroundStyle(theme.text3.color)
                }
                LabeledContent("Keyboard and mouse") {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(theme.green.color)
                    } else {
                        Button("Open Accessibility Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .help("macOS asks you to allow Dante under Privacy & Security › Accessibility before the agent can type or click. Opening apps and finding folders work without it.")
                    }
                }
            }
        } header: {
            Text("Hands")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }
}
