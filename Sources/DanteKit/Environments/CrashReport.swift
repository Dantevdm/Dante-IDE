import Foundation

/// Why a service went down, read from its last log lines: the line that names the error,
/// a short excerpt of the last crash around it, and the brief that asks an agent to fix
/// the cause. A crash loop prints the same failure each time, so only the last one is kept.
public struct CrashReport: Equatable, Sendable {
    public var service: String
    /// What Keep running saw: "It crashed (exit 1)", "Unhealthy for 3 minutes".
    public var reason: String
    /// The line that says what went wrong, when one does.
    public var headline: String?
    /// The last crash's lines, without compose's prefixes and timestamps.
    public var excerpt: [String]

    public static let excerptLimit = 40

    public init(service: String, reason: String, headline: String?, excerpt: [String]) {
        self.service = service
        self.reason = reason
        self.headline = headline
        self.excerpt = excerpt
    }

    /// Reads `docker compose logs --no-color --tail N <service>` output.
    public static func read(service: String, reason: String, logs: String) -> CrashReport {
        let lines = logs.split(whereSeparator: \.isNewline).enumerated()
            .map { LogLine.parse(String($0.element), id: $0.offset, service: service) }
            .filter { !$0.message.trimmingCharacters(in: .whitespaces).isEmpty }
        let messages = lines.map(\.message)
        // The last crash starts after the last line that came before an earlier one's error
        // repeated: find the newest error, then the first line of its run of errors.
        guard let last = lines.lastIndex(where: { $0.level == .error || isFailure($0.message) || names($0.message) }) else {
            return CrashReport(service: service, reason: reason, headline: nil, excerpt: Array(messages.suffix(12)))
        }
        var first = last
        while first > 0, lines[first - 1].level == .error || isFailure(lines[first - 1].message) || names(lines[first - 1].message) || isTrace(lines[first - 1].message) { first -= 1 }
        // Python names the error last, after its traceback; Node and Go name it first.
        let headlineIndex = (first...last).last { names(messages[$0]) } ?? (first...last).first { isHeadline(messages[$0]) } ?? first
        // Up to five lines of lead-in, stopping at the crash before this one.
        var start = first
        while start > 0, first - start < 5, !isError(lines[start - 1]) { start -= 1 }
        let end = min(messages.count, max(last + 1, start + 1) + 3)
        var excerpt = Array(messages[start..<end])
        if excerpt.count > excerptLimit { excerpt = Array(excerpt.prefix(excerptLimit / 2)) + ["…"] + Array(excerpt.suffix(excerptLimit / 2 - 1)) }
        return CrashReport(service: service, reason: reason, headline: messages[headlineIndex].trimmingCharacters(in: .whitespaces), excerpt: excerpt)
    }

    /// What Dante says on the Services page: the headline, shortened.
    public var summary: String? {
        guard let headline else { return nil }
        return headline.count > 140 ? String(headline.prefix(139)) + "…" : headline
    }

    /// The request to the agent in charge.
    public var brief: String {
        var text = "Keep running restarted the \(service) service, but it keeps going down. \(reason)."
        if let headline { text += " The logs say: \(headline)" }
        text += "\n\nThe end of its logs:\n```\n" + excerpt.joined(separator: "\n") + "\n```\n\n"
        text += "Find the cause in the code, the Dockerfile or docker-compose.yml, and fix it. Show the fix as a diff; don't restart or rebuild anything yourself, Dante does that once the fix is in."
        return text
    }

    /// Lines that read as the error itself rather than the trace under it.
    static func isHeadline(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !isTrace(trimmed) && !trimmed.lowercased().hasPrefix("traceback")
    }

    static func isError(_ line: LogLine) -> Bool {
        line.level == .error || isFailure(line.message) || names(line.message) || isTrace(line.message)
    }

    /// `ValueError: bad`, `Error: Cannot find module 'x'`, `panic: nil map`, `java.lang.IllegalStateException: …`.
    static func names(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("panic:") || trimmed.hasPrefix("fatal error:") || trimmed.hasPrefix("FATAL") { return true }
        return trimmed.prefixMatch(of: /(?:[A-Za-z_][\w.$]*\.)?[A-Z]\w*(?:Error|Exception)(?::|$)/) != nil
    }

    static func isFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["exception", "panic:", "fatal", "segmentation fault", "cannot find module", "no such file", "connection refused",
                "address already in use", "permission denied", "exited with code", "killed", "out of memory"].contains { lower.contains($0) }
    }

    /// Stack frames: `    at foo (file.js:1:2)`, `  File "x.py", line 3`, `goroutine 1 [running]:`, `\tmain.go:12`.
    static func isTrace(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return text.hasPrefix(" ") || trimmed.hasPrefix("at ") || trimmed.hasPrefix("File \"") || trimmed.hasPrefix("goroutine ") || text.hasPrefix("\t")
            || trimmed.hasPrefix("...") || trimmed.hasPrefix("^") || trimmed.hasPrefix("Caused by:")
    }
}
