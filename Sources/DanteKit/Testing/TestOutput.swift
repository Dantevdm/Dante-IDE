import Foundation

/// One test from a run.
public struct TestResult: Equatable, Sendable, Identifiable {
    public enum Status: Sendable, Equatable { case passed, failed, skipped }

    public struct Issue: Equatable, Sendable {
        public var message: String
        /// As printed: a bare file name, a relative path or an absolute one.
        public var file: String?
        public var line: Int?

        public init(message: String, file: String? = nil, line: Int? = nil) {
            self.message = message
            self.file = file
            self.line = line
        }
    }

    public var suite: String
    public var name: String
    public var status: Status
    public var duration: Double?
    public var issues: [Issue]

    public var id: String { suite + "/" + name }

    public init(suite: String, name: String, status: Status, duration: Double? = nil, issues: [Issue] = []) {
        self.suite = suite
        self.name = name
        self.status = status
        self.duration = duration
        self.issues = issues
    }
}

/// Reads test runner output line by line: Swift Testing, XCTest, cargo, go test,
/// pytest and Jest/Vitest. Lines it doesn't recognise are left for the raw output.
public struct TestOutputParser: Sendable {
    public private(set) var results: [TestResult] = []
    /// Issues seen before their test's result line, keyed by test name.
    private var pendingIssues: [String: [TestResult.Issue]] = [:]
    private var lastIssueTest: String?
    private var currentFile: String?

    public init() {}

    public mutating func consume(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if swiftTesting(line) || xcTest(line) || cargo(line) || goTest(line) || pytest(line) || jest(line) { return }
    }

    // MARK: Swift

    private mutating func swiftTesting(_ line: String) -> Bool {
        // ✔ Test passes() passed after 0.001 seconds.
        // ✘ Test "Adds up wrong" recorded an issue at T.swift:6:41: Expectation failed: …
        // ↳ off by one
        // ✘ Test "Adds up wrong" failed after 0.001 seconds with 1 issue.
        // ➜ Test skipped() skipped.
        if line.hasPrefix("↳ "), let test = lastIssueTest, var issues = pendingIssues[test], !issues.isEmpty {
            issues[issues.count - 1].message += "\n" + line.dropFirst(2)
            pendingIssues[test] = issues
            return true
        }
        guard let first = line.first, "✔✘➜◇".contains(first), line.dropFirst(2).hasPrefix("Test ") else {
            if line.first.map({ "✔✘◇".contains($0) }) == true { lastIssueTest = nil }
            return false
        }
        let rest = String(line.dropFirst(7))
        guard let (name, tail) = Self.splitName(rest) else { return false }
        if let match = tail.firstMatch(of: /^recorded an issue at ([^:]+):(\d+)(?::\d+)?: (.*)$/) {
            pendingIssues[name, default: []].append(.init(message: String(match.3), file: String(match.1), line: Int(match.2)))
            lastIssueTest = name
            return true
        }
        lastIssueTest = nil
        let duration = tail.firstMatch(of: /after ([\d.]+) seconds/).flatMap { Double($0.1) }
        if tail.hasPrefix("passed") {
            record(TestResult(suite: "", name: name, status: .passed, duration: duration))
        } else if tail.hasPrefix("failed") {
            record(TestResult(suite: "", name: name, status: .failed, duration: duration, issues: pendingIssues.removeValue(forKey: name) ?? []))
        } else if tail.hasPrefix("skipped") {
            record(TestResult(suite: "", name: name, status: .skipped))
        }
        return true
    }

    /// `passes() passed …` or `"Display name" passed …` into the name and the rest.
    static func splitName(_ text: String) -> (String, String)? {
        if text.hasPrefix("\"") {
            guard let end = text.dropFirst().firstIndex(of: "\"") else { return nil }
            let name = String(text[text.index(after: text.startIndex)..<end])
            return (name, text[text.index(after: end)...].trimmingCharacters(in: .whitespaces))
        }
        guard let space = text.firstIndex(of: " ") else { return nil }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    private mutating func xcTest(_ line: String) -> Bool {
        // /path/T.swift:10: error: -[MTests.Old testBad] : XCTAssertEqual failed: …
        if let match = line.firstMatch(of: /^(.+?):(\d+): error: -\[(\S+) (\S+)\] : (.*)$/) {
            pendingIssues["\(match.3)/\(match.4)", default: []].append(.init(message: String(match.5), file: String(match.1), line: Int(match.2)))
            return true
        }
        // Test Case '-[MTests.Old testBad]' failed (0.105 seconds).
        guard let match = line.firstMatch(of: /^Test Case '-\[(\S+) (\S+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)/) else { return false }
        let qualified = String(match.1), name = String(match.2)
        let status: TestResult.Status = match.3 == "passed" ? .passed : match.3 == "failed" ? .failed : .skipped
        let issues = pendingIssues.removeValue(forKey: "\(qualified)/\(name)") ?? []
        let suite = qualified.components(separatedBy: ".").last ?? qualified
        record(TestResult(suite: suite, name: name, status: status, duration: Double(match.4), issues: issues))
        return true
    }

    // MARK: Other runners

    private mutating func cargo(_ line: String) -> Bool {
        // test parser::tests::splits ... ok
        guard let match = line.firstMatch(of: /^test (\S+) \.\.\. (ok|FAILED|ignored)$/) else { return false }
        var parts = String(match.1).components(separatedBy: "::")
        let name = parts.removeLast()
        let status: TestResult.Status = match.2 == "ok" ? .passed : match.2 == "FAILED" ? .failed : .skipped
        record(TestResult(suite: parts.isEmpty ? "tests" : parts.joined(separator: "::"), name: name, status: status))
        return true
    }

    private mutating func goTest(_ line: String) -> Bool {
        // --- FAIL: TestLimit (0.00s)
        //     limits_test.go:12: got 3, want 2
        if let match = line.firstMatch(of: /^--- (PASS|FAIL|SKIP): (\S+) \(([\d.]+)s\)$/) {
            let status: TestResult.Status = match.1 == "PASS" ? .passed : match.1 == "FAIL" ? .failed : .skipped
            let name = String(match.2)
            record(TestResult(suite: currentFile ?? "", name: name, status: status, duration: Double(match.3)))
            lastIssueTest = status == .failed ? name : nil
            return true
        }
        if let test = lastIssueTest, let match = line.firstMatch(of: /^(\S+_test\.go):(\d+): (.*)$/),
           let index = results.lastIndex(where: { $0.name == test }) {
            results[index].issues.append(.init(message: String(match.3), file: String(match.1), line: Int(match.2)))
            return true
        }
        if let match = line.firstMatch(of: /^(ok|FAIL)\s+(\S+)\s/) {
            // Package summary: name the suite of the tests just above it.
            let package = String(match.2)
            for index in results.indices where results[index].suite.isEmpty { results[index].suite = package }
            return true
        }
        return false
    }

    private mutating func pytest(_ line: String) -> Bool {
        // tests/test_limits.py::test_resets PASSED   [ 50%]
        guard let match = line.firstMatch(of: /^(\S+\.py)::(\S+) (PASSED|FAILED|SKIPPED|ERROR|XFAIL|XPASS)/) else { return false }
        let status: TestResult.Status = switch match.3 {
        case "PASSED", "XPASS": .passed
        case "SKIPPED", "XFAIL": .skipped
        default: .failed
        }
        record(TestResult(suite: String(match.1), name: String(match.2), status: status))
        return true
    }

    private mutating func jest(_ line: String) -> Bool {
        // PASS src/limits.test.ts
        //   ✓ rejects zero amounts (3 ms)
        //   ✕ resets at midnight (12 ms)
        if let match = line.firstMatch(of: /^(PASS|FAIL) (\S+)/) {
            currentFile = String(match.2)
            return true
        }
        guard let file = currentFile, let match = line.firstMatch(of: /^(✓|✕|○|√|×) (.+?)(?: \((\d+) ms\))?$/) else { return false }
        let status: TestResult.Status = switch match.1 {
        case "✓", "√": .passed
        case "○": .skipped
        default: .failed
        }
        record(TestResult(suite: file, name: String(match.2), status: status, duration: match.3.flatMap { Double($0) }.map { $0 / 1000 }))
        return true
    }

    private mutating func record(_ result: TestResult) {
        if let index = results.firstIndex(where: { $0.id == result.id }) {
            results[index] = result
        } else {
            results.append(result)
        }
    }

    /// Fills in suites for Swift Testing results from its xUnit report, which names the
    /// type each test is in. Display-named tests whose function name doesn't match stay as they are.
    public mutating func applyXUnit(_ xml: String) {
        for testcase in XUnit.parse(xml) {
            if let index = results.firstIndex(where: { $0.suite.isEmpty && $0.name == testcase.name }) {
                results[index].suite = testcase.suite
                if results[index].issues.isEmpty, let message = testcase.failure {
                    results[index].issues = [.init(message: message)]
                }
            } else if !results.contains(where: { $0.name == testcase.name }) {
                results.append(TestResult(
                    suite: testcase.suite,
                    name: testcase.name,
                    status: testcase.failure != nil ? .failed : (testcase.skipped ? .skipped : .passed),
                    duration: testcase.time,
                    issues: testcase.failure.map { [.init(message: $0)] } ?? []
                ))
            }
        }
    }
}

/// A minimal JUnit/xUnit XML reader for `<testcase>` elements.
enum XUnit {
    struct Case: Equatable {
        var suite: String
        var name: String
        var time: Double?
        var failure: String?
        var skipped = false
    }

    static func parse(_ xml: String) -> [Case] {
        final class Delegate: NSObject, XMLParserDelegate {
            var cases: [Case] = []
            func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
                switch element {
                case "testcase":
                    let suite = attributes["classname"] ?? ""
                    cases.append(Case(suite: suite.components(separatedBy: ".").last ?? suite, name: attributes["name"] ?? "", time: attributes["time"].flatMap(Double.init)))
                case "failure", "error":
                    if !cases.isEmpty { cases[cases.count - 1].failure = attributes["message"] ?? "Failed" }
                case "skipped":
                    if !cases.isEmpty { cases[cases.count - 1].skipped = true }
                default:
                    break
                }
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.cases
    }
}
