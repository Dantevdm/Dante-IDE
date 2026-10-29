import Foundation
import Observation
import Yams

/// How a project runs its tests: `test.command` in project.yaml, or worked out from
/// the files at the root.
public struct TestCommand: Equatable, Sendable {
    public var label: String
    public var arguments: [String]
    /// Whether Dante asks the runner for an xUnit report it can read suites from.
    public var readsXUnit: Bool
    /// Folders (relative to the project) where the runner writes JUnit XML, read after the
    /// run for the tests it only counted (Maven, Gradle).
    public var reportFolders: [String] = []

    public static func detect(projectRoot root: URL) -> TestCommand? {
        if let command = custom(projectRoot: root) { return command }
        if let command = runner(in: root) { return command }
        // A repo of apps side by side (`api/` with a pom.xml, `web/` with package.json): run each in its folder.
        let folders = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !$0.lastPathComponent.hasPrefix(".") && !skippedFolders.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let found = folders.compactMap { folder in runner(in: folder).map { (folder.lastPathComponent, $0) } }
        guard !found.isEmpty else { return nil }
        if found.count == 1, let (folder, command) = found.first {
            return TestCommand(label: "\(command.label) in \(folder)", arguments: ["sh", "-c", "cd \(Shell.quote(folder)) && " + command.script],
                               readsXUnit: command.readsXUnit)
        }
        // Every folder runs even when one fails, and the run fails if any did.
        let script = "status=0; " + found.map { "(cd \(Shell.quote($0.0)) && \($0.1.script)) || status=1; " }.joined() + "exit $status"
        return TestCommand(label: found.map { "\($0.1.label) in \($0.0)" }.joined(separator: " · "), arguments: ["sh", "-c", script], readsXUnit: false)
    }

    /// `test.command` from project.yaml, which wins over anything detected.
    public static func custom(projectRoot root: URL) -> TestCommand? {
        guard let yaml = try? String(contentsOf: root.appending(path: ".dante/project.yaml"), encoding: .utf8),
              let project = (try? SafeYAML.load(yaml)) as? [String: Any],
              let test = project["test"] as? [String: Any], let command = test["command"] as? String, !command.isEmpty else { return nil }
        return TestCommand(label: command, arguments: ["sh", "-c", verbose(command)], readsXUnit: false)
    }

    static let skippedFolders: Set<String> = ["node_modules", "vendor", "build", "dist", "target", "docs", "Pods", "venv"]

    /// The runner for the files in one folder.
    static func runner(in root: URL) -> TestCommand? {
        let fileManager = FileManager.default
        func has(_ name: String) -> Bool { fileManager.fileExists(atPath: root.appending(path: name).path) }

        if has("Package.swift") { return TestCommand(label: "swift test", arguments: ["swift", "test"], readsXUnit: true) }
        if has("Cargo.toml") { return TestCommand(label: "cargo test", arguments: ["cargo", "test"], readsXUnit: false) }
        if has("go.mod") { return TestCommand(label: "go test -v ./...", arguments: ["go", "test", "-v", "./..."], readsXUnit: false) }
        if has("pom.xml") {
            let maven = has("mvnw") ? "./mvnw" : "mvn"
            return TestCommand(label: "\(maven) test", arguments: [maven, "-B", "test"], readsXUnit: false)
        }
        if has("build.gradle") || has("build.gradle.kts") {
            let gradle = has("gradlew") ? "./gradlew" : "gradle"
            return TestCommand(label: "\(gradle) test", arguments: [gradle, "test"], readsXUnit: false)
        }
        if has("package.json"),
           let data = fileManager.contents(atPath: root.appending(path: "package.json").path),
           let package = JSONValue(line: String(decoding: data, as: UTF8.self)),
           let script = package["scripts"]?["test"]?.string, !script.contains("no test specified") {
            let runner = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") ? "bun" : "npm"
            return TestCommand(label: "\(runner) test", arguments: [runner, "test"], readsXUnit: false)
        }
        if has("pytest.ini") || has("pyproject.toml") || has("setup.py") || has("tox.ini") || has("requirements.txt") && hasPythonTests(root) {
            return TestCommand(label: "pytest -v", arguments: ["python3", "-m", "pytest", "-v"], readsXUnit: false)
        }
        return nil
    }

    /// A requirements.txt alone only means pytest when there are test files to run.
    static func hasPythonTests(_ root: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.contains { $0 == "tests" || $0 == "test" || $0.hasPrefix("test_") && $0.hasSuffix(".py") }
    }

    /// The command as one line for `sh -c`.
    var script: String {
        arguments.first == "sh" && arguments.count == 3 ? arguments[2] : arguments.map(Shell.quote).joined(separator: " ")
    }

    /// `go test` lists each test only with -v; without it a run shows no results.
    static func verbose(_ command: String) -> String {
        guard command.contains("go test"), !command.contains(" -v"), !command.contains("-json") else { return command }
        return command.replacingOccurrences(of: "go test", with: "go test -v")
    }

    /// The same runner limited to `tests`: for re-running failures or one test. Nil for a
    /// custom `test.command`, which Dante can't narrow.
    public func only(_ tests: [TestResult]) -> TestCommand? {
        guard !tests.isEmpty, let tool = arguments.first else { return nil }
        let count = tests.count == 1 ? tests[0].name : "\(tests.count) tests"
        func narrowed(_ extra: [String]) -> TestCommand {
            TestCommand(label: "\(label) · \(count)", arguments: arguments + extra, readsXUnit: readsXUnit)
        }
        switch tool {
        case "swift":
            // Matched against "Module.Suite/test()" identifiers.
            let ids = tests.map { test in
                let name = NSRegularExpression.escapedPattern(for: test.name)
                return test.suite.isEmpty ? name : NSRegularExpression.escapedPattern(for: test.suite) + "/" + name
            }
            return narrowed(["--filter", ids.joined(separator: "|")])
        case "cargo":
            // libtest takes several name filters after the separator.
            return narrowed(["--"] + tests.map { $0.suite == "tests" ? $0.name : "\($0.suite)::\($0.name)" })
        case "go":
            // -run splits on slashes for subtests, so each part is anchored on its own.
            let names = Set(tests.map { $0.name.components(separatedBy: "/")[0] }).sorted()
            let pattern = "^(" + names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")$"
            var narrowedArguments = arguments
            narrowedArguments.insert(contentsOf: ["-run", pattern], at: narrowedArguments.count - 1)
            return TestCommand(label: "\(label) · \(count)", arguments: narrowedArguments, readsXUnit: readsXUnit)
        case "python3":
            return narrowed(tests.map { "\($0.suite)::\($0.name)" })
        case "sh" where arguments.count == 3:
            // A custom test.command: narrow the go test or pytest inside it.
            let script = arguments[2]
            if let range = script.range(of: "go test -v") ?? script.range(of: "go test") {
                let names = Set(tests.map { $0.name.components(separatedBy: "/")[0] }).sorted()
                let pattern = "^(" + names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")$"
                let narrowedScript = script.replacingCharacters(in: range, with: "go test -v -run \(Shell.quote(pattern))")
                return TestCommand(label: "\(label) · \(count)", arguments: ["sh", "-c", narrowedScript], readsXUnit: readsXUnit)
            }
            if script.contains("pytest") {
                let expression = tests.map(\.name).joined(separator: " or ")
                return TestCommand(label: "\(label) · \(count)", arguments: ["sh", "-c", script + " -k " + Shell.quote(expression)], readsXUnit: readsXUnit)
            }
            return nil
        case "npm", "pnpm", "yarn", "bun":
            // Jest and Vitest both take test files and a -t name pattern.
            let names = tests.map { NSRegularExpression.escapedPattern(for: $0.name) }.joined(separator: "|")
            let files = Set(tests.map(\.suite).filter { !$0.isEmpty }).sorted()
            return narrowed((tool == "npm" ? ["--"] : []) + files + ["-t", names])
        default:
            return nil
        }
    }
}

extension TestCommand {
    /// The runner limited to tests read from the code, for running a category, a file or a
    /// hand-picked few. Runners want the file for some languages and only the name for others.
    public func only(written tests: [WrittenTest]) -> TestCommand? {
        let tool = arguments.first ?? ""
        let results = tests.map { test -> TestResult in
            let lower = test.file.lowercased()
            let suite: String
            if tool == "python3" || lower.hasSuffix(".py") && tool == "sh" { suite = test.file }
            else if ["npm", "pnpm", "yarn", "bun"].contains(tool) { suite = test.file }
            else if tool == "cargo" { suite = "tests" }
            else { suite = "" }
            return TestResult(suite: suite, name: test.name, status: .passed)
        }
        return only(results)
    }
}

/// One run of the project's tests, streamed: results arrive as the runner prints them.
@MainActor
@Observable
public final class TestRun {
    public enum State: Equatable {
        case running
        case finished(exitStatus: Int32)
        case stopped
        case couldNotStart(String)
    }

    public let command: TestCommand
    public private(set) var state: State = .running
    public private(set) var results: [TestResult] = []
    /// The runner's output, capped at the last `outputLimit` lines.
    public private(set) var output: [String] = []
    public let started = Date()
    public private(set) var finished: Date?
    /// Called once when the runner exits on its own (not when stopped).
    public var onFinish: (@MainActor (TestRun) -> Void)?

    private var parser = TestOutputParser()
    private var process: Shell.Running?
    private static let outputLimit = 4000

    private let root: URL

    public init(command: TestCommand, projectRoot root: URL) {
        self.command = command
        self.root = root
        var arguments = command.arguments
        let report = FileManager.default.temporaryDirectory.appending(path: "dante-tests-\(UUID().uuidString).xml")
        if command.readsXUnit { arguments += ["--xunit-output", report.path] }
        do {
            let running = try Shell.stream(arguments, in: root)
            process = running
            Task { await self.read(running, report: command.readsXUnit ? report : nil) }
        } catch {
            state = .couldNotStart("Couldn’t run \(command.label): \(error.localizedDescription)")
            finished = .now
        }
    }

    public var isRunning: Bool { state == .running }

    /// The run as a history entry.
    public var record: TestRecord {
        TestRecord(date: finished ?? .now, label: command.label, passed: passed, failed: failed, skipped: skipped,
                   duration: duration, brokeOutsideTests: failedOutsideTests,
                   failedTests: results.filter { $0.status == .failed }.map(\.id))
    }
    /// The run kept whole for `TestRunLog`.
    public func saved(by runner: TestRunner = .you) -> SavedTestRun {
        SavedTestRun(date: finished ?? .now, by: runner, command: command.label, results: results, duration: duration,
                     brokeOutsideTests: failedOutsideTests, narrowed: command.label.contains(" · "),
                     tail: failedOutsideTests ? Array(output.suffix(30)) : [])
    }

    public var passed: Int { results.count { $0.status == .passed } }
    public var failed: Int { results.count { $0.status == .failed } }
    public var skipped: Int { results.count { $0.status == .skipped } }
    public var duration: TimeInterval { (finished ?? .now).timeIntervalSince(started) }

    /// Finished with a non-zero exit but no failing test parsed: a build error or a crash.
    public var failedOutsideTests: Bool {
        if case .finished(let status) = state { return status != 0 && failed == 0 }
        return false
    }

    public func stop() {
        guard isRunning else { return }
        state = .stopped
        process?.terminate()
    }

    /// JUnit XML written during this run (Surefire's TEST-*.xml, Gradle's test-results).
    nonisolated static func reports(in folders: [String], root: URL, since: Date) -> [String] {
        var texts: [String] = []
        for folder in folders {
            let url = root.appending(path: folder)
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let file as URL in walker where file.pathExtension == "xml" {
                guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= since.addingTimeInterval(-2), let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                texts.append(text)
            }
        }
        return texts
    }

    private func read(_ running: Shell.Running, report: URL?) async {
        for await line in running.lines {
            output.append(line)
            if output.count > Self.outputLimit { output.removeFirst(output.count - Self.outputLimit) }
            parser.consume(line)
            if parser.results.count != results.count || parser.results.last != results.last {
                results = parser.results
            }
        }
        // The pipe closes just before the process is reaped.
        while running.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        if let report {
            // XCTest writes the named file; Swift Testing writes a sibling with this suffix.
            let swiftTesting = report.deletingPathExtension().path + "-swift-testing.xml"
            for file in [report.path, swiftTesting] {
                if let xml = try? String(contentsOfFile: file, encoding: .utf8) { parser.applyXUnit(xml) }
                try? FileManager.default.removeItem(atPath: file)
            }
        }
        for xml in Self.reports(in: command.reportFolders, root: root, since: started) { parser.applyXUnit(xml) }
        results = parser.results
        let ranToEnd = state == .running
        if ranToEnd { state = .finished(exitStatus: running.status) }
        finished = .now
        if ranToEnd { onFinish?(self) }
    }
}
