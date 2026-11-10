import Foundation

/// What's wrong with a deployed app, in short lines, for notifications and the companion: a
/// deployment that failed, a component that's unhealthy or restarting.
public enum DeployWatch {
    public struct State: Equatable, Sendable {
        public var app: String
        /// The newest deployment's id and whether it failed.
        public var failedDeployment: String?
        public var unhealthy: Set<String>
        public var restarts: [String: Int]

        public init(app: String, failedDeployment: String? = nil, unhealthy: Set<String> = [], restarts: [String: Int] = [:]) {
            self.app = app
            self.failedDeployment = failedDeployment
            self.unhealthy = unhealthy
            self.restarts = restarts
        }

        public init(app: DOApp, newest: DODeployment?, health: [DOComponentHealth], restarts: [String: Double]) {
            self.app = app.name
            failedDeployment = newest?.phase == .error ? newest?.id : nil
            unhealthy = Set(health.filter { !$0.isHealthy || ($0.replicasDesired ?? 0) > ($0.replicasReady ?? $0.replicasDesired ?? 0) }.map(\.name))
            self.restarts = restarts.mapValues { Int($0) }
        }

        /// The lines describing it now.
        public var trouble: [String] {
            var lines: [String] = []
            if failedDeployment != nil { lines.append("The latest deployment of \(app) failed.") }
            for name in unhealthy.sorted() { lines.append("\(name) isn’t healthy.") }
            for (name, count) in restarts.sorted(by: { $0.key < $1.key }) where count >= DeployWatch.restartLimit {
                lines.append("\(name) restarted \(count) times today.")
            }
            return lines
        }
    }

    /// Restarts in a day that count as "keeps restarting".
    public static let restartLimit = 3

    /// Lines that are new since `old`, with a restart count that grew past the limit counting
    /// as new each time it rises.
    public static func news(from old: State?, to new: State) -> [String] {
        guard let old else { return [] }
        var lines: [String] = []
        if let failed = new.failedDeployment, failed != old.failedDeployment { lines.append("The latest deployment of \(new.app) failed.") }
        for name in new.unhealthy.subtracting(old.unhealthy).sorted() { lines.append("\(name) isn’t healthy.") }
        for (name, count) in new.restarts.sorted(by: { $0.key < $1.key }) where count >= restartLimit && count > (old.restarts[name] ?? 0) {
            lines.append("\(name) restarted \(count) times today.")
        }
        return lines
    }
}

/// Database connection pools in the code, and whether they fit the database and the traffic:
/// a pool too small queues requests (pgx's default is four per CPU the machine reports, and App
/// Platform reports the host's CPUs, not the share it gives the app), one too large across all
/// copies runs out of the database's connections.
public struct ConnectionPool: Equatable, Sendable {
    public var file: String
    public var line: Int
    public var library: String
    /// The maximum set in code, when there is one.
    public var maximum: Int?
    /// What the library does without one, in words.
    public var defaultMaximum: String

    public init(file: String, line: Int, library: String, maximum: Int?, defaultMaximum: String) {
        self.file = file
        self.line = line
        self.library = library
        self.maximum = maximum
        self.defaultMaximum = defaultMaximum
    }

    struct Pattern {
        var library: String
        var finds: NSRegularExpression
        var maximum: NSRegularExpression?
        var defaultMaximum: String
    }

    static let patterns: [Pattern] = [
        Pattern(library: "pgx", finds: try! NSRegularExpression(pattern: #"pgxpool\.(New|NewWithConfig|Connect|ConnectConfig)\("#),
                maximum: try! NSRegularExpression(pattern: #"(?:MaxConns\s*=\s*|pool_max_conns=)(\d+)"#), defaultMaximum: "4 per CPU the machine reports, at least 4"),
        Pattern(library: "database/sql", finds: try! NSRegularExpression(pattern: #"sql\.Open\("(postgres|pgx)"#),
                maximum: try! NSRegularExpression(pattern: #"SetMaxOpenConns\((\d+)\)"#), defaultMaximum: "no limit"),
        Pattern(library: "node-postgres", finds: try! NSRegularExpression(pattern: #"new\s+(?:pg\.)?Pool\("#),
                maximum: try! NSRegularExpression(pattern: #"\bmax\s*:\s*(\d+)"#), defaultMaximum: "10"),
        Pattern(library: "HikariCP", finds: try! NSRegularExpression(pattern: #"(spring\.datasource|maximum-pool-size|maximumPoolSize|HikariConfig)"#),
                maximum: try! NSRegularExpression(pattern: #"(?:maximum-pool-size|maximumPoolSize)\s*[:=(]\s*(\d+)"#), defaultMaximum: "10"),
        Pattern(library: "SQLAlchemy", finds: try! NSRegularExpression(pattern: #"create(?:_async)?_engine\("#),
                maximum: try! NSRegularExpression(pattern: #"pool_size\s*=\s*(\d+)"#), defaultMaximum: "5, plus 10 overflow"),
        Pattern(library: "Prisma", finds: try! NSRegularExpression(pattern: #"provider\s*=\s*"postgresql""#),
                maximum: try! NSRegularExpression(pattern: #"connection_limit=(\d+)"#), defaultMaximum: "2 per CPU plus 1"),
    ]

    static let extensions: Set<String> = ["go", "ts", "js", "mjs", "py", "java", "kt", "properties", "yml", "yaml", "prisma", "env"]

    /// Pools set up in shipped code (not tests), one per file and library.
    public static func detect(files: [String], read: (String) -> String?) -> [ConnectionPool] {
        var found: [ConnectionPool] = []
        for file in files where extensions.contains((file as NSString).pathExtension.lowercased()) && CodePlace.of(file) == .shipped
            && !file.contains("node_modules/") && !file.contains("vendor/") {
            guard let text = read(file), text.utf8.count < 400_000 else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for pattern in patterns {
                guard let match = pattern.finds.firstMatch(in: text, range: range) else { continue }
                // Spring's datasource only counts with a Postgres URL beside it.
                if pattern.library == "HikariCP", !text.contains("postgresql") && !text.contains("maximum") { continue }
                let line = text[..<(Range(match.range, in: text)?.lowerBound ?? text.startIndex)].filter(\.isNewline).count + 1
                let maximum = pattern.maximum?.firstMatch(in: text, range: range).flatMap { Range($0.range(at: 1), in: text) }.flatMap { Int(text[$0]) }
                found.append(ConnectionPool(file: file, line: line, library: pattern.library, maximum: maximum, defaultMaximum: pattern.defaultMaximum))
            }
        }
        return found
    }

    /// The connections a Postgres database on DigitalOcean takes: 25 per GB of memory less 3
    /// kept back, and about 22 for a dev database.
    public static func databaseLimit(clusterSize: String?) -> Int {
        guard let size = clusterSize, let match = size.firstMatch(of: /-(\d+)gb$/), let gb = Int(match.1) else { return 22 }
        return max(22, gb * 25 - 3)
    }

    /// Connections per copy that fit: the database's limit shared by every copy that could run
    /// (autoscaling's most), keeping a few for migrations and consoles.
    public static func suggested(limit: Int, copies: Int) -> Int {
        max(2, (limit - 4) / max(1, copies))
    }
}

/// The month's bill and a budget: whether a change raises the monthly price by more than the
/// person allows, and how much of the budget is used.
public enum CostGuard {
    /// The sentence to show before deploying, when the change costs more than `limit` a month extra.
    public static func warning(current: Double?, new: Double?, limit: Double?) -> String? {
        guard let new, let limit, limit >= 0 else { return nil }
        let raise = new - (current ?? 0)
        guard raise > limit + 0.005 else { return nil }
        let from = current.map { String(format: " from $%.2f", $0) } ?? ""
        return String(format: "This raises the app's bill by $%.2f a month%@ to $%.2f, more than the $%.2f you allowed.", raise, from, new, limit)
    }

    /// The share of the budget used, 0…1 or above.
    public static func used(monthToDate: Double, budget: Double) -> Double {
        budget > 0 ? monthToDate / budget : 0
    }

    /// The month's spend so far stretched to the whole month, for "on track for $…".
    public static func projected(monthToDate: Double, now: Date, calendar: Calendar = .current) -> Double {
        guard let days = calendar.range(of: .day, in: .month, for: now)?.count else { return monthToDate }
        let day = calendar.component(.day, from: now)
        let hour = Double(calendar.component(.hour, from: now)) / 24
        let elapsed = max(0.5, Double(day - 1) + hour)
        return monthToDate / elapsed * Double(days)
    }
}

/// Load testing the live app is allowed only on its own App Platform address (or a domain the
/// spec gives it), once the person has confirmed, and only as a load test: Bliksem's fuzz
/// probes and chaos stay on this Mac.
public enum LiveLoadTest {
    public static func isAppAddress(_ host: String, app: DOApp) -> Bool {
        let host = host.lowercased()
        if let live = app.liveURL?.host?.lowercased(), host == live { return true }
        return (app.spec?.domains ?? []).contains { $0.domain.lowercased() == host }
    }

    /// The most users at once against a live app: enough to find its limit without being an attack.
    public static let maxUsers = 100
}
