import Foundation

/// Keeping compose services up without being asked: a service that crashed or has been
/// unhealthy for a while is restarted, a few times at most, and a changed compose file is
/// applied. Services you stopped stay stopped, and so do ones that exited cleanly.
public enum ServiceRecovery {
    public enum Action: Equatable, Sendable {
        /// `docker compose up -d <service>`.
        case restart(service: String, reason: String)
        /// Tried too often: leave it and say so.
        case giveUp(service: String, reason: String)
        /// `docker compose up -d` for the services already running, after the compose file changed.
        case apply(reason: String)
    }

    public struct Attempt: Equatable, Sendable, Codable {
        public var service: String
        public var date: Date

        public init(service: String, date: Date) {
            self.service = service
            self.date = date
        }
    }

    /// Restarts per service within `window` before giving up.
    public static let limit = 3
    public static let window: TimeInterval = 15 * 60
    /// How long a service may stay unhealthy before it's restarted.
    public static let unhealthyGrace: TimeInterval = 90

    /// - Parameters:
    ///   - unhealthySince: when each service was first seen unhealthy.
    ///   - stoppedByYou: services stopped from Dante, never brought back on their own.
    ///   - gaveUp: services already reported as given up, so it's said once.
    ///   - composeChanged: the compose file differs from the one the running services started with.
    public static func plan(states: [ContainerState], services: [String], attempts: [Attempt], unhealthySince: [String: Date],
                            stoppedByYou: Set<String>, gaveUp: Set<String> = [], composeChanged: Bool = false, now: Date) -> [Action] {
        var actions: [Action] = []
        let anyRunning = states.contains { $0.state == "running" }
        if composeChanged, anyRunning {
            actions.append(.apply(reason: "The compose file changed"))
        }
        for state in states where services.contains(state.service) && !stoppedByYou.contains(state.service) {
            guard let reason = trouble(state, unhealthySince: unhealthySince[state.service], now: now) else { continue }
            let recent = attempts.filter { $0.service == state.service && now.timeIntervalSince($0.date) < window }
            if recent.count >= limit {
                if !gaveUp.contains(state.service) {
                    actions.append(.giveUp(service: state.service, reason: "\(reason), still after \(limit) restarts"))
                }
            } else {
                actions.append(.restart(service: state.service, reason: reason))
            }
        }
        return actions
    }

    /// Why a service needs bringing back, or nil when it's fine or meant to be down.
    static func trouble(_ state: ContainerState, unhealthySince: Date?, now: Date) -> String? {
        switch state.state {
        case "dead": return "It died"
        case "exited":
            // 0 is a clean finish (a one-off job); 143 and 137 are `docker stop` asking and insisting.
            guard let code = exitCode(state.status), ![0, 137, 143].contains(code) else { return nil }
            return "It crashed (exit \(code))"
        case "running":
            guard state.health == "unhealthy", let since = unhealthySince, now.timeIntervalSince(since) >= unhealthyGrace else { return nil }
            return "Unhealthy for \(Int(now.timeIntervalSince(since) / 60) < 2 ? "over a minute" : "\(Int(now.timeIntervalSince(since) / 60)) minutes")"
        default:
            // Docker's own restart policy is already at it.
            return nil
        }
    }

    /// "Exited (1) 2 minutes ago" → 1.
    static func exitCode(_ status: String) -> Int? {
        guard let open = status.firstIndex(of: "("), let close = status[open...].firstIndex(of: ")") else { return nil }
        return Int(status[status.index(after: open)..<close])
    }
}
