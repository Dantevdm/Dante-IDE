import Foundation

/// A whole-project scan: Dante's own rules, plus any scanners installed on this Mac, with
/// ignores applied and the report saved for the next comparison. Used by the Security area
/// and by `dante scan` in a terminal or CI.
public enum ProjectSecurity {
    public struct Options: Sendable {
        /// Run installed scanners (Semgrep, Gitleaks, OSV-Scanner, npm audit, govulncheck…).
        public var externalTools: Bool
        /// Ask OSV.dev about the project's dependencies; sends package names and versions.
        public var onlineAdvisories: Bool
        public var save: Bool

        public init(externalTools: Bool = true, onlineAdvisories: Bool = false, save: Bool = true) {
            self.externalTools = externalTools
            self.onlineAdvisories = onlineAdvisories
            self.save = save
        }
    }

    public static func scan(root: URL, files: [String]? = nil, options: Options = Options(),
                            progress: (@Sendable (String) -> Void)? = nil) async -> SecurityReport {
        let started = Date()
        progress?("Listing files")
        let files = files ?? FileIndex.scan(root)
        let rules = ClaudeRules.load(projectRoot: root)
        let never: @Sendable (String) -> Bool = { path in rules.never.contains { ClaudeRules.path(path, matches: $0) } }
        progress?("Asking git what's tracked")
        let git = await gitView(root: root)
        progress?("Reading \(files.count) files")
        var findings = await Task.detached(priority: .userInitiated) {
            SecurityScanner.scan(files: files, read: { path in
                let url = root.appending(path: path)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= SecurityScanner.sizeLimit else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            }, git: git, never: never)
        }.value
        var scanners = ["Dante"]
        if options.externalTools {
            for tool in SecurityTool.all where tool.applies(root) && (options.onlineAdvisories || !tool.sendsDependencies) {
                guard let path = tool.locate() else { continue }
                progress?("Running \(tool.name)")
                if let found = await tool.run(executable: path, root: root) {
                    findings += found.filter { !never($0.file) }
                    scanners.append(tool.name)
                }
            }
        }
        if options.onlineAdvisories {
            progress?("Checking dependencies with OSV.dev")
            let dependencies = Dependencies.read(root: root, files: files.filter { !never($0) })
            if let advisories = try? await OSV().findings(for: dependencies) {
                findings += advisories
                scanners.append("OSV.dev")
            }
        }
        let ignores = SecurityIgnores.load(root: root)
        let split = ignores.apply(findings)
        let report = SecurityReport(findings: split.open, ignored: split.ignored, scanners: scanners, files: files.count,
                                    seconds: Date().timeIntervalSince(started), testPaths: ignores.tests)
        if options.save { report.save(for: root) }
        return report
    }

    static func gitView(root: URL) async -> SecurityScanner.GitView? {
        let tracked = await Shell.run(["git", "ls-files", "-z"], in: root, trimming: false)
        guard tracked.succeeded else { return nil }
        let ignored = await Shell.run(["git", "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], in: root, trimming: false)
        func paths(_ output: String) -> Set<String> { Set(output.split(separator: "\0").map(String.init)) }
        var ignoredPaths = paths(ignored.stdout)
        // Ignored folders come back as "folder/": every file under them counts.
        let folders = ignoredPaths.filter { $0.hasSuffix("/") }
        if !folders.isEmpty {
            for file in FileIndex.scan(root) where folders.contains(where: { file.hasPrefix($0) }) { ignoredPaths.insert(file) }
        }
        return SecurityScanner.GitView(tracked: paths(tracked.stdout), ignored: ignoredPaths)
    }

    /// A new scan with an agent's audit findings from the saved report carried over (they stay
    /// until the next audit), saved for the Security page. What `security_report` runs.
    public static func refresh(root: URL, onlineAdvisories: Bool) async -> SecurityReport {
        let earlier = SecurityReport.load(for: root)
        let report = keepingAudits(await scan(root: root, options: .init(onlineAdvisories: onlineAdvisories, save: false)), from: earlier)
        report.save(for: root)
        return report
    }

    /// `fresh` with the audit findings of `earlier`, which a scan doesn't make.
    public static func keepingAudits(_ fresh: SecurityReport, from earlier: SecurityReport?) -> SecurityReport {
        let audit = earlier?.findings.filter { $0.rule.hasPrefix("audit.") } ?? []
        guard !audit.isEmpty else { return fresh }
        return SecurityReport(date: fresh.date, findings: fresh.findings + audit, aside: fresh.aside, ignored: fresh.ignored, scanners: fresh.scanners,
                              files: fresh.files, seconds: fresh.seconds, testPaths: fresh.testPaths)
    }

    /// A short text summary for the terminal.
    /// `all` lists the findings in tests, docs and examples too, after the graded ones.
    public static func summary(_ report: SecurityReport, root: URL, limit: Int = 40, all: Bool = false) -> String {
        var lines = ["Security: \(report.grade) (\(report.score)/100) · \(report.findings.count) finding\(report.findings.count == 1 ? "" : "s") in \(report.files) files · \(report.scanners.joined(separator: ", "))"]
        let counts = SecurityFinding.Severity.allCases.compactMap { severity -> String? in
            let count = report.count(severity)
            return count == 0 ? nil : "\(count) \(severity.rawValue)"
        }
        if !counts.isEmpty { lines.append(counts.joined(separator: " · ")) }
        for finding in report.findings.prefix(limit) {
            lines.append("")
            lines.append("[\(finding.severity.rawValue)] \(finding.title) — \(finding.location)")
            if !finding.evidence.isEmpty { lines.append("    \(finding.evidence)") }
            lines.append("    Fix: \(finding.fix)")
        }
        if report.findings.count > limit { lines.append("\n… and \(report.findings.count - limit) more.") }
        if all, !report.aside.isEmpty {
            lines.append("\nIn tests, docs and examples (not graded):")
            for finding in report.aside.prefix(limit) {
                lines.append("[\(finding.severity.rawValue)] \(finding.title) — \(finding.location)")
            }
            if report.aside.count > limit { lines.append("… and \(report.aside.count - limit) more.") }
        } else if !report.aside.isEmpty {
            lines.append("\n\(report.aside.count) more in tests, docs and examples, not graded (dante scan --all lists them).")
        }
        if !report.ignored.isEmpty { lines.append("\n\(report.ignored.count) ignored in \(SecurityIgnores.path).") }
        return lines.joined(separator: "\n")
    }
}
