import AppKit
import DanteKit
import Foundation
import UserNotifications

/// Watching the deployed app from any page: every two minutes it's looked at again, and a
/// deployment that failed, a component that went unhealthy or one that keeps restarting is
/// posted as a notification and kept in `trouble` for the companion.
extension DeployModel {
    static let watchInterval: Duration = .seconds(120)

    /// Runs for the window's life (WorkspaceView); does nothing until a project is linked to an app.
    func watchInBackground(workspace: Workspace) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.watchInterval)
            if root != workspace.url { await load(workspace: workspace) }
            guard signedIn, linkedAppID != nil, !isDemoMode else { continue }
            if (lastRefreshed ?? .distantPast) < .now.addingTimeInterval(-90) { await refresh() }
            checkTrouble()
        }
    }

    /// Compares the app with the last look and tells the person what's new.
    func checkTrouble() {
        guard let app else { trouble = []; watched = nil; return }
        let state = DeployWatch.State(app: app, newest: deployments.first, health: health, restarts: restarts)
        let news = DeployWatch.news(from: watched?.app == state.app ? watched : nil, to: state)
        watched = state
        trouble = state.trouble
        guard !news.isEmpty, Preferences.shared.notifiesOnDeploy else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            content.title = news.count == 1 ? "Trouble with \(app.name)" : "\(news.count) problems with \(app.name)"
            content.body = news.joined(separator: " ")
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "deploy-trouble-\(app.id)-\(news.joined().hashValue)", content: content, trigger: nil))
        }
    }
}
