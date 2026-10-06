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

    public static func detect(projectRoot root: URL) -> TestCommand? {
        let fileManager = FileManager.default
        func has(_ name: String) -> Bool { fileManager.fileExists(atPath: root.appending(path: name).path) }

        if let yaml = try? String(contentsOf: root.appending(path: ".dante/project.yaml"), encoding: .utf8),
           let project = (try? Yams.load(yaml: yaml)) as? [String: Any],
           let test = project["test"] as? [String: Any], let command = test["command"] as? String, !command.isEmpty {
            return TestCommand(label: command, arguments: ["sh", "-c", command], readsXUnit: false)
        }
        if has("Package.swift") { return TestCommand(label: "swift test", arguments: ["swift", "test"], readsXUnit: true) }
        if has("Cargo.toml") { return TestCommand(label: "cargo test", arguments: ["cargo", "test"], readsXUnit: false) }
        if has("go.mod") { return TestCommand(label: "go test -v ./...", arguments: ["go", "test", "-v", "./..."], readsXUnit: false) }
        if has("package.json"),
           let data = fileManager.contents(atPath: root.appending(path: "package.json").path),
           let package = JSONValue(line: String(decoding: data, as: UTF8.self)),
           let script = package["scripts"]?["test"]?.string, !script.contains("no test specified") {
            let runner = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") ? "bun" : "npm"
            return TestCommand(label: "\(runner) test", arguments: [runner, "test"], readsXUnit: false)
        }
        if has("pytest.ini") || has("pyproject.toml") || has("setup.py") || has("tox.ini") {
            return TestCommand(label: "pytest -v", arguments: ["python3", "-m", "pytest", "-v"], readsXUnit: false)
        }
        return nil
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

    public init(command: TestCommand, projectRoot root: URL) {
        self.command = command
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
                   duration: duration, brokeOutsideTests: failedOutsideTests)
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
        results = parser.results
        let ranToEnd = state == .running
        if ranToEnd { state = .finished(exitStatus: running.status) }
        finished = .now
        if ranToEnd { onFinish?(self) }
    }
}
