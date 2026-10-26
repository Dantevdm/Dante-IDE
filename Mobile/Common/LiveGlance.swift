import ActivityKit
import Foundation

/// Keeps one Live Activity going while the agents work or wait (`CompanionGlance`), updated
/// with each snapshot and ended after a minute of quiet or when the phone is unpaired. iOS
/// only lets an activity start with the app in front, so a quiet phone starts one at the next
/// opportunity; updates carry on in the background while the app runs (walk mode keeps it
/// running with the screen locked).
@MainActor
final class LiveGlance {
    /// The running activity's id: `Activity` isn't Sendable, so it's looked up where it's used.
    private var activity: String?
    private var last: DanteActivityAttributes.ContentState?
    private var quietSince: Date?
    private var ending: Task<Void, Never>?

    init(connection: CompanionConnection) {
        // One left over from before the app was last stopped is picked up rather than doubled.
        activity = Activity<DanteActivityAttributes>.activities.first?.id
        connection.observers.append { [weak self] snapshot, connected, _ in
            self?.update(CompanionGlance.make(snapshot, connected: connected), server: snapshot?.server ?? connection.pairing?.name ?? "your Mac")
        }
    }

    /// Off in Settings › Dante › Live Activities, or not on this device (most iPads).
    private var allowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func update(_ glance: CompanionGlance, server: String) {
        let state = DanteActivityAttributes.ContentState(mood: glance.mood.rawValue, headline: glance.headline, detail: glance.detail,
                                                         waiting: glance.waiting, working: glance.working)
        guard glance.isActive else {
            // Done for now: leave the last state up a minute, so a short pause doesn't flicker.
            if quietSince == nil { quietSince = Date() }
            scheduleEnd()
            return
        }
        quietSince = nil
        ending?.cancel()
        guard state != last || activity == nil else { return }
        last = state
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60), relevanceScore: glance.mood == .waiting ? 100 : 50)
        if let activity, Self.running(activity) {
            Task.detached { await Self.find(activity)?.update(content) }
        } else if allowed {
            activity = (try? Activity.request(attributes: DanteActivityAttributes(server: server), content: content))?.id
        }
    }

    private func scheduleEnd() {
        guard ending == nil || ending?.isCancelled == true, let activity else { return }
        ending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.quietSince != nil else { return }
            await Task.detached { await Self.find(activity)?.end(nil, dismissalPolicy: .immediate) }.value
            if self.activity == activity { self.activity = nil }
            self.last = nil
            self.ending = nil
        }
    }

    /// Unpaired: nothing to follow any more.
    func endNow() {
        ending?.cancel()
        activity = nil
        last = nil
        Task.detached {
            for activity in Activity<DanteActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    nonisolated private static func find(_ id: String) -> Activity<DanteActivityAttributes>? {
        Activity<DanteActivityAttributes>.activities.first { $0.id == id }
    }

    private static func running(_ id: String) -> Bool {
        find(id)?.activityState == .active
    }
}
