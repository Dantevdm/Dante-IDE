import Foundation

/// A folder whose tests one runner runs: `services/api` with Maven, `services/web` with npm.
/// A repo can hold several, at any depth; each runs in its own folder.
public struct TestSuite: Equatable, Sendable, Identifiable {
    public enum Tool: String, Equatable, Sendable {
        case swift, cargo, go, maven, gradle, node, pytest

        /// Tools that cover the folders below them (Maven modules, Gradle subprojects, npm
        /// workspaces), so a nested folder with the same tool isn't a suite of its own.
        var family: String { self == .maven || self == .gradle ? "jvm" : rawValue }
    }

    /// What the code under test is, for sorting unit tests into front-end and back-end.
    public enum Side: String, Equatable, Sendable {
        case frontEnd, backEnd, app
    }

    /// Relative to the project root; empty for the root itself.
    public var folder: String
    public var tool: Tool
    /// The program to start: `./mvnw`, `mvn`, `npm`, `pnpm`…
    public var runner: String
    public var side: Side?
    /// For node: what the test script runs with (jest, vitest, react-scripts…), for its flags.
    public var framework: String?
    public var id: String { folder }

    public init(folder: String, tool: Tool, runner: String, side: Side? = nil, framework: String? = nil) {
        self.folder = folder
        self.tool = tool
        self.runner = runner
        self.side = side
        self.framework = framework
    }

    /// "./mvnw test in services/api".
    public var label: String {
        let base: String = switch tool {
        case .swift: "swift test"
        case .cargo: "cargo test"
        case .go: "go test ./..."
        case .maven, .gradle, .node: "\(runner) test"
        case .pytest: "pytest"
        }
        return folder.isEmpty ? base : "\(base) in \(folder)"
    }

    public func contains(_ path: String) -> Bool {
        folder.isEmpty || path.hasPrefix(folder + "/")
    }

    /// Where the runner writes JUnit XML that names each test (Maven and Gradle print only counts).
    public var reportFolders: [String] {
        let base = folder.isEmpty ? "" : folder + "/"
        switch tool {
        case .maven: return [base + "target/surefire-reports", base + "target/failsafe-reports"]
        case .gradle: return [base + "build/test-results"]
        default: return []
        }
    }

    /// The command line, run from this suite's folder: every test, or only `tests`.
    public func script(only tests: [WrittenTest]? = nil) -> String {
        let local = (tests ?? []).map { folder.isEmpty ? $0.file : String($0.file.dropFirst(folder.count + 1)) }
        let names = Array(Set((tests ?? []).map { TestMap.key($0.name) })).sorted()
        let classes = Array(Set((tests ?? []).map { (($0.file as NSString).lastPathComponent as NSString).deletingPathExtension })).sorted()
        let narrowed = tests != nil
        switch tool {
        case .swift:
            return "swift test" + (narrowed ? " --filter " + Shell.quote(names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")) : "")
        case .cargo:
            return "cargo test" + (narrowed ? " -- " + names.map(Shell.quote).joined(separator: " ") : "")
        case .go:
            let pattern = "^(" + Set(names.map { $0.components(separatedBy: "/")[0] }).sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")$"
            return "go test -v" + (narrowed ? " -run " + Shell.quote(pattern) : "") + " ./..."
        case .maven:
            return "\(runner) -B test" + (narrowed ? " -Dtest=" + Shell.quote(classes.joined(separator: ",")) + " -Dsurefire.failIfNoSpecifiedTests=false -DfailIfNoTests=false" : "")
        case .gradle:
            return "\(runner) test" + (narrowed ? classes.map { " --tests " + Shell.quote("*" + $0) }.joined() : "")
        case .node:
            // CI stops watch mode (react-scripts, vitest); verbose makes jest name every test.
            var extra: [String] = []
            switch framework {
            case "vitest": extra = ["--run", "--reporter=verbose"]
            case "jest", "react-scripts": extra = ["--verbose", "--watchAll=false"]
            case "ng": extra = ["--watch=false"]
            default: break
            }
            extra += Array(Set(local)).sorted().map(Shell.quote)
            let separator = runner == "npm" && !extra.isEmpty ? " --" : ""
            return "CI=true \(runner) test" + separator + extra.map { " " + $0 }.joined()
        case .pytest:
            return "python3 -m pytest -v" + Array(Set(local)).sorted().map { " " + Shell.quote($0) }.joined()
        }
    }
}

public enum TestSuites {
    static let skipped: Set<String> = ["node_modules", "vendor", "build", "dist", "target", "Pods", "venv", ".venv", ".build", "out", "coverage"]
    static let frontEndPackages = ["react", "react-dom", "vue", "@angular/core", "svelte", "next", "nuxt", "solid-js", "preact", "lit", "@remix-run/react", "astro"]
    static let backEndPackages = ["express", "fastify", "@nestjs/core", "koa", "@hapi/hapi", "hapi", "restify"]

    /// Every folder with a runner, outermost first, from the project's file list. `read`
    /// gives a file's text (package.json), relative to the root.
    public static func find(files: [String], read: (String) -> String?, maxDepth: Int = 4) -> [TestSuite] {
        let fileSet = Set(files)
        var folders: [String: [String]] = [:]
        for file in files {
            let parts = file.split(separator: "/").map(String.init)
            guard parts.count <= maxDepth + 1, !parts.dropLast().contains(where: { skipped.contains($0) || $0.hasPrefix(".") }) else { continue }
            folders[parts.dropLast().joined(separator: "/"), default: []].append(parts.last!)
        }
        var suites: [TestSuite] = []
        for folder in folders.keys.sorted(by: { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }) {
            let names = Set(folders[folder] ?? [])
            guard let suite = suite(in: folder, names: names, has: { fileSet.contains($0) }, read: read) else { continue }
            // A Maven module or npm workspace under a suite of the same kind is run by it.
            if suites.contains(where: { $0.tool.family == suite.tool.family && ($0.folder.isEmpty || folder.hasPrefix($0.folder + "/")) }) { continue }
            suites.append(suite)
        }
        return suites
    }

    static func suite(in folder: String, names: Set<String>, has: (String) -> Bool, read: (String) -> String?) -> TestSuite? {
        let prefix = folder.isEmpty ? "" : folder + "/"
        if names.contains("Package.swift") { return TestSuite(folder: folder, tool: .swift, runner: "swift", side: .app) }
        if names.contains("go.mod") { return TestSuite(folder: folder, tool: .go, runner: "go", side: .backEnd) }
        if names.contains("pom.xml") { return TestSuite(folder: folder, tool: .maven, runner: names.contains("mvnw") ? "./mvnw" : "mvn", side: .backEnd) }
        if names.contains("build.gradle") || names.contains("build.gradle.kts") {
            return TestSuite(folder: folder, tool: .gradle, runner: names.contains("gradlew") ? "./gradlew" : "gradle", side: .backEnd)
        }
        if names.contains("Cargo.toml") { return TestSuite(folder: folder, tool: .cargo, runner: "cargo", side: .backEnd) }
        if names.contains("package.json"), let text = read(prefix + "package.json"), let package = JSONValue(line: text),
           let script = package["scripts"]?["test"]?.string, !script.contains("no test specified") {
            return TestSuite(folder: folder, tool: .node, runner: nodeRunner(folder: folder, has: has), side: side(of: package), framework: framework(script))
        }
        if names.contains("pytest.ini") || names.contains("pyproject.toml") || names.contains("setup.py") || names.contains("tox.ini")
            || names.contains("requirements.txt") && (names.contains { $0.hasPrefix("test_") && $0.hasSuffix(".py") } || has(prefix + "tests/__init__.py") || has(prefix + "tests/conftest.py")) {
            return TestSuite(folder: folder, tool: .pytest, runner: "python3", side: .backEnd)
        }
        return nil
    }

    /// The lockfile in this folder or one above it says which package manager.
    static func nodeRunner(folder: String, has: (String) -> Bool) -> String {
        var parts = folder.split(separator: "/").map(String.init)
        while true {
            let prefix = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
            if has(prefix + "pnpm-lock.yaml") { return "pnpm" }
            if has(prefix + "yarn.lock") { return "yarn" }
            if has(prefix + "bun.lockb") || has(prefix + "bun.lock") { return "bun" }
            if has(prefix + "package-lock.json") || parts.isEmpty { return "npm" }
            parts.removeLast()
        }
    }

    static func side(of package: JSONValue) -> TestSuite.Side? {
        var names: Set<String> = []
        for key in ["dependencies", "devDependencies", "peerDependencies"] {
            if case .object(let deps)? = package[key] { names.formUnion(deps.keys) }
        }
        if frontEndPackages.contains(where: names.contains) { return .frontEnd }
        if backEndPackages.contains(where: names.contains) { return .backEnd }
        return nil
    }

    static func framework(_ script: String) -> String? {
        if script.contains("vitest") { return "vitest" }
        if script.contains("react-scripts") || script.contains("craco") { return "react-scripts" }
        if script.contains("jest") { return "jest" }
        if script.contains("ng test") { return "ng" }
        return nil
    }

    /// The suite a file belongs to: the deepest folder holding it.
    public static func suite(for path: String, in suites: [TestSuite]) -> TestSuite? {
        suites.filter { $0.contains(path) }.max { $0.folder.count < $1.folder.count }
    }

    /// One command for several suites, or for `tests` (each run by its own suite). Every
    /// suite runs even when one fails, and the run fails if any did. Nil when nothing would run.
    public static func command(_ suites: [TestSuite], only tests: [WrittenTest]? = nil, label: String? = nil) -> TestCommand? {
        var parts: [(suite: TestSuite, tests: [WrittenTest]?)] = []
        if let tests {
            for candidate in suites {
                let mine = tests.filter { TestSuites.suite(for: $0.file, in: suites) == candidate }
                if !mine.isEmpty { parts.append((candidate, mine)) }
            }
        } else {
            parts = suites.map { ($0, nil) }
        }
        guard !parts.isEmpty else { return nil }
        let count = tests.map { $0.count == 1 ? $0[0].name : "\($0.count) tests" }
        let name = label ?? parts.map(\.suite.label).joined(separator: " · ") + (count.map { " · \($0)" } ?? "")
        let reports = parts.flatMap(\.suite.reportFolders)
        // Swift at the root runs directly, so Dante can ask for its xUnit report.
        if parts.count == 1, parts[0].suite.tool == .swift, parts[0].suite.folder.isEmpty {
            var arguments = ["swift", "test"]
            if let tests = parts[0].tests {
                arguments += ["--filter", tests.map { NSRegularExpression.escapedPattern(for: TestMap.key($0.name)) }.joined(separator: "|")]
            }
            return TestCommand(label: name, arguments: arguments, readsXUnit: true)
        }
        func line(_ part: (suite: TestSuite, tests: [WrittenTest]?)) -> String {
            let script = part.suite.script(only: part.tests)
            return part.suite.folder.isEmpty ? script : "cd \(Shell.quote(part.suite.folder)) && \(script)"
        }
        let script = parts.count == 1 ? line(parts[0])
            : "status=0; " + parts.map { "(\(line($0))) || status=1; " }.joined() + "exit $status"
        return TestCommand(label: name, arguments: ["sh", "-c", script], readsXUnit: false, reportFolders: reports)
    }
}
