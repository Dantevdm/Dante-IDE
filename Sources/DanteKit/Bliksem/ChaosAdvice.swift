import Foundation

/// What to do about a chaos run: suggestions read from how the app failed and from its code
/// and compose file, each with the change to make. Pure.
public struct ChaosSuggestion: Equatable, Sendable, Identifiable {
    public var title: String
    /// What the run showed.
    public var evidence: String
    /// The change, as specific as the stack allows.
    public var fix: String
    public var id: String { title }
}

public enum ChaosAdvice {
    /// The stack's database pool, for advice in its own terms.
    enum Pool: Equatable {
        case hikari, spring, nodePostgres, python, go, other
    }

    static func pool(files: [String], read: (String) -> String?) -> Pool {
        let manifests = files.filter { ["pom.xml", "build.gradle", "build.gradle.kts", "module.yaml", "package.json", "requirements.txt", "pyproject.toml", "go.mod"].contains(($0 as NSString).lastPathComponent) }
        let text = manifests.compactMap(read).joined(separator: "\n")
        if text.contains("spring-boot") { return .spring }
        if text.contains("HikariCP") || text.contains("hikari") { return .hikari }
        if text.contains("\"pg\"") || text.contains("postgres") && manifests.contains(where: { $0.hasSuffix("package.json") }) { return .nodePostgres }
        if text.contains("sqlalchemy") || text.contains("psycopg") || text.contains("django") { return .python }
        if manifests.contains(where: { $0.hasSuffix("go.mod") }) { return .go }
        return .other
    }

    static func isDatabase(_ service: String) -> Bool {
        ["db", "postgres", "mysql", "maria", "mongo", "database", "pg", "sql"].contains { service.lowercased().contains($0) }
    }

    public static func suggest(_ analysis: ChaosAnalysis, service: String, fault: ChaosFault, files: [String], read: (String) -> String?,
                               healthRoute: (file: String, line: Int)?) -> [ChaosSuggestion] {
        var found: [ChaosSuggestion] = []
        let failures = analysis.answers.reduce(0) { $0 + $1.count }
        func share(_ test: (String) -> Bool) -> Double {
            failures == 0 ? 0 : Double(analysis.answers.filter { test($0.text) }.reduce(0) { $0 + $1.count }) / Double(failures)
        }
        let timedOut = share { $0 == "timed out" }
        let serverErrors = share { $0 == "500" || $0 == "502" }
        let database = isDatabase(service)
        let pool = database ? pool(files: files, read: read) : .other

        if timedOut >= 0.3 {
            let fix: String = switch pool {
            case .hikari: "Give HikariCP a short connectionTimeout (2000 ms; the default is 30 s) and the JDBC URL a socketTimeout and connectTimeout, so a request without a database fails in seconds with a clear error."
            case .spring: "Set spring.datasource.hikari.connection-timeout=2000 (the default is 30 s) and add socketTimeout and connectTimeout to the JDBC URL."
            case .nodePostgres: "Set connectionTimeoutMillis (2000) and query_timeout on the pg Pool; without them a request waits for ever."
            case .python: "Set connect_timeout in the connection arguments and pool_timeout on the SQLAlchemy engine (a few seconds)."
            case .go: "Pass a context with a deadline (context.WithTimeout) to every query, and set the driver's connect_timeout."
            case .other: "Give every call to \(service) a short timeout, so requests fail fast instead of piling up."
            }
            found.append(ChaosSuggestion(title: "Fail fast instead of hanging",
                                         evidence: "\(Int((timedOut * 100).rounded()))% of the failures timed out: requests waited for \(service) rather than giving up.",
                                         fix: fix))
        }
        if serverErrors >= 0.3 {
            found.append(ChaosSuggestion(title: "Answer 503 with Retry-After",
                                         evidence: "Most failures were \(analysis.answers.first?.text ?? "500"), which reads as a bug in the app rather than a dependency being down.",
                                         fix: "Catch the \(service) connection errors in one place (Ktor's StatusPages, a Spring @ControllerAdvice, an Express error handler) and answer 503 with Retry-After and a short message, so clients and load balancers back off and retry."))
        }
        switch analysis.verdict {
        case .recovered(let seconds) where seconds > 5:
            let fix: String = switch pool {
            case .hikari, .spring: "Let the pool notice dead connections sooner: a keepaliveTime of 30 s, a validationTimeout of 1 s and a maxLifetime under the database's own idle limit. Connections broken by the outage are then replaced at once instead of failing one by one."
            case .nodePostgres: "Listen for the pool's error event and set idleTimeoutMillis, so broken clients are dropped and new ones made."
            case .python: "Turn on pool_pre_ping and a pool_recycle, so stale connections are checked before use."
            default: "Check connections before use and drop broken ones, so the app reconnects as soon as \(service) is back."
            }
            found.append(ChaosSuggestion(title: "Recover faster",
                                         evidence: "It took \(Int(seconds.rounded())) s after \(service) was back to answer normally again.",
                                         fix: fix))
        case .stayedBroken:
            found.append(ChaosSuggestion(title: "Reconnect on its own",
                                         evidence: "It was still failing when the watch ended, after \(service) was back.",
                                         fix: "Make the app reconnect: a pool that replaces broken connections, retries with backoff when it starts, and restart: unless-stopped in compose with a health check, so a stuck process is restarted."))
        default:
            break
        }
        if let health = healthRoute, database, analysis.outageFailing > 0.2,
           let text = read(health.file), let body = RouteFlow.block(in: text, line: health.line, python: health.file.hasSuffix(".py")),
           !["select", "isValid", "ping", "dataSource", "datasource", "database", "Database", "pool", "db."].contains(where: body.contains) {
            found.append(ChaosSuggestion(title: "Make the health check see \(service)",
                                         evidence: "The health route (\((health.file as NSString).lastPathComponent):\(health.line)) answers without touching \(service), so it said all was well while requests failed.",
                                         fix: "Add a readiness check that runs a cheap query (SELECT 1) with a short timeout and answers 503 when it fails. Keep the plain one for liveness, so a database outage doesn't restart the app."))
        }
        let compose = files.first { ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"].contains($0) }.flatMap(read)
        if let compose, database, !compose.contains("service_healthy") {
            found.append(ChaosSuggestion(title: "Start the app after \(service) is ready",
                                         evidence: "The compose file doesn't wait for \(service) to be healthy before starting what needs it.",
                                         fix: "Give \(service) a healthcheck (pg_isready for Postgres) and the app depends_on: \(service): condition: service_healthy, so a restart of both doesn't start with a burst of failures."))
        }
        if analysis.firstFailure.map({ $0 < 1 }) == true, database, failures > 0, analysis.outageFailing >= 0.95 {
            found.append(ChaosSuggestion(title: "Keep serving what doesn't need \(service)",
                                         evidence: "Every request failed while \(service) was down, even the first second.",
                                         fix: "Cache reads that change rarely (configuration, reference data) in memory with a short lifetime, so they're served while \(service) is away, and make health and static routes independent of it."))
        }
        return found
    }

    public static func brief(_ suggestion: ChaosSuggestion, service: String) -> String {
        """
        Bliksem broke \(service) under load. \(suggestion.evidence)
        Please make this change: \(suggestion.title). \(suggestion.fix)
        Find where it belongs in this codebase, keep the change small, and say how to check it (Bliksem's Break things can run again).
        """
    }
}
