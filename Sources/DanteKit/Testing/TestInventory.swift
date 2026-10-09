import Foundation
import Yams

/// One test as written in the code, found by reading test files rather than running them.
public struct WrittenTest: Equatable, Sendable, Identifiable {
    public var name: String
    /// Relative to the project root.
    public var file: String
    /// 1-based.
    public var line: Int
    public var category: String
    /// The folder or package the test lives in.
    public var area: String
    public var id: String { "\(file):\(line):\(name)" }

    public init(name: String, file: String, line: Int, category: String, area: String) {
        self.name = name
        self.file = file
        self.line = line
        self.category = category
        self.area = area
    }
}

/// Every test written in a project, sorted into categories: Unit, Integration,
/// End-to-end, UI and Performance by default, or the project's own from
/// `test.categories` in project.yaml (a name and the path globs that belong to it).
public struct TestInventory: Equatable, Sendable {
    public struct CategoryRule: Equatable, Sendable {
        public var name: String
        public var globs: [String]

        public init(name: String, globs: [String]) {
            self.name = name
            self.globs = globs
        }
    }

    public static let unit = "Unit", integration = "Integration", endToEnd = "End-to-end", ui = "UI", performance = "Performance"
    public static let defaultOrder = [unit, integration, endToEnd, ui, performance]

    public var tests: [WrittenTest]
    public var testFiles: [String]
    public var rules: [CategoryRule]

    public init(tests: [WrittenTest] = [], testFiles: [String] = [], rules: [CategoryRule] = []) {
        self.tests = tests
        self.testFiles = testFiles
        self.rules = rules
    }

    /// Categories in display order: the project's own first, then the defaults in use.
    public var categories: [String] {
        let used = Set(tests.map(\.category))
        let order = rules.map(\.name) + Self.defaultOrder
        var seen: [String] = []
        for name in order where used.contains(name) && !seen.contains(name) { seen.append(name) }
        for name in used.sorted() where !seen.contains(name) { seen.append(name) }
        return seen
    }

    public func count(in category: String) -> Int { tests.count { $0.category == category } }

    // MARK: Reading

    public static func load(root: URL, files: [String], sizeLimit: Int = 512 * 1024) -> TestInventory {
        let rules = categoryRules(projectRoot: root)
        var tests: [WrittenTest] = []
        var testFiles: [String] = []
        for file in files where isTestFile(file) || mayHoldTests(file) {
            let url = root.appending(path: file)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= sizeLimit,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let found = Self.tests(in: text, path: file, rules: rules)
            if isTestFile(file) || !found.isEmpty { testFiles.append(file) }
            tests += found
        }
        return TestInventory(tests: tests, testFiles: testFiles.sorted(), rules: rules)
    }

    /// `test.categories` from project.yaml: `{ Integration: ["backend/internal/db/**"] }`.
    public static func categoryRules(projectRoot root: URL) -> [CategoryRule] {
        guard let yaml = try? String(contentsOf: root.appending(path: ".dante/project.yaml"), encoding: .utf8) else { return [] }
        return categoryRules(yaml: yaml)
    }

    public static func categoryRules(yaml: String) -> [CategoryRule] {
        guard let project = (try? Yams.load(yaml: yaml)) as? [String: Any],
              let categories = (project["test"] as? [String: Any])?["categories"] as? [String: Any] else { return [] }
        return categories.keys.sorted().compactMap { name in
            let globs = (categories[name] as? [Any])?.map { "\($0)" } ?? (categories[name] as? String).map { [$0] } ?? []
            return globs.isEmpty ? nil : CategoryRule(name: name, globs: globs)
        }
    }

    /// Files that are only tests, by naming convention or folder.
    public static func isTestFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let lower = name.lowercased()
        let folders = path.lowercased().split(separator: "/").dropLast().map(String.init)
        if lower.hasSuffix("_test.go") { return true }
        if lower.hasSuffix(".swift") { return lower.hasSuffix("tests.swift") || lower.hasSuffix("test.swift") || folders.contains { $0.hasSuffix("tests") } }
        if lower.hasSuffix(".py") { return lower.hasPrefix("test_") || lower.hasSuffix("_test.py") }
        if [".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"].contains(where: { lower.hasSuffix($0) }) {
            return lower.contains(".test.") || lower.contains(".spec.") || folders.contains("__tests__") || folders.contains("e2e") || folders.contains("cypress")
        }
        if lower.hasSuffix(".java") || lower.hasSuffix(".kt") { return lower.contains("test") && folders.contains("test") }
        if lower.hasSuffix(".rb") { return lower.hasSuffix("_spec.rb") || lower.hasSuffix("_test.rb") }
        if lower.hasSuffix(".rs") { return folders.contains("tests") }
        return false
    }

    /// Rust keeps unit tests beside the code, in `#[cfg(test)]` modules.
    static func mayHoldTests(_ path: String) -> Bool { path.hasSuffix(".rs") }

    // MARK: Parsing

    /// The tests declared in one file.
    public static func tests(in text: String, path: String, rules: [CategoryRule] = []) -> [WrittenTest] {
        let lines = text.components(separatedBy: "\n")
        let lower = path.lowercased()
        var found: [(name: String, line: Int, kind: String?)] = []

        func scan(_ pattern: Regex<(Substring, Substring)>, kind: String? = nil) {
            for (index, line) in lines.enumerated() {
                if let match = line.firstMatch(of: pattern) { found.append((String(match.1), index + 1, kind)) }
            }
        }

        if lower.hasSuffix(".go") {
            scan(/^func\s+(Test\w*)\s*\(\s*\w+\s+\*testing\.T\s*\)/)
            scan(/^func\s+(Benchmark\w*)\s*\(\s*\w+\s+\*testing\.B\s*\)/, kind: performance)
            scan(/^func\s+(Fuzz\w*)\s*\(\s*\w+\s+\*testing\.F\s*\)/)
        } else if lower.hasSuffix(".swift") {
            // @Test func name(), @Test("Display name") func name(), and XCTest's func testName().
            for (index, line) in lines.enumerated() {
                let previous = index > 0 ? lines[index - 1] : ""
                if let match = line.firstMatch(of: /@Test\b(?:\([^)]*\))?\s*(?:@\w+\s+)*(?:(?:static|nonisolated|private|fileprivate|internal|public)\s+)*func\s+(`?[\w]+`?)/) {
                    found.append((String(match.1), index + 1, nil))
                } else if previous.trimmingCharacters(in: .whitespaces).hasPrefix("@Test"), let match = line.firstMatch(of: /^\s*(?:(?:static|nonisolated|private)\s+)*func\s+(`?\w+`?)/) {
                    found.append((String(match.1), index + 1, nil))
                } else if let match = line.firstMatch(of: /^\s*(?:@\w+\s+)*(?:override\s+)?func\s+(test\w+)\s*\(\s*\)/) {
                    found.append((String(match.1), index + 1, nil))
                }
            }
        } else if lower.hasSuffix(".py") {
            scan(/^\s*(?:async\s+)?def\s+(test\w*)\s*\(/)
        } else if [".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"].contains(where: { lower.hasSuffix($0) }) {
            scan(/^\s*(?:it|test)(?:\.(?:only|skip|concurrent|todo|each\([^)]*\)))?\s*\(\s*['"`]((?:[^'"`\\]|\\.)+)['"`]/)
            scan(/^\s*bench\s*\(\s*['"`]([^'"`]+)['"`]/, kind: performance)
        } else if lower.hasSuffix(".rs") {
            for (index, line) in lines.enumerated() where line.contains("#[test]") || line.contains("#[tokio::test") {
                for next in lines.dropFirst(index + 1).prefix(3) {
                    if let match = next.firstMatch(of: /^\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)/) {
                        found.append((String(match.1), index + 1, nil))
                        break
                    }
                }
            }
        } else if lower.hasSuffix(".java") || lower.hasSuffix(".kt") {
            for (index, line) in lines.enumerated() where line.contains("@Test") {
                for next in lines.dropFirst(index).prefix(3) {
                    if let match = next.firstMatch(of: /(?:void|fun)\s+`?([\w ]+?)`?\s*\(/) {
                        found.append((String(match.1), index + 1, nil))
                        break
                    }
                }
            }
        } else if lower.hasSuffix(".rb") {
            scan(/^\s*it\s+['"]([^'"]+)['"]/)
            scan(/^\s*def\s+(test_\w+)/)
        }

        let fileCategory = category(path: path, text: text, rules: rules)
        let area = Self.area(of: path)
        return found.sorted { $0.line < $1.line }.map { test in
            WrittenTest(name: test.name, file: path, line: test.line,
                        category: ruleCategory(path, rules) ?? test.kind ?? nameCategory(test.name) ?? fileCategory, area: area)
        }
    }

    static func ruleCategory(_ path: String, _ rules: [CategoryRule]) -> String? {
        rules.first { rule in rule.globs.contains { ClaudeRules.path(path, matches: $0) } }?.name
    }

    static func nameCategory(_ name: String) -> String? {
        let lower = name.lowercased()
        if lower.hasPrefix("benchmark") || lower.contains("performance") { return performance }
        if lower.contains("integration") { return integration }
        if lower.contains("e2e") || lower.contains("endtoend") || lower.contains("end to end") { return endToEnd }
        return nil
    }

    /// From the project's rules, the folder, then what the file reaches for.
    public static func category(path: String, text: String, rules: [CategoryRule] = []) -> String {
        if let rule = ruleCategory(path, rules) { return rule }
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        if parts.contains(where: { ["e2e", "cypress", "playwright", "acceptance"].contains($0) }) || lower.contains(".e2e.") { return endToEnd }
        if parts.contains(where: { $0.hasSuffix("uitests") || $0 == "ui-tests" || $0 == "ui" }) { return ui }
        if parts.contains(where: { $0.contains("integration") || $0 == "it" }) || lower.contains(".integration.") { return integration }
        if parts.contains(where: { ["bench", "benches", "benchmarks", "perf", "performance"].contains($0) }) { return performance }
        // Tests that start servers, open databases or containers reach past one unit.
        let signals = ["testcontainers", "sql.Open(", "httptest.NewServer", "dockertest", "supertest", "TestClient(", "requests.get(", "pg.Pool", "createConnection(", "XCUIApplication"]
        if let signal = signals.first(where: { text.contains($0) }) {
            return signal == "XCUIApplication" ? ui : integration
        }
        return unit
    }

    /// The folder a test file sits in, or "(root)".
    static func area(of path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "(root)" : folder
    }
}
