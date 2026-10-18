import DanteKit
import AppKit
import Foundation
import UserNotifications

/// Monitoring alarms: watching them, investigating one, and notifying when one fires.
extension Session {
    func watchAlarms() {
        guard let workspace else { return }
        alarms.onFire = { [weak self] firing in self?.notify(firing) }
        alarms.watch(workspace.info.alarms, in: workspace.url)
    }

    func investigate(_ alarm: Alarm) {
        askClaude(Alarms.investigatePrompt(alarm, errors: logWatch?.digest.issues ?? []))
    }

    /// Asks macOS for permission the first time notifications are turned on.
    static func requestNotificationPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private func notify(_ firing: [Alarm]) {
        guard Preferences.shared.notifiesOnAlarms, let workspace else { return }
        for alarm in firing.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = "\(alarm.name) is firing"
            content.subtitle = workspace.url.lastPathComponent
            content.body = alarm.reason ?? "A monitoring alarm went into ALARM."
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "alarm-\(alarm.id)", content: content, trigger: nil))
        }
    }

    /// Claude finished or is waiting, and Dante isn't the app in front.
    func notifyClaude(_ attention: ClaudeSession.Attention) {
        guard Preferences.shared.notifiesOnClaude, !NSApplication.shared.isActive, let workspace else { return }
        let content = UNMutableNotificationContent()
        content.subtitle = workspace.url.lastPathComponent
        switch attention {
        case .finished(let reply):
            content.title = "Claude is done"
            content.body = reply
        case .needsApproval(let what):
            content.title = "Claude is waiting for you"
            content.body = what
            content.sound = .default
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "claude-\(workspace.url.path)", content: content, trigger: nil))
    }
}
