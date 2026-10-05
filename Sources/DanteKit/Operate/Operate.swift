import Foundation
import Observation

/// Polls the health checks from `operate.checks` and keeps a short history of each.
@MainActor
@Observable
public final class HealthMonitor {
    public struct Sample: Equatable, Sendable {
        public var date: Date
        /// The HTTP status, or nil when the request failed outright.
        public var status: Int?
        public var milliseconds: Double?
        public var error: String?

        public var isUp: Bool { status.map { (200..<400).contains($0) } ?? false }
    }

    public private(set) var samples: [String: [Sample]] = [:]
    public private(set) var checks: [ProjectInfo.HealthCheck] = []
    private var task: Task<Void, Never>?
    public static let historyLimit = 60

    public init() {}

    /// Starts polling every `interval` seconds; calling again with new checks restarts it.
    public func watch(_ checks: [ProjectInfo.HealthCheck], every interval: Duration = .seconds(15)) {
        guard checks != self.checks || task == nil else { return }
        self.checks = checks
        samples = samples.filter { key, _ in checks.contains { $0.id == key } }
        task?.cancel()
        guard !checks.isEmpty else { task = nil; return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func poll() async {
        await withTaskGroup(of: (String, Sample).self) { group in
            for check in checks {
                group.addTask { (check.id, await Self.probe(check.url)) }
            }
            for await (id, sample) in group {
                var history = samples[id, default: []]
                history.append(sample)
                if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
                samples[id] = history
            }
        }
    }

    nonisolated static func probe(_ url: URL) async -> Sample {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        let start = ContinuousClock.now
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsed = ContinuousClock.now - start
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            return Sample(date: .now, status: (response as? HTTPURLResponse)?.statusCode, milliseconds: milliseconds)
        } catch {
            return Sample(date: .now, status: nil, milliseconds: nil, error: error.localizedDescription)
        }
    }
}

/// Groups error lines from a log stream into issues: the same error with different
/// timestamps, ids or numbers counts as one.
public struct ErrorDigest: Equatable, Sendable {
    public struct Issue: Equatable, Sendable, Identifiable {
        public var signature: String
        /// The most recent line, as logged.
        public var example: String
        public var count: Int
        public var lastSeen: Date
        public var id: String { signature }

        /// The latest line without its leading timestamp, for task titles.
        public var summary: String {
            let stripped = example.replacing(/^\s*\[?\d{4}-\d{2}-\d{2}[T ][\d:.]+(?:Z|[+-]\d{2}:?\d{2})?\]?\s*/, with: "")
                .replacing(/^\s*\[?\d{1,2}:\d{2}:\d{2}(?:\.\d+)?\]?\s*/, with: "")
            return stripped.count > 90 ? String(stripped.prefix(90)) + "…" : stripped
        }
    }

    public private(set) var issues: [Issue] = []
    public private(set) var linesSeen = 0

    public init() {}

    public static func isError(_ line: String) -> Bool {
        line.firstMatch(of: #/(?i)\b(error|exception|fatal|panic|traceback|unhandled|crash(ed)?)\b|\b[A-Z]\w*(?:Error|Exception)\b|\b(ERR|E\d{4})\b|"\s5\d\d\s/#) != nil
    }

    /// The line with the parts that vary between occurrences replaced.
    public static func signature(_ line: String) -> String {
        var text = line
        let patterns: [Regex<Substring>] = [
            /\d{4}-\d{2}-\d{2}[T ][\d:.]+(?:Z|[+-]\d{2}:?\d{2})?/,      // ISO timestamps
            /\d{1,2}:\d{2}:\d{2}(?:\.\d+)?/,                              // times
            /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/, // UUIDs
            /0x[0-9a-fA-F]+/,                                           // addresses
            /\b[0-9a-f]{12,}\b/,                                        // hashes and request ids
            /\d+/,                                                      // other numbers
        ]
        for pattern in patterns { text = text.replacing(pattern, with: "#") }
        return text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
    }

    public mutating func consume(_ line: String, at date: Date = .now) {
        linesSeen += 1
        guard Self.isError(line) else { return }
        let signature = Self.signature(line)
        if let index = issues.firstIndex(where: { $0.signature == signature }) {
            issues[index].count += 1
            issues[index].example = line
            issues[index].lastSeen = date
        } else {
            issues.append(Issue(signature: signature, example: line, count: 1, lastSeen: date))
        }
        issues.sort { $0.count != $1.count ? $0.count > $1.count : $0.lastSeen > $1.lastSeen }
    }
}

/// Follows the `operate.logs` command and digests its errors.
@MainActor
@Observable
public final class LogWatch {
    public let command: String
    public private(set) var digest = ErrorDigest()
    public private(set) var recent: [String] = []
    public private(set) var exitMessage: String?
    public private(set) var isRunning = false
    private var process: Shell.Running?

    public init(command: String, projectRoot root: URL) {
        self.command = command
        do {
            let running = try Shell.stream(["sh", "-c", command], in: root)
            process = running
            isRunning = true
            Task { await self.read(running) }
        } catch {
            exitMessage = "Couldn’t run \(command): \(error.localizedDescription)"
        }
    }

    public func stop() {
        process?.terminate()
    }

    private func read(_ running: Shell.Running) async {
        for await line in running.lines {
            digest.consume(line)
            recent.append(line)
            if recent.count > 500 { recent.removeFirst(recent.count - 500) }
        }
        while running.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        isRunning = false
        exitMessage = running.status == 0 ? "The log command finished." : "The log command exited with status \(running.status)."
    }
}
