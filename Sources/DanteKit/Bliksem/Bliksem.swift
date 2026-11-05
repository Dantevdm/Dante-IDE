import Foundation

/// Bliksem: hammer the running system with load, throw garbage at its routes, and break its
/// services to see how it copes. Everything here is pure; `BliksemRunner` sends the requests.
/// It only ever sends to this Mac and to test hosts (`BrowserHosts`), never to the internet.
public enum Bliksem {
    /// The most virtual users a load run may have.
    public static let maxUsers = 200
    /// A breaking point: the 95th percentile above this many seconds…
    public static let slowP95 = 1.0
    /// …or more than this share of requests failing.
    public static let failingShare = 0.05
}

/// One route the map found in the code.
public struct BliksemRoute: Hashable, Sendable, Identifiable, Codable {
    public var method: String
    /// As written in the code: `/orders/{id}`, `/orders/:id`, `/orders/<int:id>`.
    public var path: String

    public init(method: String, path: String) {
        self.method = method.uppercased()
        self.path = path.hasPrefix("/") ? path : "/" + path
    }

    public var id: String { method + " " + path }
    /// Reads don't change anything, so they're the only routes hit unless writes are asked for.
    public var isRead: Bool { ["GET", "HEAD", "OPTIONS"].contains(method) }
    public var takesBody: Bool { ["POST", "PUT", "PATCH"].contains(method) }

    /// "GET /orders/{id}" or a bare "/orders" (GET), as `SystemMap.Item.text` has them.
    public static func parse(_ text: String) -> BliksemRoute? {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let last = words.last, last.hasPrefix("/") else { return nil }
        let method = words.count > 1 ? words[0].uppercased() : "GET"
        let known = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "ALL", "ANY"]
        guard known.contains(method) else { return nil }
        return BliksemRoute(method: method == "ALL" || method == "ANY" ? "GET" : method, path: last)
    }

    /// Every route in the map's API lane, reads first, each once.
    public static func from(_ map: SystemMap) -> [BliksemRoute] {
        var seen = Set<String>()
        var routes: [BliksemRoute] = []
        for part in map.parts where part.lane == .api && part.kind == .routes {
            for item in part.items {
                guard let route = parse(item.text), !route.path.contains("*"), seen.insert(route.id).inserted else { continue }
                routes.append(route)
            }
        }
        return routes.sorted { ($0.isRead ? 0 : 1, $0.path, $0.method) < ($1.isRead ? 0 : 1, $1.path, $1.method) }
    }

    /// One path segment's parameter name, or nil for a fixed segment.
    static func parameter(_ segment: Substring) -> String? {
        var name: Substring
        if segment.hasPrefix("{"), segment.hasSuffix("}") { name = segment.dropFirst().dropLast() }
        else if segment.hasPrefix(":") { name = segment.dropFirst() }
        else if segment.hasPrefix("<"), segment.hasSuffix(">") { name = segment.dropFirst().dropLast() }
        else if segment.hasPrefix("["), segment.hasSuffix("]") { name = segment.dropFirst().dropLast() }
        else if segment.hasPrefix("$") { name = segment.dropFirst() }
        else { return nil }
        // `{id:int}`, `<int:id>`, `[...slug]`, `{id?}`.
        if segment.hasPrefix("<"), let colon = name.lastIndex(of: ":") { name = name[name.index(after: colon)...] }
        else if let colon = name.firstIndex(of: ":") { name = name[..<colon] }
        name = Substring(name.trimmingCharacters(in: CharacterSet(charactersIn: ".?[]")))
        return String(name)
    }

    public var parameters: [String] { path.split(separator: "/").compactMap(Self.parameter) }

    /// The path with each parameter given `value(name)`.
    public func filled(_ value: (String) -> String) -> String {
        "/" + path.split(separator: "/").map { segment in
            Self.parameter(segment).map(value) ?? String(segment)
        }.joined(separator: "/")
    }

    /// The path with a plausible value for each parameter: ids are 1, uuids a fixed uuid.
    public var samplePath: String {
        filled { name in
            let name = name.lowercased()
            if name.contains("uuid") || name == "guid" { return "00000000-0000-4000-8000-000000000001" }
            if name.hasSuffix("id") || name == "n" || name.contains("number") || name == "page" { return "1" }
            return "sample"
        }
    }
}

/// Where Bliksem sends its requests.
public enum BliksemTarget {
    public enum Refusal: Error, Equatable, Sendable {
        case notAURL, notHTTP, notLocal(String)

        public var explanation: String {
            switch self {
            case .notAURL: "That isn’t an address. Type one like http://localhost:8080."
            case .notHTTP: "Bliksem speaks HTTP: the address must start with http:// or https://."
            case .notLocal(let host): "Bliksem only hits this Mac and test hosts, so it won’t send to \(host). Add a test host under browser: hosts: in .dante/project.yaml to allow it."
            }
        }
    }

    /// The base URL, checked against the hosts the agents' browser may visit.
    public static func check(_ text: String, hosts: BrowserHosts) -> Result<URL, Refusal> {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), let host = url.host(percentEncoded: false), !host.isEmpty else { return .failure(.notAURL) }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .failure(.notHTTP) }
        guard hosts.allows(url) else { return .failure(.notLocal(host)) }
        return .success(url)
    }

    /// `base` with the route's path after any path it already has.
    public static func url(_ base: URL, path: String, query: String? = nil) -> URL? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let prefix = (components?.percentEncodedPath ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.percentEncodedPath = (prefix.isEmpty ? "" : "/" + prefix) + path
        components?.percentEncodedQuery = query
        return components?.url
    }
}

/// One request's outcome.
public struct BliksemSample: Sendable, Equatable, Codable {
    public var route: String
    /// Seconds from the start of the run.
    public var start: Double
    public var duration: Double
    /// Nil when no response came back.
    public var status: Int?
    public var error: String?

    public init(route: String, start: Double, duration: Double, status: Int?, error: String? = nil) {
        self.route = route
        self.start = start
        self.duration = duration
        self.status = status
        self.error = error
    }

    /// No answer, a server error, or the server saying it's overloaded. A 404 for a made-up
    /// id still went through the app, so it isn't a failure.
    public var failed: Bool { status.map { $0 >= 500 || $0 == 429 } ?? true }
}

/// A load run's plan: stages, each moving the number of virtual users from one count to another.
public struct LoadPlan: Equatable, Sendable, Codable {
    public struct Stage: Equatable, Sendable, Codable {
        public var name: String
        public var seconds: Double
        public var from: Int
        public var to: Int

        public init(name: String, seconds: Double, from: Int, to: Int) {
            self.name = name
            self.seconds = seconds
            self.from = from
            self.to = to
        }
    }

    public var stages: [Stage]

    public init(stages: [Stage]) { self.stages = stages }

    /// Warm up, ramp to `peak`, spike to twice it, then cool down.
    public static func standard(peak: Int, seconds: Int) -> LoadPlan {
        let peak = min(max(peak, 1), Bliksem.maxUsers / 2)
        let total = Double(max(seconds, 20))
        let warm = max(1, peak / 10)
        return LoadPlan(stages: [
            Stage(name: "Warm-up", seconds: (total * 0.15).rounded(), from: 1, to: warm),
            Stage(name: "Ramp", seconds: (total * 0.45).rounded(), from: warm, to: peak),
            Stage(name: "Spike", seconds: (total * 0.2).rounded(), from: peak * 2, to: peak * 2),
            Stage(name: "Cool-down", seconds: (total * 0.2).rounded(), from: peak, to: 1),
        ])
    }

    public var duration: Double { stages.reduce(0) { $0 + $1.seconds } }
    public var peak: Int { min(stages.map { max($0.from, $0.to) }.max() ?? 1, Bliksem.maxUsers) }

    /// How many users run at `t` seconds in, and the stage.
    public func users(at t: Double) -> Int { stage(at: t).users }

    public func stage(at t: Double) -> (name: String, users: Int) {
        var elapsed = 0.0
        for stage in stages {
            if t < elapsed + stage.seconds {
                let share = stage.seconds > 0 ? (t - elapsed) / stage.seconds : 1
                let users = Double(stage.from) + Double(stage.to - stage.from) * share
                return (stage.name, min(max(Int(users.rounded()), stage.to == 0 && stage.from == 0 ? 0 : 1), Bliksem.maxUsers))
            }
            elapsed += stage.seconds
        }
        return (stages.last?.name ?? "", 0)
    }
}

/// One second of a run.
public struct BliksemSecond: Equatable, Sendable, Codable, Identifiable {
    public var second: Int
    public var requests: Int
    public var failures: Int
    public var p50: Double
    public var p95: Double
    public var users: Int
    public var id: Int { second }

    public var failingShare: Double { requests == 0 ? 0 : Double(failures) / Double(requests) }
}

/// One route's figures over a run.
public struct BliksemRouteStats: Equatable, Sendable, Identifiable, Codable {
    public var route: String
    public var requests: Int
    public var failures: Int
    public var p50: Double
    public var p95: Double
    public var p99: Double
    /// Status code (0 for no answer) to count.
    public var statuses: [Int: Int]
    public var id: String { route }

    /// The commonest answer, as text ("200", "404", "no answer").
    public var usual: String {
        guard let (code, _) = statuses.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) else { return "—" }
        return code == 0 ? "no answer" : String(code)
    }
}

/// Where the system stopped keeping up.
public struct BreakingPoint: Equatable, Sendable, Codable {
    public var second: Int
    public var users: Int
    public var reason: String
}

public enum BliksemStats {
    /// Nearest-rank percentile of sorted values.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// Samples bucketed by the second they started in, every second up to the last.
    public static func seconds(_ samples: [BliksemSample], users: (Int) -> Int) -> [BliksemSecond] {
        guard let last = samples.map(\.start).max() else { return [] }
        var buckets = Array(repeating: [BliksemSample](), count: Int(last) + 1)
        for sample in samples where sample.start >= 0 { buckets[Int(sample.start)].append(sample) }
        return buckets.enumerated().map { second, bucket in
            let times = bucket.filter { !$0.failed }.map(\.duration).sorted()
            return BliksemSecond(second: second, requests: bucket.count, failures: bucket.count { $0.failed },
                                 p50: percentile(times, 50), p95: percentile(times, 95), users: users(second))
        }
    }

    public static func routes(_ samples: [BliksemSample]) -> [BliksemRouteStats] {
        Dictionary(grouping: samples, by: \.route).map { route, samples in
            let times = samples.map(\.duration).sorted()
            var statuses: [Int: Int] = [:]
            for sample in samples { statuses[sample.status ?? 0, default: 0] += 1 }
            return BliksemRouteStats(route: route, requests: samples.count, failures: samples.count { $0.failed },
                                     p50: percentile(times, 50), p95: percentile(times, 95), p99: percentile(times, 99), statuses: statuses)
        }
        .sorted { ($0.failures, $0.p95, $1.route) > ($1.failures, $1.p95, $0.route) }
    }

    /// The first second, with enough requests to judge, that was too slow or failed too often,
    /// and stayed that way for the next second too, so one hiccup isn't called a breaking point.
    public static func breakingPoint(_ seconds: [BliksemSecond]) -> BreakingPoint? {
        func bad(_ s: BliksemSecond) -> String? {
            guard s.requests >= 5 else { return nil }
            if s.failingShare > Bliksem.failingShare { return "\(Int((s.failingShare * 100).rounded()))% of requests failed" }
            if s.p95 > Bliksem.slowP95 { return "95% took up to \(BliksemStats.time(s.p95))" }
            return nil
        }
        for (index, second) in seconds.enumerated() {
            guard let reason = bad(second) else { continue }
            if index + 1 < seconds.count, bad(seconds[index + 1]) == nil, seconds[index + 1].requests >= 5 { continue }
            return BreakingPoint(second: second.second, users: second.users, reason: reason)
        }
        return nil
    }

    /// "180 ms", "1.4 s".
    public static func time(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }
}

/// What a load run found, in sentences.
public struct LoadSummary: Equatable, Sendable, Codable {
    public var requests: Int
    public var failures: Int
    public var seconds: Double
    public var peakRate: Int
    public var p50: Double
    public var p95: Double
    public var p99: Double
    public var peakUsers: Int
    public var breakingPoint: BreakingPoint?

    public static func make(_ samples: [BliksemSample], timeline: [BliksemSecond], duration: Double) -> LoadSummary {
        let times = samples.filter { !$0.failed }.map(\.duration).sorted()
        return LoadSummary(requests: samples.count, failures: samples.count { $0.failed }, seconds: duration,
                           peakRate: timeline.map(\.requests).max() ?? 0,
                           p50: BliksemStats.percentile(times, 50), p95: BliksemStats.percentile(times, 95), p99: BliksemStats.percentile(times, 99),
                           peakUsers: timeline.map(\.users).max() ?? 0, breakingPoint: BliksemStats.breakingPoint(timeline))
    }

    public var rate: Double { seconds > 0 ? Double(requests) / seconds : 0 }
    public var failingShare: Double { requests == 0 ? 0 : Double(failures) / Double(requests) }

    public var verdict: String {
        if requests == 0 { return "Nothing answered: is the app running at that address?" }
        if let point = breakingPoint { return "It broke at \(point.users) users, \(point.second) s in: \(point.reason)." }
        return "It held up to \(peakUsers) users: \(Int(rate.rounded())) requests a second, 95% within \(BliksemStats.time(p95))."
    }
}
