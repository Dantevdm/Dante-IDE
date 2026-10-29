import Foundation

/// Who ran a set of tests: you from the Tests page, the agent in charge, a job, or CI.
public struct TestRunner: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case you, agent, job, ci
    }

    public var kind: Kind
    /// "Claude", "Codex", a job's title, a workflow's name; empty for you.
    public var name: String

    public init(_ kind: Kind, name: String = "") {
        self.kind = kind
        self.name = name
    }

    public static let you = TestRunner(.you)

    /// "You", "Claude", "Job: Fix the login loop".
    public var label: String {
        switch kind {
        case .you: "You"
        case .agent: name.isEmpty ? "The agent" : name
        case .job: name.isEmpty ? "A job" : "Job: \(name)"
        case .ci: name.isEmpty ? "CI" : "CI: \(name)"
        }
    }
}

/// One run, kept whole: every result with its issues, so the Tests page can show any run
/// again after a restart and the test map can tell each test's last result.
public struct SavedTestRun: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var date: Date
    public var by: TestRunner
    /// The command as run (`swift test`, `go test ./...`).
    public var command: String
    public var results: [TestResult]
    public var duration: TimeInterval
    /// Failed without a failing test: the build broke or the runner crashed.
    public var brokeOutsideTests: Bool
    /// The run asked for only some tests (a filter, one file): it says nothing about the rest.
    public var narrowed: Bool
    /// For a run that failed outside its tests: the lines naming why, then the end (`BrokenRunLines`).
    public var tail: [String]

    public init(id: String = UUID().uuidString, date: Date, by: TestRunner, command: String, results: [TestResult], duration: TimeInterval = 0,
                brokeOutsideTests: Bool = false, narrowed: Bool = false, tail: [String] = []) {
        self.id = id
        self.date = date
        self.by = by
        self.command = command
        self.results = results
        self.duration = duration
        self.brokeOutsideTests = brokeOutsideTests
        self.narrowed = narrowed
        self.tail = tail
    }

    public var passed: Int { results.count { $0.status == .passed } }
    public var failed: Int { results.count { $0.status == .failed } }
    public var skipped: Int { results.count { $0.status == .skipped } }
    public var succeeded: Bool { failed == 0 && !brokeOutsideTests }
    public var failures: [TestResult] { results.filter { $0.status == .failed } }

    /// The count-only history entry Home, the timeline and the morning update read.
    public var record: TestRecord {
        TestRecord(date: date, label: narrowed ? "\(command) · some tests" : command, passed: passed, failed: failed, skipped: skipped,
                   duration: duration, brokeOutsideTests: brokeOutsideTests, failedTests: failures.map(\.id))
    }

    /// A test command an agent ran, read from its output. Nil when the output shows no
    /// results and the command didn't fail (it listed tests, or printed nothing useful).
    public static func reading(command: String, output: String, failed: Bool, by runner: TestRunner, date: Date = .now) -> SavedTestRun? {
        var parser = TestOutputParser()
        let lines = output.components(separatedBy: "\n")
        for line in lines { parser.consume(line) }
        let results = parser.results
        let failing = results.contains { $0.status == .failed }
        guard !results.isEmpty || failed else { return nil }
        let summary = TestOutputSummary.duration(in: lines)
        return SavedTestRun(date: date, by: runner, command: command.trimmingCharacters(in: .whitespacesAndNewlines), results: results,
                            duration: summary ?? 0, brokeOutsideTests: failed && !failing, narrowed: TestCommandLine.isNarrowed(command),
                            tail: failed && !failing ? BrokenRunLines.pick(lines) : [])
    }
}

/// Every test run on this Mac for a project, whoever ran it, newest last. Kept in
/// Application Support/Dante/tests, never in the repo.
public enum TestRunLog {
    public static let limit = 40

    public static func url(for root: URL, in folder: URL = defaultFolder()) -> URL {
        let path = root.standardizedFileURL.path
        return folder.appending(path: "\(root.lastPathComponent)-\(String(SemanticIndex.hash(path), radix: 16)).json")
    }

    public static func defaultFolder() -> URL {
        URL.applicationSupportDirectory.appending(path: "Dante/tests", directoryHint: .isDirectory)
    }

    public static func load(for root: URL, in folder: URL = defaultFolder()) -> [SavedTestRun] {
        guard let data = try? Data(contentsOf: url(for: root, in: folder)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([SavedTestRun].self, from: data)) ?? []).sorted { $0.date < $1.date }
    }

    /// Adds a run (and its count-only `TestRecord`), keeping the newest `limit`.
    public static func append(_ run: SavedTestRun, for root: URL, in folder: URL = defaultFolder(), defaults: UserDefaults = .standard) {
        var runs = load(for: root, in: folder)
        runs.append(run)
        runs = Array(runs.sorted { $0.date < $1.date }.suffix(limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(runs) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url(for: root, in: folder), options: .atomic)
        }
        run.record.append(for: root, defaults: defaults)
        NotificationCenter.default.post(name: changed, object: root.standardizedFileURL.path)
    }

    /// Posted with the project's path after each run is saved, so an open Tests page reloads.
    public static let changed = Notification.Name("DanteTestRunLogChanged")
}

/// Recognises a test command in a shell line an agent ran.
public enum TestCommandLine {
    /// Runner invocations, matched as whole words at the start of a command or after `&&`, `;`, `|` or `cd … &&`.
    static let runners: [[String]] = [
        ["swift", "test"], ["go", "test"], ["cargo", "test"], ["cargo", "nextest"], ["pytest"], ["python", "-m", "pytest"], ["python3", "-m", "pytest"],
        ["uv", "run", "pytest"], ["poetry", "run", "pytest"], ["npm", "test"], ["npm", "run", "test"], ["npm", "t"], ["pnpm", "test"], ["pnpm", "run", "test"],
        ["yarn", "test"], ["bun", "test"], ["npx", "jest"], ["npx", "vitest"], ["jest"], ["vitest"], ["mvn", "test"], ["mvn", "verify"],
        ["./mvnw", "test"], ["./mvnw", "verify"], ["gradle", "test"], ["./gradlew", "test"], ["dotnet", "test"], ["xcodebuild", "test"],
        ["rspec"], ["bundle", "exec", "rspec"], ["mix", "test"], ["deno", "test"], ["scripts/kit-tests.sh"],
    ]

    /// Whether `command` runs tests. `projectCommand` is the project's own `test.command`, which counts too.
    public static func runsTests(_ command: String, projectCommand: String? = nil) -> Bool {
        let flat = command.replacingOccurrences(of: "\n", with: " ")
        if let projectCommand, !projectCommand.isEmpty, flat.contains(projectCommand) { return true }
        for part in parts(flat) {
            var words = part.split(whereSeparator: \.isWhitespace).map(String.init)
            // Environment assignments and wrappers before the runner.
            while let first = words.first, first.contains("=") && !first.hasPrefix("-") || ["env", "time", "caffeinate", "nice"].contains(first) {
                words.removeFirst()
            }
            if words.first == "mvn" || words.first == "./mvnw", words.contains("test") || words.contains("verify") { return true }
            if words.first == "gradle" || words.first == "./gradlew", words.contains("test") { return true }
            if runners.contains(where: { runner in words.count >= runner.count && Array(words.prefix(runner.count)) == runner }) { return true }
        }
        return false
    }

    /// Asked for only some tests: a filter, a `-run`, `-k`, `-t`, or test files named.
    public static func isNarrowed(_ command: String) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.contains(where: { ["--filter", "-run", "-k", "-t", "--testNamePattern", "-Dtest", "--tests", "--only"].contains($0) || $0.hasPrefix("-Dtest=") || $0.hasPrefix("--filter=") || $0.hasPrefix("-run=") }) {
            return true
        }
        return words.contains { word in
            let lower = word.lowercased()
            return lower.hasSuffix(".py") || lower.contains(".test.") || lower.contains(".spec.") || lower.hasSuffix("_test.go") || lower.contains(".py::")
        }
    }

    /// A shell line cut at `&&`, `||`, `;` and `|`.
    static func parts(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var characters = Array(line)[...]
        while let character = characters.popFirst() {
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == ";" || character == "|" || character == "&" {
                if let next = characters.first, next == character { characters.removeFirst() }
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("cd ") }
    }
}

/// Totals runners print at the end, read when the per-test lines aren't enough.
enum TestOutputSummary {
    /// "after 2.168 seconds", "Executed 12 tests, … in 0.5 (0.6) seconds", "ok pkg 0.12s", "in 1.23s".
    static func duration(in lines: [String]) -> TimeInterval? {
        for line in lines.reversed() {
            if line.contains("Test run with"), let match = line.firstMatch(of: /after ([\d.]+) seconds/) { return Double(match.1) }
            if let match = line.firstMatch(of: /=+ .* in ([\d.]+)s/) { return Double(match.1) }
            if let match = line.firstMatch(of: /^Time:\s+([\d.]+)\s*s/) { return Double(match.1) }
        }
        return nil
    }
}
