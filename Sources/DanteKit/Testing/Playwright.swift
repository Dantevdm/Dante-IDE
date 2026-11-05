import Foundation

/// Playwright end-to-end tests: where a project keeps them, how Dante runs them and what
/// their report says, screenshots, videos and traces included.
public enum Playwright {
    static let configNames = ["playwright.config.ts", "playwright.config.js", "playwright.config.mjs", "playwright.config.cjs",
                              "playwright.config.mts", "playwright.config.cts"]

    /// The config's `testDir`, relative to its folder: `./e2e` gives "e2e"; Playwright's own
    /// default is the config's folder, but `npm init playwright` writes "tests".
    public static func testDir(inConfig text: String) -> String {
        guard let match = text.firstMatch(of: /testDir\s*:\s*['"`]([^'"`]+)['"`]/) else { return "" }
        var dir = String(match.1)
        while dir.hasPrefix("./") { dir.removeFirst(2) }
        while dir.hasSuffix("/") { dir.removeLast() }
        return dir == "." ? "" : dir
    }

    /// The JSON report Dante asks for, in the suite's folder: in test-results/, which
    /// Playwright's own .gitignore lines leave out.
    public static let reportFile = "test-results/.dante-playwright.json"

    /// The shell lines that find the project's own Playwright (never `npx`, which would
    /// download one) and run it with the list reporter for progress and JSON for the details.
    static func script(arguments: [String]) -> String {
        """
        d="$PWD"; while [ ! -x "$d/node_modules/.bin/playwright" ] && [ "$d" != / ]; do d=$(dirname "$d"); done; \
        if [ ! -x "$d/node_modules/.bin/playwright" ]; then echo "Playwright isn't installed in this project: run npm install (or your package manager's install), then try again."; exit 127; fi; \
        CI=true PLAYWRIGHT_JSON_OUTPUT_NAME=\(Shell.quote(reportFile)) "$d/node_modules/.bin/playwright" test --reporter=list,json\(arguments.map { " " + $0 }.joined())
        """
    }
}

extension TestResult {
    /// Something a test left behind: a screenshot, a video, a trace, or another file.
    public struct Attachment: Codable, Equatable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case screenshot, video, trace, other }
        public var name: String
        /// Absolute.
        public var path: String
        public var contentType: String
        /// The browser project it came from ("chromium").
        public var project: String?

        public init(name: String, path: String, contentType: String, project: String? = nil) {
            self.name = name
            self.path = path
            self.contentType = contentType
            self.project = project
        }

        public var kind: Kind {
            if name == "trace" || path.hasSuffix(".zip") && name.contains("trace") { return .trace }
            if contentType.hasPrefix("image/") { return .screenshot }
            if contentType.hasPrefix("video/") { return .video }
            return .other
        }
    }
}

/// Reads the JSON reporter's file. Each test becomes one result even when it ran in several
/// browsers: failed if any failed, with each failure's browser named in its issue.
public enum PlaywrightReport {
    /// - Parameters:
    ///   - projectRoot: the project's folder, so files become project paths.
    ///   - suiteFolder: the config's folder relative to the project, for files outside it.
    public static func results(_ data: Data, projectRoot: String, suiteFolder: String) -> [TestResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let config = root["config"] as? [String: Any]
        let rootDir = (config?["rootDir"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var ordered: [String] = []
        var merged: [String: TestResult] = [:]

        func walk(_ suite: [String: Any], titles: [String], file: String?) {
            let file = suite["file"] as? String ?? file
            let title = suite["title"] as? String ?? ""
            // The file's own suite is titled with the file name; describe blocks add their titles.
            let path = titles + (title.isEmpty || title == file || title == (file as NSString?)?.lastPathComponent ? [] : [title])
            for spec in suite["specs"] as? [[String: Any]] ?? [] {
                guard let specTitle = spec["title"] as? String else { continue }
                let specFile = spec["file"] as? String ?? file ?? ""
                let relative = projectPath(specFile, rootDir: rootDir, projectRoot: projectRoot, suiteFolder: suiteFolder)
                let line = spec["line"] as? Int
                for test in spec["tests"] as? [[String: Any]] ?? [] {
                    let result = result(test, name: specTitle, file: relative, line: line)
                    let id = relative + "/" + specTitle
                    if var existing = merged[id] {
                        existing.merge(result)
                        merged[id] = existing
                    } else {
                        merged[id] = result
                        ordered.append(id)
                    }
                }
            }
            for child in suite["suites"] as? [[String: Any]] ?? [] { walk(child, titles: path, file: file) }
        }
        for suite in root["suites"] as? [[String: Any]] ?? [] { walk(suite, titles: [], file: nil) }
        return ordered.compactMap { merged[$0] }
    }

    static func result(_ test: [String: Any], name: String, file: String, line: Int?) -> TestResult {
        let project = (test["projectName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let runs = test["results"] as? [[String: Any]] ?? []
        let outcome = test["status"] as? String ?? "expected"
        let status: TestResult.Status = switch outcome {
        case "skipped": .skipped
        case "unexpected": .failed
        default: .passed  // expected, flaky (passed on a retry)
        }
        var issues: [TestResult.Issue] = []
        var attachments: [TestResult.Attachment] = []
        for run in runs {
            let errors = (run["errors"] as? [[String: Any]]) ?? ((run["error"] as? [String: Any]).map { [$0] } ?? [])
            if run["status"] as? String != "passed" || status == .failed {
                for error in errors {
                    let message = TestOutputText.strippingColour(error["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let location = error["location"] as? [String: Any]
                    let retry = run["retry"] as? Int ?? 0
                    let prefix = [project.map { "[\($0)]" }, retry > 0 ? "retry \(retry):" : nil].compactMap { $0 }.joined(separator: " ")
                    issues.append(.init(message: (prefix.isEmpty ? "" : prefix + " ") + (message.split(separator: "\n").prefix(12).joined(separator: "\n")),
                                        file: location?["file"] as? String, line: location?["line"] as? Int))
                }
            }
            for attachment in run["attachments"] as? [[String: Any]] ?? [] {
                guard let path = attachment["path"] as? String else { continue }
                attachments.append(.init(name: attachment["name"] as? String ?? "attachment", path: path,
                                         contentType: attachment["contentType"] as? String ?? "application/octet-stream", project: project))
            }
        }
        if outcome == "flaky", let project { issues.insert(.init(message: "[\(project)] flaky: failed, then passed on a retry"), at: 0) }
        let duration = runs.last.flatMap { $0["duration"] as? Double ?? ($0["duration"] as? Int).map(Double.init) }.map { $0 / 1000 }
        var result = TestResult(suite: file, name: name, status: status, duration: duration, issues: issues)
        if issues.isEmpty, status == .failed { result.issues = [.init(message: "Failed in \(project ?? "the browser")", file: file, line: line)] }
        result.attachments = attachments.isEmpty ? nil : attachments
        return result
    }

    /// Files are relative to the report's rootDir (the testDir); results use project paths.
    static func projectPath(_ file: String, rootDir: String?, projectRoot: String, suiteFolder: String) -> String {
        let absolute = file.hasPrefix("/") ? file : rootDir.map { URL(fileURLWithPath: $0).appending(path: file).standardizedFileURL.path }
        let base = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
        for candidate in [absolute, absolute.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }].compactMap({ $0 }) {
            for root in [base, URL(fileURLWithPath: base).resolvingSymlinksInPath().path] where candidate.hasPrefix(root + "/") {
                return String(candidate.dropFirst(root.count + 1))
            }
        }
        return suiteFolder.isEmpty ? file : suiteFolder + "/" + file
    }
}

extension TestResult {
    /// One browser's result folded into another's: a failure anywhere fails the test.
    mutating func merge(_ other: TestResult) {
        if other.status == .failed || status == .skipped { status = other.status }
        issues += other.issues
        let all = (attachments ?? []) + (other.attachments ?? [])
        attachments = all.isEmpty ? nil : all
        if let time = other.duration { duration = max(duration ?? 0, time) }
    }
}

enum TestOutputText {
    /// Playwright's messages carry terminal colour codes.
    static func strippingColour(_ text: String) -> String {
        text.replacing(/\u{1B}\[[0-9;]*m/, with: "")
    }
}
