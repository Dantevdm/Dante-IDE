import Foundation

/// One line of `docker compose logs`, split into the parts the Env area shows apart.
public struct LogLine: Equatable, Sendable, Identifiable {
    public enum Level: Int, Sendable, Comparable, CaseIterable {
        case debug, info, warning, error

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: Int
    public var service: String
    /// The app's own timestamp at the start of the line, when it printed one.
    public var timestamp: String?
    /// The rest of the line.
    public var message: String
    public var level: Level
    /// A successful HTTP request the line logs, found once when it's parsed.
    public var request: Request?

    public struct Request: Equatable, Sendable {
        public var path: String
        /// Made from inside the container, where health checks run.
        public var fromInside: Bool
    }

    public init(id: Int, service: String, timestamp: String? = nil, message: String, level: Level = .info) {
        self.id = id
        self.service = service
        self.timestamp = timestamp
        self.message = message
        self.level = level
        request = Self.request(in: message)
    }

    /// Gin, nginx, Apache and most access logs carry the method, the path and the status
    /// on one line. Nil unless the request succeeded.
    static func request(in message: String) -> Request? {
        guard message.contains("GET") || message.contains("HEAD") || message.contains("POST") || message.contains("OPTIONS"),
              let match = message.firstMatch(of: /\b(?:GET|HEAD|OPTIONS|POST)\s+"?(\/[^\s"?]*)/),
              message.contains(/(?:^|[\s|"])[23]\d\d(?:[\s|]|$)/) else { return nil }
        let fromInside = message.contains(/(?:^|[\s|])(?:127\.0\.0\.1|::1|localhost)(?:[\s|:]|$)/)
        return Request(path: String(match.1), fromInside: fromInside)
    }

    /// Compose prefixes each line with "service  | " (or "service-1  | " in some
    /// releases) when following more than one service.
    public static func parse(_ raw: String, id: Int, service fallback: String) -> LogLine {
        var service = fallback
        var text = raw
        if let bar = raw.range(of: " | ") ?? (raw.hasSuffix(" |") ? raw.range(of: " |", options: .backwards) : nil) {
            let name = raw[..<bar.lowerBound].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains(" "), name.count < 64 {
                service = name.replacing(/-\d+$/, with: "")
                text = String(raw[bar.upperBound...])
            }
        }
        var timestamp: String?
        if let match = text.prefixMatch(of: timestampPattern) {
            timestamp = String(match.output).trimmingCharacters(in: .whitespaces)
            text = String(text[match.range.upperBound...])
        }
        return LogLine(id: id, service: service, timestamp: timestamp, message: text, level: level(of: text))
    }

    // 2026/10/09 09:54:14, 2026-10-09T09:54:14.123Z, [2026-10-09 09:54:14,123], 09:54:14.123
    nonisolated(unsafe) static let timestampPattern = /\[?(?:\d{4}[-\/]\d{2}[-\/]\d{2}[T ])?\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?\]?\s+/

    static func level(of text: String) -> Level {
        let lower = text.lowercased()
        func has(_ words: [String]) -> Bool {
            words.contains { word in
                lower.contains("level=\(word)") || lower.contains("[\(word)]") || lower.contains("\"level\":\"\(word)") ||
                    lower.hasPrefix(word + " ") || lower.hasPrefix(word + ":") || lower.contains(" \(word) ") || lower.contains(" \(word):")
            }
        }
        if has(["error", "err", "fatal", "panic", "critical", "crit"]) || lower.hasPrefix("panic") || lower.contains("exception") || lower.contains("traceback") { return .error }
        if has(["warn", "warning", "wrn"]) { return .warning }
        if has(["debug", "dbg", "trace"]) { return .debug }
        return .info
    }
}

/// What the logs view shows: a text search and a lowest level.
public struct LogFilter: Equatable, Sendable {
    public var query: String
    public var minimum: LogLine.Level
    /// Show only lines that match, or all lines with matches highlighted.
    public var onlyMatches: Bool
    /// Leave out successful requests made by health checks, which arrive every few seconds.
    public var hidesHealthChecks: Bool
    /// Paths the project's health checks call, beside the usual /health, /ready and so on.
    public var healthPaths: Set<String>

    public init(query: String = "", minimum: LogLine.Level = .debug, onlyMatches: Bool = true,
                hidesHealthChecks: Bool = true, healthPaths: Set<String> = []) {
        self.query = query
        self.minimum = minimum
        self.onlyMatches = onlyMatches
        self.hidesHealthChecks = hidesHealthChecks
        self.healthPaths = healthPaths
    }

    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    public func matches(_ line: LogLine) -> Bool {
        isSearching ? Self.ranges(of: query, in: line.searchText).isEmpty == false : false
    }

    public func apply(_ lines: [LogLine]) -> [LogLine] {
        lines.filter { line in
            line.level >= minimum && (!isSearching || !onlyMatches || matches(line))
                && !(hidesHealthChecks && line.isHealthCheck(paths: healthPaths))
        }
    }

    /// How many of `lines` are health check requests.
    public func healthCheckCount(in lines: [LogLine]) -> Int {
        lines.count { $0.isHealthCheck(paths: healthPaths) }
    }

    static let commonHealthPaths: Set<String> = ["/health", "/healthz", "/healthcheck", "/ready", "/readyz", "/live", "/livez", "/ping", "/status", "/api/health"]

    /// Paths of the local URLs in a compose file, which are its health checks' targets:
    /// `curl -sf http://localhost:3000/api/stats` gives "/api/stats".
    public static func healthPaths(composeText text: String) -> Set<String> {
        var paths: Set<String> = []
        for match in text.matches(of: /https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?(\/[^\s"',\]?#]*)?/) {
            paths.insert(match.1.map(String.init) ?? "/")
        }
        return paths
    }

    /// Case-insensitive ranges of the query in some text, for highlighting.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            found.append(range)
            start = range.upperBound
        }
        return found
    }
}

extension LogLine {
    /// A successful HTTP request from inside the container (a health check runs there) or
    /// to a health check path.
    public func isHealthCheck(paths: Set<String> = []) -> Bool {
        guard let request else { return false }
        return request.fromInside || paths.contains(request.path) || LogFilter.commonHealthPaths.contains(request.path)
    }

    /// What a search looks in.
    public var searchText: String { [timestamp, message].compactMap { $0 }.joined(separator: " ") }
}
