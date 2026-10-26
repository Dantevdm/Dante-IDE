import Foundation
import UIKit
import UserNotifications

/// Notifications for what the foreman notices while the app isn't in front: a step waiting
/// (Approve and Decline on the notification itself; Approve asks for the phone to be
/// unlocked), a job ready, stopped or asking, a reply finished. They're posted by the app while
/// it runs (in walk mode, with the screen locked); with no server of its own to push from,
/// nothing arrives once iOS has suspended it. A step answered elsewhere takes its notification
/// with it.
@MainActor
final class Notices: NSObject, UNUserNotificationCenterDelegate {
    private let connection: CompanionConnection
    private let center = UNUserNotificationCenter.current()
    /// Set by the app: a tapped notification focuses its project.
    var onOpen: (String) -> Void = { _ in }
    private var asked = false

    init(connection: CompanionConnection) {
        self.connection = connection
        super.init()
        center.delegate = self
        let approve = UNNotificationAction(identifier: CompanionNotice.approveAction, title: "Approve", options: [.authenticationRequired])
        let decline = UNNotificationAction(identifier: CompanionNotice.declineAction, title: "Decline", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: CompanionNotice.approvalCategory, actions: [approve, decline], intentIdentifiers: [], options: []),
        ])
        connection.observers.append { [weak self] snapshot, connected, events in
            guard let self else { return }
            if connected, !self.asked { self.askOnce() }
            if let snapshot {
                self.post(events, in: snapshot)
                self.withdrawAnswered(in: snapshot)
            }
        }
    }

    /// The first time the phone is connected: until then a notification couldn't mean anything.
    private func askOnce() {
        asked = true
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    private func post(_ events: [CompanionForeman.Event], in snapshot: CompanionSnapshot) {
        // In front, the app shows it all (and walk mode says it).
        guard UIApplication.shared.applicationState != .active, !events.isEmpty else { return }
        for event in events {
            let notice = CompanionNotice.make(event, in: snapshot)
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.threadIdentifier = notice.project
            content.userInfo = ["project": notice.project, "approval": notice.approval ?? ""]
            if notice.kind == .approval { content.categoryIdentifier = CompanionNotice.approvalCategory }
            if notice.sounds { content.sound = .default }
            content.interruptionLevel = notice.approval == nil ? .active : .timeSensitive
            center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
        }
        center.setBadgeCount(snapshot.waiting)
    }

    /// Steps answered on the Mac (or by voice) shouldn't sit on the Lock Screen.
    private func withdrawAnswered(in snapshot: CompanionSnapshot) {
        let waiting = Set(snapshot.projects.flatMap { $0.approvals.map { "approval." + $0.id } })
        center.getDeliveredNotifications { delivered in
            let gone = delivered.map(\.request.identifier).filter { $0.hasPrefix("approval.") && !waiting.contains($0) }
            guard !gone.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone)
        }
        center.setBadgeCount(snapshot.waiting)
    }

    #if DEBUG
    /// The demo's waiting step as a notification, two seconds later so it lands on the Lock Screen.
    func demo(_ snapshot: CompanionSnapshot) async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard let project = snapshot.projects.first, let approval = project.approvals.first else { return }
        let notice = CompanionNotice.make(.waiting(project: project.id, approval), in: snapshot)
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.categoryIdentifier = CompanionNotice.approvalCategory
        content.userInfo = ["project": notice.project, "approval": notice.approval ?? ""]
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: trigger))
    }
    #endif

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // Only posted from the background; one that lands as the app comes forward stays quiet.
        [.list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let project = info["project"] as? String ?? ""
        let approval = info["approval"] as? String ?? ""
        let action = response.actionIdentifier
        await respond(action: action, project: project, approval: approval)
    }

    private func respond(action: String, project: String, approval: String) async {
        switch action {
        case CompanionNotice.approveAction, CompanionNotice.declineAction:
            guard !approval.isEmpty else { return }
            // Woken in the background for this: iOS allows a few seconds, enough to reconnect.
            let result = await connection.answerWhenConnected(approval: approval, project: project, allow: action == CompanionNotice.approveAction)
            if !result.ok { tell(result.message, project: project) }
        default:
            if !project.isEmpty { onOpen(project) }
        }
    }

    /// A short notification saying an answer didn't go through.
    private func tell(_ message: String, project: String) {
        let content = UNMutableNotificationContent()
        content.title = "Not answered"
        content.body = message
        content.threadIdentifier = project
        content.userInfo = ["project": project]
        center.add(UNNotificationRequest(identifier: "result." + UUID().uuidString, content: content, trigger: nil))
    }
}
