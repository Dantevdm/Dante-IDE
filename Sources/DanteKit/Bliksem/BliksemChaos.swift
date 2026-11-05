import Foundation

/// Breaking one of the project's own compose services under a light load, then putting it
/// back and timing how long the system takes to recover.
public enum ChaosFault: String, CaseIterable, Sendable, Codable, Identifiable {
    case stop, pause, kill, restart

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .stop: "Stop it"
        case .pause: "Freeze it"
        case .kill: "Kill it"
        case .restart: "Restart it"
        }
    }

    public var explanation: String {
        switch self {
        case .stop: "Stops the container cleanly, as a deploy or a crash that exits would, then starts it again."
        case .pause: "Freezes every process in it: connections stay open but nothing answers, like a hung database. Then thaws it."
        case .kill: "Sends SIGKILL with no time to tidy up, then starts it again."
        case .restart: "Restarts it once and watches the system find it again."
        }
    }

    /// The command that breaks `service`.
    public func breaking(_ service: String) -> [String] {
        ["docker", "compose", rawValue, service]
    }

    /// The command that puts `service` back, or nil when breaking it already does.
    public func restoring(_ service: String) -> [String]? {
        switch self {
        case .stop, .kill: ["docker", "compose", "start", service]
        case .pause: ["docker", "compose", "unpause", service]
        case .restart: nil
        }
    }
}

public struct ChaosPlan: Equatable, Sendable, Codable {
    public var service: String
    public var fault: ChaosFault
    /// Seconds of light load before the fault, to know what normal looks like.
    public var baseline: Double = 15
    /// Seconds the service stays broken.
    public var outage: Double = 20
    /// The longest to wait after putting it back.
    public var recovery: Double = 60
    public var users: Int = 4

    public init(service: String, fault: ChaosFault) {
        self.service = service
        self.fault = fault
    }

    /// Which services may be broken: this project's compose services that are running, and
    /// never ones started outside it.
    public static func candidates(compose: ComposeFile?, containers: [ContainerState]) -> [String] {
        let declared = Set(compose?.services.map(\.name) ?? [])
        return containers.filter { declared.contains($0.service) && $0.state == "running" }.map(\.service).sorted()
    }
}

/// When each phase of a chaos run began, in seconds from its start.
public struct ChaosTimes: Equatable, Sendable, Codable {
    public var broke: Double
    public var restored: Double
    public var ended: Double

    public init(broke: Double, restored: Double, ended: Double) {
        self.broke = broke
        self.restored = restored
        self.ended = ended
    }
}

public struct ChaosAnalysis: Equatable, Sendable, Codable {
    public enum Verdict: Equatable, Sendable, Codable {
        /// Requests kept succeeding while it was down.
        case rodeItOut
        /// Back to normal this many seconds after the service was.
        case recovered(Double)
        /// Still failing when the watch ended.
        case stayedBroken
    }

    public var baselineFailing: Double
    public var baselineP95: Double
    public var outageFailing: Double
    public var outageP95: Double
    /// Seconds into the outage before the first failure.
    public var firstFailure: Double?
    public var verdict: Verdict
    /// What the failures said, commonest first ("503" ×40, "no answer" ×12).
    public var answers: [Answer]

    public struct Answer: Equatable, Sendable, Codable {
        public var text: String
        public var count: Int
    }

    /// Normal is the baseline's failing share plus two points, and its p95 doubled plus 50 ms;
    /// recovered is the first three seconds in a row after the restore that are all normal.
    public static func analyse(_ samples: [BliksemSample], times: ChaosTimes) -> ChaosAnalysis {
        let before = samples.filter { $0.start < times.broke }
        let during = samples.filter { $0.start >= times.broke && $0.start < times.restored }
        func failing(_ s: [BliksemSample]) -> Double { s.isEmpty ? 0 : Double(s.count { $0.failed }) / Double(s.count) }
        func p95(_ s: [BliksemSample]) -> Double { BliksemStats.percentile(s.filter { !$0.failed }.map(\.duration).sorted(), 95) }
        let normalFailing = failing(before) + 0.02
        let normalP95 = p95(before) * 2 + 0.05
        let firstFailure = during.filter(\.failed).map(\.start).min().map { $0 - times.broke }

        var answers: [String: Int] = [:]
        for sample in samples where sample.failed && sample.start >= times.broke {
            answers[sample.status.map(String.init) ?? (sample.error ?? "no answer"), default: 0] += 1
        }

        let verdict: Verdict
        if failing(during) <= normalFailing, p95(during) <= max(normalP95, 0.5) {
            verdict = .rodeItOut
        } else {
            var streak = 0
            var found: Double?
            var second = times.restored.rounded(.down)
            while second < times.ended {
                let bucket = samples.filter { $0.start >= second && $0.start < second + 1 }
                if !bucket.isEmpty, failing(bucket) <= normalFailing, p95(bucket) <= max(normalP95, 0.5) {
                    streak += 1
                    if streak == 3 { found = max(0, second - 2 - times.restored); break }
                } else {
                    streak = 0
                }
                second += 1
            }
            verdict = found.map { .recovered($0) } ?? .stayedBroken
        }
        return ChaosAnalysis(baselineFailing: failing(before), baselineP95: p95(before), outageFailing: failing(during), outageP95: p95(during),
                             firstFailure: firstFailure, verdict: verdict,
                             answers: answers.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { Answer(text: $0.key, count: $0.value) })
    }

    /// The result in a sentence or two, naming the service.
    public func story(service: String, fault: ChaosFault) -> String {
        let broken = switch fault {
        case .stop: "stopped"
        case .pause: "frozen"
        case .kill: "killed"
        case .restart: "restarting"
        }
        let during = outageFailing == 0 ? "nothing failed"
            : "\(Int((outageFailing * 100).rounded()))% of requests failed" + (answers.first.map { ", mostly \($0.text)" } ?? "")
        switch verdict {
        case .rodeItOut:
            return "With \(service) \(broken), \(during): the system rode it out."
        case .recovered(let seconds):
            let after = seconds < 1 ? "as soon as it was back" : "\(Int(seconds.rounded())) s after it was back"
            return "With \(service) \(broken), \(during). It recovered \(after)."
        case .stayedBroken:
            return "With \(service) \(broken), \(during), and it still hadn’t recovered when the watch ended: something holds on to a dead connection or never retries."
        }
    }
}
