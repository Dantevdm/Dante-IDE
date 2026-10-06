import Foundation
import Observation

/// Where alarms come from, from `operate.alarms` in project.yaml.
public enum AlarmSource: Equatable, Hashable, Sendable {
    /// CloudWatch through the `aws` command line and its existing login. Read only.
    case cloudwatch(profile: String?, region: String?, prefix: String?)
    /// Any command that prints alarms as JSON (see `Alarms.parseCommand`), for Datadog,
    /// Grafana, Alertmanager and the rest.
    case command(String)

    public var label: String {
        switch self {
        case .cloudwatch(let profile, let region, let prefix):
            (["CloudWatch"] + [profile, region, prefix.map { "\($0)*" }].compactMap { $0 }).joined(separator: " · ")
        case .command(let run): run
        }
    }

    /// The command that lists the alarms.
    public var arguments: [String] {
        switch self {
        case .cloudwatch(let profile, let region, let prefix):
            var arguments = ["aws", "cloudwatch", "describe-alarms", "--output", "json"]
            if let prefix { arguments += ["--alarm-name-prefix", prefix] }
            if let profile { arguments += ["--profile", profile] }
            if let region { arguments += ["--region", region] }
            return arguments
        case .command(let run):
            return ["sh", "-c", run]
        }
    }

    /// `{ source: cloudwatch, profile, region, prefix }` or `{ source: command, run }`;
    /// a bare string is a command.
    static func parse(_ entry: Any) -> AlarmSource? {
        if let run = entry as? String { return run.nonEmptyTrimmed.map(AlarmSource.command) }
        guard let entry = entry as? [String: Any] else { return nil }
        func text(_ key: String) -> String? { (entry[key] as? String)?.nonEmptyTrimmed }
        switch text("source")?.lowercased() {
        case "cloudwatch", "aws":
            return .cloudwatch(profile: text("profile"), region: text("region"), prefix: text("prefix"))
        case "command", nil:
            return text("run").map(AlarmSource.command)
        default:
            return nil
        }
    }
}

/// One alarm and its current state.
public struct Alarm: Equatable, Sendable, Identifiable {
    public enum State: String, Sendable, Comparable {
        case alarm, unknown, ok

        /// Firing first.
        public static func < (a: State, b: State) -> Bool {
            let order: [State] = [.alarm, .unknown, .ok]
            return order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }

        /// The many ways services spell it.
        init(_ text: String) {
            switch text.lowercased().replacingOccurrences(of: "-", with: "_") {
            case "alarm", "alerting", "firing", "triggered", "critical", "error", "warn", "warning", "active", "open": self = .alarm
            case "ok", "normal", "resolved", "inactive", "closed", "pass", "passing": self = .ok
            default: self = .unknown
            }
        }
    }

    /// Stable across refreshes: the source's own id, else its name.
    public var id: String
    public var name: String
    public var state: State
    public var reason: String?
    public var updated: Date?
    public var url: URL?

    public init(id: String, name: String, state: State, reason: String? = nil, updated: Date? = nil, url: URL? = nil) {
        self.id = id
        self.name = name
        self.state = state
        self.reason = reason
        self.updated = updated
        self.url = url
    }
}

public enum Alarms {
    /// `aws cloudwatch describe-alarms --output json`: metric and composite alarms.
    public static func parseCloudWatch(_ json: String, region: String? = nil) -> [Alarm] {
        guard let value = JSONValue(line: json) else { return [] }
        let items = (value["MetricAlarms"]?.array ?? []) + (value["CompositeAlarms"]?.array ?? [])
        return items.compactMap { item -> Alarm? in
            guard let name = item["AlarmName"]?.string else { return nil }
            let arn = item["AlarmArn"]?.string
            // arn:aws:cloudwatch:<region>:<account>:alarm:<name>
            let alarmRegion = region ?? arn?.split(separator: ":").dropFirst(3).first.map(String.init)
            let url = alarmRegion.flatMap { region in
                name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))).flatMap {
                    URL(string: "https://\(region).console.aws.amazon.com/cloudwatch/home?region=\(region)#alarmsV2:alarm/\($0)")
                }
            }
            return Alarm(id: arn ?? "cloudwatch:\(name)", name: name, state: Alarm.State(item["StateValue"]?.string ?? ""),
                         reason: item["StateReason"]?.string, updated: date(item["StateUpdatedTimestamp"]?.string), url: url)
        }
    }

    /// A command's output: a JSON array (or `{ "alarms": [...] }`) of objects with `name`
    /// and `state`, and optionally `id`, `reason`, `updated` (ISO 8601) and `url`.
    public static func parseCommand(_ json: String) -> [Alarm] {
        guard let value = JSONValue(line: json) else { return [] }
        let items = value.array ?? value["alarms"]?.array ?? []
        return items.compactMap { item -> Alarm? in
            guard let name = item["name"]?.string ?? item["title"]?.string else { return nil }
            return Alarm(id: item["id"]?.string ?? name, name: name, state: Alarm.State(item["state"]?.string ?? item["status"]?.string ?? ""),
                         reason: item["reason"]?.string ?? item["message"]?.string, updated: date(item["updated"]?.string),
                         url: item["url"]?.string.flatMap(URL.init(string:)))
        }
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Alarms firing again after the task made from them was finished.
    public static func refired(_ alarms: [Alarm], tasks: [PlanTask]) -> [(alarm: Alarm, task: PlanTask)] {
        alarms.filter { $0.state == .alarm }.compactMap { alarm in
            tasks.last { $0.alarm == alarm.id && $0.state == .done }.map { (alarm, $0) }
        }
    }

    /// What to hand Claude: the alarm, and errors from the log stream that might go with it.
    public static func investigatePrompt(_ alarm: Alarm, errors: [ErrorDigest.Issue]) -> String {
        var lines = ["This production alarm is firing: \(alarm.name)."]
        if let reason = alarm.reason { lines.append("Reason: \(reason)") }
        if let updated = alarm.updated { lines.append("Since: \(ISO8601DateFormatter().string(from: updated))") }
        if !errors.isEmpty {
            lines.append("\nErrors in the production logs since Dante started following them:")
            for issue in errors.prefix(5) { lines.append("- ×\(issue.count) \(issue.example)") }
        }
        lines.append("\nFind what in the code could cause this, and what to check first. Don't change anything yet.")
        return lines.joined(separator: "\n")
    }
}

/// Polls the alarm sources and remembers which alarms started firing since the last poll.
@MainActor
@Observable
public final class AlarmMonitor {
    public private(set) var alarms: [Alarm] = []
    /// Why a source couldn't be read, by its label.
    public private(set) var errors: [String: String] = [:]
    public private(set) var lastChecked: Date?
    public private(set) var isChecking = false
    private(set) var sources: [AlarmSource] = []
    private var root: URL?
    private var task: Task<Void, Never>?
    /// Called with alarms that went into ALARM since the previous poll (not on the first).
    public var onFire: (@MainActor ([Alarm]) -> Void)?

    public init() {}

    public func watch(_ sources: [AlarmSource], in root: URL, every interval: Duration = .seconds(60)) {
        guard sources != self.sources || root != self.root || task == nil else { return }
        self.sources = sources
        self.root = root
        task?.cancel()
        alarms = []
        errors = [:]
        guard !sources.isEmpty else { task = nil; return }
        task = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                await self?.poll(notifying: !first)
                first = false
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func poll(notifying: Bool = false) async {
        guard let root, !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var found: [Alarm] = []
        var failures: [String: String] = [:]
        for source in sources {
            let output = await Shell.run(source.arguments, in: root)
            guard output.succeeded else {
                failures[source.label] = output.status == 127 && source.arguments.first == "aws"
                    ? "The aws command line isn’t installed."
                    : output.message.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? "Exited with status \(output.status)."
                continue
            }
            switch source {
            case .cloudwatch(_, let region, _): found += Alarms.parseCloudWatch(output.stdout, region: region)
            case .command: found += Alarms.parseCommand(output.stdout)
            }
        }
        found.sort { $0.state != $1.state ? $0.state < $1.state : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let wasFiring = Set(alarms.filter { $0.state == .alarm }.map(\.id))
        let newlyFiring = found.filter { $0.state == .alarm && !wasFiring.contains($0.id) }
        alarms = found
        errors = failures
        lastChecked = .now
        if notifying, !newlyFiring.isEmpty { onFire?(newlyFiring) }
    }
}
