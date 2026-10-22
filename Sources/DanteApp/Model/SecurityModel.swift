import DanteKit
import Foundation

/// The Security area's state for one window: the latest report, the one before it, a scan or
/// audit in progress.
@MainActor @Observable
final class SecurityModel {
    var report: SecurityReport?
    /// The last report that found something different, for "2 new, 3 fixed". A scan that
    /// finds the same things keeps it, so the changes stay until something else changes.
    var previous: SecurityReport?
    var scanning = false
    var progress = ""
    /// The agent auditing the code, while it does.
    var auditing: AgentEngine?
    var auditStarted: Date?
    var auditOverall: String?
    var errorMessage: String?
    private var loaded = false

    /// The saved report, the first time the area opens.
    func loadSaved(root: URL) {
        guard !loaded else { return }
        loaded = true
        report = SecurityReport.load(for: root)
    }

    func scan(root: URL, files: [String]) async {
        guard !scanning else { return }
        scanning = true
        progress = "Starting"
        defer { scanning = false; progress = "" }
        let earlier = report ?? SecurityReport.load(for: root)
        let online = Preferences.shared.checksDependenciesOnline
        let scanned = await ProjectSecurity.scan(root: root, files: files, options: .init(onlineAdvisories: online, save: false)) { message in
            Task { @MainActor [weak self] in self?.progress = message }
        }
        // Audit findings stay until the next audit.
        let fresh = ProjectSecurity.keepingAudits(scanned, from: earlier)
        if previous == nil || Self.differ(fresh, earlier) { previous = earlier }
        report = fresh
        fresh.save(for: root)
    }

    /// The agent in charge is running the scan through Dante's `security_report` tool.
    func agentScanStarted(by agent: String) {
        scanning = true
        progress = "Scanning for \(agent)"
    }

    /// The agent's scan is saved: show it, compared with the one before.
    func agentScanFinished(root: URL) {
        scanning = false
        progress = ""
        loaded = true
        guard let fresh = SecurityReport.load(for: root) else { return }
        if fresh.date != report?.date, previous == nil || Self.differ(fresh, report) { previous = report }
        report = fresh
    }

    private static func differ(_ report: SecurityReport, _ earlier: SecurityReport?) -> Bool {
        Set(report.findings.map(\.id)) != Set(earlier?.findings.map(\.id) ?? [])
    }

    /// A read-only audit by Claude or Codex, outside the panel's conversation.
    func audit(with engine: AgentEngine, root: URL, claudeExecutable: String?) async {
        guard auditing == nil else { return }
        auditing = engine
        auditStarted = Date()
        errorMessage = nil
        defer { auditing = nil; auditStarted = nil }
        let prompt = SecurityBrief.audit(known: report?.findings.filter { !$0.rule.hasPrefix("audit.") } ?? [], projectName: root.lastPathComponent)
        let started = Date()
        let ledger = AgentLedger.standard
        do {
            let text: String
            let model: String
            var tokens = (input: 0, output: 0)
            switch engine {
            case .codex:
                guard let path = Session.codexPath else { throw Failure(message: "Codex isn’t installed.") }
                let chosen = Preferences.shared.codexModel.isEmpty ? nil : Preferences.shared.codexModel
                let reply = try await Codex(executable: path).ask(prompt, in: root.path, model: chosen, timeout: 1200)
                text = reply.text
                model = chosen ?? "codex"
                tokens = (reply.inputTokens, reply.outputTokens)
            case .claude:
                guard let executable = claudeExecutable else { throw Failure(message: "Claude Code isn’t installed.") }
                let chosen = Preferences.shared.claudeModel.argument
                let reply = try await ClaudeOpinion(executable: executable).ask(prompt, in: root.path, model: chosen, timeout: 1200)
                text = reply.text
                model = chosen ?? "claude"
                tokens = (reply.inputTokens, reply.outputTokens)
            }
            let parsed = SecurityBrief.parseAudit(text, source: engine.title)
            auditOverall = parsed.overall
            ledger.append(AgentJob(kind: "audit", provider: engine == .codex ? .codex : .claude, model: model, project: root.lastPathComponent,
                                   promptTokens: tokens.input, outputTokens: tokens.output, seconds: Date().timeIntervalSince(started),
                                   requestedBy: "you", title: "Security audit", why: "Find what pattern scanners miss",
                                   gist: parsed.overall.flatMap { AgentJob.gist(of: $0) } ?? "\(parsed.findings.count) findings"))
            let base = report ?? SecurityReport(findings: [])
            let ignores = SecurityIgnores.load(root: root)
            let split = ignores.apply(parsed.findings)
            // This agent's earlier audit is replaced; another agent's stays, so both can be compared.
            let kept = base.findings.filter { $0.rule != "audit.\(engine.title.lowercased())" }
            let merged = SecurityReport(date: Date(), findings: kept + split.open, aside: base.aside.filter { $0.rule != "audit.\(engine.title.lowercased())" },
                                        ignored: base.ignored + split.ignored, scanners: Array(Set(base.scanners + ["\(engine.title) audit"])).sorted(),
                                        files: base.files, seconds: base.seconds, testPaths: ignores.tests)
            report = merged
            merged.save(for: root)
        } catch {
            errorMessage = error.localizedDescription
            ledger.append(AgentJob(kind: "audit", provider: engine == .codex ? .codex : .claude, model: engine.title.lowercased(),
                                   project: root.lastPathComponent, seconds: Date().timeIntervalSince(started), outcome: .failed,
                                   requestedBy: "you", title: "Security audit", gist: AgentJob.gist(of: error.localizedDescription)))
        }
    }

    /// Accepts a finding on purpose: written to .dante/security.yaml for everyone on the project.
    func ignore(_ finding: SecurityFinding, reason: String, wholeRule: Bool, root: URL) {
        let url = root.appending(path: SecurityIgnores.path)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let entry = wholeRule ? SecurityIgnores.Entry(rule: finding.rule, reason: reason) : SecurityIgnores.Entry(id: finding.id, reason: reason)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SecurityIgnores.adding(entry, to: existing).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard var report else { return }
        let matches = { (other: SecurityFinding) in wholeRule ? other.rule == finding.rule : other.id == finding.id }
        let moved = (report.findings + report.aside).filter(matches)
        report = SecurityReport(date: report.date, findings: report.findings.filter { !matches($0) }, aside: report.aside.filter { !matches($0) },
                                ignored: report.ignored + moved, scanners: report.scanners, files: report.files, seconds: report.seconds,
                                testPaths: report.testPaths)
        self.report = report
        report.save(for: root)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
