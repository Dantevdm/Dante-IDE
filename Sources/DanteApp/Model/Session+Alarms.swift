import DanteKit
import Foundation
import UserNotifications

/// Monitoring alarms: watching them, turning one into a task, and notifying when one fires.
extension Session {
    func watchAlarms() {
        guard let workspace else { return }
        alarms.onFire = { [weak self] firing in self?.notify(firing) }
        alarms.watch(workspace.info.alarms, in: workspace.url)
    }

    /// The task made from an alarm, newest first: open ones before finished ones.
    func task(for alarm: Alarm) -> PlanTask? {
        let linked = workspace?.tasks.tasks.filter { $0.alarm == alarm.id } ?? []
        return linked.last { $0.state != .done } ?? linked.last
    }

    func createTask(for alarm: Alarm) {
        guard let workspace else { return }
        let phase = workspace.lifecycle.phases.first { $0.lowercased() == "operate" } ?? workspace.lifecycle.phases.last ?? "Operate"
        var note = alarm.reason ?? ""
        if let updated = alarm.updated { note += (note.isEmpty ? "" : " ") + "(\(alarm.state == .alarm ? "firing" : "changed") since \(updated.formatted(date: .abbreviated, time: .shortened)))" }
        do {
            try workspace.tasks.add(title: "Alarm: \(alarm.name)", phase: phase, note: note.isEmpty ? nil : note, alarm: alarm.id)
        } catch {
            errorMessage = "Couldn’t add the task: \(error.localizedDescription)"
        }
    }

    func reopen(_ task: PlanTask) {
        do {
            try workspace?.tasks.move(task.id, to: .inProgress)
        } catch {
            errorMessage = "Couldn’t reopen \(task.id): \(error.localizedDescription)"
        }
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
}
