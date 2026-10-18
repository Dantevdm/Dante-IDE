import Foundation
import Yams

/// One scan of a project: what was found, by what, and how the project scores.
public struct SecurityReport: Codable, Equatable, Sendable {
    public var date: Date
    /// Open findings, worst first; ignored ones are in `ignored`.
    public var findings: [SecurityFinding]
    public var ignored: [SecurityFinding]
    /// The scanners that ran: "Dante", "Semgrep", "OSV".
    public var scanners: [String]
    public var files: Int
    public var seconds: Double

    public init(date: Date = Date(), findings: [SecurityFinding], ignored: [SecurityFinding] = [], scanners: [String] = ["Dante"],
                files: Int = 0, seconds: Double = 0) {
        self.date = date
        self.findings = SecurityScanner.sorted(Self.merged(findings))
        self.ignored = ignored
        self.scanners = scanners
        self.files = files
        self.seconds = seconds
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
    public func changes(since earlier: SecurityReport) -> (new: [SecurityFinding], fixed: [SecurityFinding]) {
        let before = Set(earlier.findings.map(\.id))
        let now = Set(findings.map(\.id))
        return (findings.filter { !before.contains($0.id) }, earlier.findings.filter { !now.contains($0.id) && !ignored.map(\.id).contains($0.id) })
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
            if let id, id != finding.id { return false }
            if let rule, rule != finding.rule { return false }
            if let path, !(finding.file == path || finding.file.hasPrefix(path.hasSuffix("/") ? path : path + "/")) { return false }
            return id != nil || rule != nil || path != nil
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    public static let path = ".dante/security.yaml"

    public static func parse(_ text: String) -> SecurityIgnores {
        guard let root = (try? Yams.load(yaml: text)) as? [String: Any], let list = root["ignore"] as? [Any] else { return SecurityIgnores() }
        return SecurityIgnores(entries: list.compactMap { item in
            if let id = item as? String { return Entry(id: id) }
            guard let map = item as? [String: Any] else { return nil }
            let entry = Entry(id: map["id"] as? String, rule: map["rule"] as? String, path: map["path"] as? String, reason: map["reason"] as? String)
            return entry.id ?? entry.rule ?? entry.path == nil ? nil : entry
        })
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
