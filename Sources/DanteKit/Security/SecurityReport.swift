import Foundation
import Yams

/// One scan of a project: what was found, by what, and how the project scores.
public struct SecurityReport: Codable, Equatable, Sendable {
    public var date: Date
    /// Open findings in code that ships, worst first: these make the grade. Ignored ones are in
    /// `ignored`, and those in tests, docs and examples in `aside`.
    public var findings: [SecurityFinding]
    public var ignored: [SecurityFinding]
    /// Open findings in tests, docs and examples: listed on request, never graded.
    public var aside: [SecurityFinding]
    /// The project's own test paths, from `tests:` in `.dante/security.yaml`.
    public var testPaths: [String]
    /// The scanners that ran: "Dante", "Semgrep", "OSV".
    public var scanners: [String]
    public var files: Int
    public var seconds: Double

    /// `findings` and `aside` are sorted again into the two lists, so a copy can pass both back.
    public init(date: Date = Date(), findings: [SecurityFinding], aside: [SecurityFinding] = [], ignored: [SecurityFinding] = [],
                scanners: [String] = ["Dante"], files: Int = 0, seconds: Double = 0, testPaths: [String] = []) {
        self.date = date
        let all = SecurityScanner.sorted(Self.merged(findings + aside))
        self.findings = all.filter { !Self.isAside($0, testPaths: testPaths) }
        self.aside = all.filter { Self.isAside($0, testPaths: testPaths) }
        self.testPaths = testPaths
        self.ignored = ignored
        self.scanners = scanners
        self.files = files
        self.seconds = seconds
    }

    enum CodingKeys: String, CodingKey { case date, findings, ignored, aside, testPaths, scanners, files, seconds }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Reports saved before tests were set aside have everything in `findings`.
        self.init(date: try values.decode(Date.self, forKey: .date), findings: try values.decode([SecurityFinding].self, forKey: .findings),
                  aside: try values.decodeIfPresent([SecurityFinding].self, forKey: .aside) ?? [],
                  ignored: try values.decode([SecurityFinding].self, forKey: .ignored), scanners: try values.decode([String].self, forKey: .scanners),
                  files: try values.decode(Int.self, forKey: .files), seconds: try values.decode(Double.self, forKey: .seconds),
                  testPaths: try values.decodeIfPresent([String].self, forKey: .testPaths) ?? [])
    }

    /// Where a finding's file is: shipped code, tests, or docs and examples.
    public func place(of finding: SecurityFinding) -> CodePlace {
        finding.file.isEmpty ? .shipped : CodePlace.of(finding.file, tests: testPaths)
    }

    /// Credentials for a real service, which leak from a test file as much as from anywhere.
    static let realCredentials: Set<String> = [
        "secret.aws", "secret.private-key", "secret.anthropic", "secret.openai", "secret.github", "secret.slack", "secret.stripe", "secret.google",
    ]

    /// Findings in tests, docs and examples are set aside: a fixture's password or a docs page's
    /// `eval` isn't in what ships. A real service's key is graded wherever it is.
    static func isAside(_ finding: SecurityFinding, testPaths: [String]) -> Bool {
        guard !finding.file.isEmpty, CodePlace.of(finding.file, tests: testPaths) != .shipped else { return false }
        if realCredentials.contains(finding.rule) { return false }
        if finding.rule.hasPrefix("gitleaks.") { return ["generic", "password", "jwt"].contains { finding.rule.contains($0) } }
        // Dependency advisories are about the lockfile, wherever it sits.
        return finding.category != .dependencies
    }

    /// One finding per place and problem: when two scanners report the same line, the
    /// worse severity is kept and the sources are joined.
    static func merged(_ findings: [SecurityFinding]) -> [SecurityFinding] {
        var byKey: [String: SecurityFinding] = [:]
        var order: [String] = []
        for finding in findings {
            // Audits by different agents of the same line are the same problem.
            let kind = finding.rule.hasPrefix("audit.") ? "audit" : (finding.reference ?? finding.rule)
            let key = finding.line > 0 ? "\(finding.file):\(finding.line):\(kind)" : finding.id
            if var existing = byKey[key] {
                if finding.severity > existing.severity {
                    let sources = existing.source
                    existing = finding
                    existing.source = sources
                }
                if !existing.source.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(finding.source) {
                    existing.source += " + \(finding.source)"
                }
                byKey[key] = existing
            } else {
                byKey[key] = finding
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// 100 for nothing found, down by each finding's weight; a critical finding caps it at 49.
    public var score: Int {
        var total = 0
        var perRule: [String: Int] = [:]
        for finding in findings {
            // The tenth copy of the same problem matters less than the first.
            let seen = perRule[finding.rule, default: 0]
            perRule[finding.rule] = seen + 1
            total += seen < 3 ? finding.severity.weight : max(finding.severity.weight / 4, finding.severity == .info ? 0 : 1)
        }
        var score = max(0, 100 - total)
        if findings.contains(where: { $0.severity == .critical }) { score = min(score, 49) }
        return score
    }

    public var grade: String {
        switch score {
        case 90...: "A"
        case 75..<90: "B"
        case 60..<75: "C"
        case 40..<60: "D"
        default: "F"
        }
    }

    public func count(_ severity: SecurityFinding.Severity) -> Int { findings.filter { $0.severity == severity }.count }

    public func count(_ category: SecurityFinding.Category) -> Int { findings.filter { $0.category == category }.count }

    /// What appeared and what went away since an earlier report.
    public func changes(since earlier: SecurityReport) -> SecurityChanges {
        // Findings with the same rule, file and line text are matched nearest line first, so
        // repeats ("#2") that shift when a line above is added or removed still count as the same.
        let ignored = Set(ignored.map(\.lineID))
        // Sorted by this report's test paths, so a finding that moved aside isn't "fixed".
        let before = (earlier.findings + earlier.aside).filter { !Self.isAside($0, testPaths: testPaths) }
        let earlierByLine = Dictionary(grouping: before, by: \.lineID)
        var matchedNow = Set<String>(), matchedBefore = Set<String>()
        for (lineID, now) in Dictionary(grouping: findings, by: \.lineID) {
            guard let before = earlierByLine[lineID] else { continue }
            let pairs = now.flatMap { a in before.map { b in (a, b) } }.sorted { abs($0.0.line - $0.1.line) < abs($1.0.line - $1.1.line) }
            for (a, b) in pairs where !matchedNow.contains(a.id) && !matchedBefore.contains(b.id) {
                matchedNow.insert(a.id)
                matchedBefore.insert(b.id)
            }
        }
        var new = findings.filter { !matchedNow.contains($0.id) }
        let left = Set(before.map(\.id)).subtracting(matchedBefore)
        var fixed = before.filter { left.contains($0.id) && !ignored.contains($0.lineID) }
        // A finding's id includes its line's text, so editing a line that still has the problem
        // reads as one fixed and one new. Pair those up: same rule, same file, nearest line.
        var edited: [SecurityChanges.Edit] = []
        for finding in new {
            let candidates = fixed.enumerated().filter { $0.element.rule == finding.rule && $0.element.file == finding.file && abs($0.element.line - finding.line) <= 3 }
            guard let match = candidates.min(by: { abs($0.element.line - finding.line) < abs($1.element.line - finding.line) }) else { continue }
            edited.append(.init(before: match.element, after: finding))
            fixed.remove(at: match.offset)
        }
        let paired = Set(edited.map(\.after.id))
        new.removeAll { paired.contains($0.id) }
        return SecurityChanges(new: new, fixed: fixed, edited: edited)
    }

    // MARK: Saved reports

    /// The latest report per project on this Mac (Application Support/Dante/security), so the
    /// next scan can say what changed. Not in the repository.
    public static func folder() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Dante/security")
    }

    public static func url(for root: URL, in folder: URL = folder()) -> URL {
        let path = root.standardizedFileURL.path
        return folder.appending(path: "\(root.lastPathComponent)-\(String(SecurityFinding.fnv(path), radix: 16)).json")
    }

    public static func load(for root: URL, in folder: URL = folder()) -> SecurityReport? {
        guard let data = try? Data(contentsOf: url(for: root, in: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SecurityReport.self, from: data)
    }

    public func save(for root: URL, in folder: URL = folder()) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: Self.url(for: root, in: folder), options: .atomic)
    }
}

/// Accepted risks, in `.dante/security.yaml` so everyone on the project sees them:
///
///     ignore:
///       - id: "js.html:src/view.ts:1a2b3c"
///         reason: "Sanitised with DOMPurify"
///       - rule: gha.unpinned
///       - path: examples/
///     tests:            # test code Dante can't tell by its name or folder
///       - qa/
///       - "*_it.go"
public struct SecurityIgnores: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var id: String?
        public var rule: String?
        public var path: String?
        public var reason: String?

        public init(id: String? = nil, rule: String? = nil, path: String? = nil, reason: String? = nil) {
            self.id = id
            self.rule = rule
            self.path = path
            self.reason = reason
        }

        func matches(_ finding: SecurityFinding) -> Bool {
            if let id, id != finding.id, id != finding.lineID { return false }
            if let rule, rule != finding.rule { return false }
            if let path, !(finding.file == path || finding.file.hasPrefix(path.hasSuffix("/") ? path : path + "/")) { return false }
            return id != nil || rule != nil || path != nil
        }
    }

    public var entries: [Entry]
    /// More paths that hold only tests, besides each language's own conventions (`CodePlace`).
    public var tests: [String]

    public init(entries: [Entry] = [], tests: [String] = []) {
        self.entries = entries
        self.tests = tests
    }

    public static let path = ".dante/security.yaml"

    public static func parse(_ text: String) -> SecurityIgnores {
        guard let root = (try? SafeYAML.load(text)) as? [String: Any] else { return SecurityIgnores() }
        let tests = (root["tests"] as? [Any])?.map { "\($0)" } ?? (root["tests"] as? String).map { [$0] } ?? []
        let list = root["ignore"] as? [Any] ?? []
        return SecurityIgnores(entries: list.compactMap { item in
            if let id = item as? String { return Entry(id: id) }
            guard let map = item as? [String: Any] else { return nil }
            let entry = Entry(id: map["id"] as? String, rule: map["rule"] as? String, path: map["path"] as? String, reason: map["reason"] as? String)
            return entry.id ?? entry.rule ?? entry.path == nil ? nil : entry
        }, tests: tests.filter { !$0.isEmpty })
    }

    public static func load(root: URL) -> SecurityIgnores {
        (try? String(contentsOf: root.appending(path: path), encoding: .utf8)).map(parse) ?? SecurityIgnores()
    }

    public func reason(for finding: SecurityFinding) -> String?? {
        guard let entry = entries.first(where: { $0.matches(finding) }) else { return nil }
        return .some(entry.reason)
    }

    /// Splits findings into open and ignored.
    public func apply(_ findings: [SecurityFinding]) -> (open: [SecurityFinding], ignored: [SecurityFinding]) {
        var open: [SecurityFinding] = []
        var ignored: [SecurityFinding] = []
        for finding in findings {
            if entries.contains(where: { $0.matches(finding) }) { ignored.append(finding) } else { open.append(finding) }
        }
        return (open, ignored)
    }

    /// The file's text with one more entry, leaving everything already there (comments too) alone.
    public static func adding(_ entry: Entry, to text: String?) -> String {
        var lines: [String] = []
        if let id = entry.id { lines.append("  - id: \(quoted(id))") }
        else if let rule = entry.rule { lines.append("  - rule: \(quoted(rule))") }
        else if let path = entry.path { lines.append("  - path: \(quoted(path))") }
        if let reason = entry.reason, !reason.isEmpty { lines.append("    reason: \(quoted(reason))") }
        let block = lines.joined(separator: "\n")
        guard var text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "# Security findings accepted on purpose. Dante's Security area writes this file.\nignore:\n\(block)\n"
        }
        if !text.hasSuffix("\n") { text += "\n" }
        if text.range(of: #"(?m)^ignore:[ \t]*(\[[ \t]*\])?[ \t]*$"#, options: .regularExpression) == nil {
            return text + "ignore:\n\(block)\n"
        }
        text = text.replacingOccurrences(of: #"(?m)^ignore:[ \t]*\[[ \t]*\][ \t]*$"#, with: "ignore:", options: .regularExpression)
        return text + block + "\n"
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// What changed between two scans: findings that appeared, ones that went, and ones whose line
/// was edited but still has the problem.
public struct SecurityChanges: Sendable, Equatable {
    public struct Edit: Sendable, Equatable {
        public let before: SecurityFinding
        public let after: SecurityFinding
    }

    public let new: [SecurityFinding]
    public let fixed: [SecurityFinding]
    public let edited: [Edit]

    /// The line before the edit, by the current finding's id.
    public func before(_ id: String) -> SecurityFinding? { edited.first { $0.after.id == id }?.before }
}
