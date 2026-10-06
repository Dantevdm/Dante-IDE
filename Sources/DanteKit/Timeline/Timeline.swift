import Foundation

/// One thing that happened to the project, for the Timeline.
public struct TimelineEvent: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case commit, release, claude, tests, ci
    }

    public enum Outcome: Equatable, Sendable {
        case good, bad, neutral, running
    }

    public var id: String
    public var kind: Kind
    public var date: Date
    public var title: String
    public var detail: String?
    public var outcome: Outcome = .neutral
    /// A commit hash, a Claude session id, or a CI run's address: what opening the event needs.
    public var reference: String?
    /// A one-prompt Claude session: Dante's own commit messages, drafts and inline edits.
    public var isQuick = false

    public init(id: String, kind: Kind, date: Date, title: String, detail: String? = nil, outcome: Outcome = .neutral,
                reference: String? = nil, isQuick: Bool = false) {
        self.id = id
        self.kind = kind
        self.date = date
        self.title = title
        self.detail = detail
        self.outcome = outcome
        self.reference = reference
        self.isQuick = isQuick
    }
}

public enum Timeline {
    /// Everything Dante can find, newest first.
    @MainActor
    public static func load(root: URL, tests: [TestRecord], ci: [CIRun], claudeFolder: URL? = nil, commitLimit: Int = 200) async -> [TimelineEvent] {
        let folder = claudeFolder ?? ClaudeTranscripts.folder(for: root)
        async let log = Shell.run(["git", "log", "-n", "\(commitLimit)", "--format=%H%x1f%s%x1f%an%x1f%cI%x1f%D"], in: root)
        let sessions = await Task.detached { ClaudeTranscripts.sessions(in: folder) }.value
        var events = commits(from: await log.stdout)
        events += sessions
        events += tests.map(\.event)
        events += ci.compactMap(event(for:))
        return events.sorted { $0.date > $1.date }
    }

    /// Commits, and a release event for each tag one carries.
    static func commits(from output: String) -> [TimelineEvent] {
        let formatter = ISO8601DateFormatter()
        var events: [TimelineEvent] = []
        for line in output.components(separatedBy: "\n") {
            let fields = line.components(separatedBy: "\u{1F}")
            guard fields.count >= 4, let date = formatter.date(from: fields[3]) else { continue }
            let hash = fields[0]
            events.append(TimelineEvent(id: "commit:\(hash)", kind: .commit, date: date, title: fields[1],
                                        detail: "\(fields[2]) · \(hash.prefix(7))", reference: hash))
            let decorations = fields.count > 4 ? fields[4].components(separatedBy: ", ") : []
            for tag in decorations where tag.hasPrefix("tag: ") {
                let name = String(tag.dropFirst(5))
                events.append(TimelineEvent(id: "tag:\(name)", kind: .release, date: date.addingTimeInterval(1), title: "Tagged \(name)",
                                            detail: fields[1], outcome: .good, reference: name))
            }
        }
        return events
    }

    static func event(for run: CIRun) -> TimelineEvent? {
        guard let date = run.created else { return nil }
        let outcome: TimelineEvent.Outcome = run.isRunning ? .running : run.succeeded ? .good : ["skipped", "cancelled", "neutral"].contains(run.conclusion) ? .neutral : .bad
        let state = run.isRunning ? "running" : run.conclusion.isEmpty ? run.status : run.conclusion
        return TimelineEvent(id: "ci:\(run.id)", kind: .ci, date: date, title: "\(run.workflow): \(run.title)",
                             detail: "\(run.branch) · \(state)", outcome: outcome, reference: run.url?.absoluteString)
    }
}

/// A finished test run, kept per project on this Mac.
public struct TestRecord: Codable, Equatable, Sendable {
    public var date: Date
    public var label: String
    public var passed: Int
    public var failed: Int
    public var skipped: Int
    public var duration: TimeInterval
    /// Failed without a failing test: the build broke or the runner crashed.
    public var brokeOutsideTests: Bool

    public init(date: Date, label: String, passed: Int, failed: Int, skipped: Int, duration: TimeInterval, brokeOutsideTests: Bool = false) {
        self.date = date
        self.label = label
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.duration = duration
        self.brokeOutsideTests = brokeOutsideTests
    }

    public var succeeded: Bool { failed == 0 && !brokeOutsideTests }

    var event: TimelineEvent {
        let title = brokeOutsideTests ? "Tests didn’t run: the build or runner failed"
            : failed > 0 ? "\(failed) test\(failed == 1 ? "" : "s") failed" : "\(passed) test\(passed == 1 ? "" : "s") passed"
        var detail = "\(label) · \(Int(duration.rounded()))s"
        if failed > 0 { detail += " · \(passed) passed" }
        if skipped > 0 { detail += " · \(skipped) skipped" }
        return TimelineEvent(id: "tests:\(date.timeIntervalSince1970)", kind: .tests, date: date, title: title, detail: detail,
                             outcome: succeeded ? .good : .bad)
    }

    static let key = "testHistory"
    static let limit = 100

    public static func load(for root: URL, defaults: UserDefaults = .standard) -> [TestRecord] {
        guard let data = defaults.dictionary(forKey: key)?[root.standardizedFileURL.path] as? Data else { return [] }
        return (try? JSONDecoder().decode([TestRecord].self, from: data)) ?? []
    }

    /// Adds this run to the project's history, keeping the newest hundred.
    public func append(for root: URL, defaults: UserDefaults = .standard) {
        var records = Self.load(for: root, defaults: defaults)
        records.append(self)
        guard let data = try? JSONEncoder().encode(Array(records.suffix(Self.limit))) else { return }
        var all = defaults.dictionary(forKey: Self.key) ?? [:]
        all[root.standardizedFileURL.path] = data
        defaults.set(all, forKey: Self.key)
    }
}

/// Claude Code's transcripts for a project: `~/.claude/projects/<path with every
/// other character as ->/<session>.jsonl`.
public enum ClaudeTranscripts {
    public static func folder(for root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".claude/projects").appending(path: encode(root.standardizedFileURL.path))
    }

    static func encode(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The sessions in a folder, newest first, at most `limit`.
    public static func sessions(in folder: URL, limit: Int = 60) -> [TimelineEvent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        return newest.compactMap { file, _ in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return session(id: file.deletingPathExtension().lastPathComponent, transcript: text)
        }
    }

    /// Reads a transcript: its title (set by the user, else the first prompt), when it
    /// started and ended, and how many prompts the person typed.
    public static func session(id: String, transcript: String) -> TimelineEvent? {
        var first: Date?
        var last: Date?
        var title: String?
        var customTitle: String?
        var prompts = 0
        var edits = 0
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            if let stamp = timestamp(in: line), let date = formatter.date(from: stamp) {
                if first == nil { first = date }
                last = date
            }
            if line.contains("\"type\":\"custom-title\""), let value = JSONValue(line: String(line))?["customTitle"]?.string {
                customTitle = value
                continue
            }
            if line.contains("\"name\":\"Edit\"") || line.contains("\"name\":\"Write\"") || line.contains("\"name\":\"MultiEdit\"") {
                edits += 1
            }
            // Typed prompts are user messages whose content is a plain string.
            guard line.contains("\"type\":\"user\""), line.contains("\"content\":\""), !line.contains("\"isMeta\":true"),
                  let value = JSONValue(line: String(line)), value["type"]?.string == "user",
                  let content = value["message"]?["content"]?.string else { continue }
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Command output and system notes come wrapped in tags.
            guard !text.isEmpty, !text.hasPrefix("<") else { continue }
            prompts += 1
            if title == nil { title = text }
        }
        guard let start = first, let name = customTitle ?? title else { return nil }
        let oneLine = name.replacingOccurrences(of: "\n", with: " ")
        let shortTitle = oneLine.count > 90 ? String(oneLine.prefix(89)) + "…" : oneLine
        let minutes = Int(((last ?? start).timeIntervalSince(start) / 60).rounded())
        var detail = "\(prompts) prompt\(prompts == 1 ? "" : "s")"
        if minutes > 0 { detail += " · \(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min")" }
        if edits > 0 { detail += " · \(edits) edit\(edits == 1 ? "" : "s")" }
        return TimelineEvent(id: "claude:\(id)", kind: .claude, date: last ?? start, title: shortTitle, detail: detail,
                             reference: id, isQuick: prompts <= 1 && customTitle == nil)
    }

    private static func timestamp(in line: Substring) -> String? {
        guard let range = line.range(of: "\"timestamp\":\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
