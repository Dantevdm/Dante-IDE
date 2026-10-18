import Foundation

/// What Dante asks Claude or Codex to do about security: fix findings (with the other agent
/// checking the fix), and audit the project the way a reviewer would, POPIA included.
public enum SecurityBrief {
    /// The panel message that fixes findings. `partner` is the other agent's tool name when
    /// it can be asked (ask_codex, ask_claude).
    public static func fix(_ findings: [SecurityFinding], partner: (name: String, tool: String)?) -> String {
        var lines = ["Fix \(findings.count == 1 ? "this security finding" : "these \(findings.count) security findings") from Dante's scan:", ""]
        for (index, finding) in findings.prefix(25).enumerated() {
            lines.append("\(index + 1). [\(finding.severity.rawValue)] \(finding.title) at \(finding.location)\(finding.reference.map { " (\($0))" } ?? "")")
            if !finding.evidence.isEmpty { lines.append("   Line: \(finding.evidence)") }
            lines.append("   Why: \(finding.why)")
            lines.append("   Suggested fix: \(finding.fix)")
        }
        if findings.count > 25 { lines.append("…and \(findings.count - 25) more of the same kinds; fix the ones above first.") }
        lines += [
            "",
            "How to fix them:",
            "- Make the smallest change that removes the risk and keeps the behaviour. Don't refactor around it.",
            "- Secrets: read them from the environment (or the platform's secret store), add the variable to .env.example with a placeholder, and tell me which keys to rotate. Never print a secret's value.",
            "- Personal information: mask it in logs, keep it out of fixtures (generate fake values), and encrypt sensitive columns with a migration that keeps existing data.",
            "- Injection: use parameters or argument arrays, never string building.",
            "- Dependencies: upgrade to the fixed version and update the lockfile with the project's package manager.",
            "- Where the project has tests, add or adjust one that would have caught the problem.",
            "- If a finding is a false positive, say why instead of changing the code, and I'll mark it as accepted.",
        ]
        if let partner {
            lines.append("- When you're done, ask \(partner.name) to check your changes with \(partner.tool) (why: \"check the security fixes\"), and tell me what it said.")
        }
        lines.append("Finish with a short list: what you changed for each finding, and anything I still need to do by hand.")
        return lines.joined(separator: "\n")
    }

    /// A read-only audit: the agent looks through the code and answers in a format Dante reads back.
    public static func audit(known: [SecurityFinding], projectName: String) -> String {
        var lines = [
            "You are auditing \(projectName) for security and privacy, as an experienced application-security reviewer would before a launch. Read the code; don't change anything and don't run commands that change state.",
            "",
            "Look for what pattern scanners miss:",
            "- Authentication and sessions: missing auth checks on routes, broken access control (one user reading another's data by id), weak session handling, missing rate limits on login and password reset.",
            "- Injection of every kind: SQL, NoSQL, shell, template, path traversal, SSRF (fetching user-supplied URLs), deserialisation.",
            "- Personal information under South Africa's POPIA (and GDPR where it applies): where it's collected, logged, stored and sent; whether ID numbers, health, financial and children's data are encrypted at rest and masked in logs; data kept longer than needed; personal information sent to third parties or other countries (section 72); whether a breach could be noticed and reported (section 22); access to personal information limited to who needs it (section 19).",
            "- Encryption: data in transit (TLS everywhere, HSTS), at rest (databases, backups, files, caches), key management and rotation, password hashing.",
            "- Secrets and configuration: credentials in code or images, debug modes, permissive CORS, missing security headers, default accounts.",
            "- Supply chain and CI: unpinned actions, scripts piped to shells, workflows that run untrusted code with secrets.",
            "- Error handling that leaks internals, and logging that leaks data.",
            "",
            "Report every real problem, most serious first, one per line, exactly like this:",
            "- [critical|high|medium|low] path/to/file.ext:line — short title — how to fix it",
            "Use the project-relative path; use line 0 when it's about a whole file or the design. After the list, add at most five sentences on the project's overall security and privacy posture, starting with \"Overall:\".",
        ]
        if !known.isEmpty {
            lines += ["", "Dante's scanner already reported these; don't repeat them, but say if one is worse than its severity suggests:"]
            lines += known.prefix(40).map { "- [\($0.severity.rawValue)] \($0.location) — \($0.title)" }
        }
        return lines.joined(separator: "\n")
    }

    /// Reads an audit reply back into findings.
    public static func parseAudit(_ reply: String, source: String) -> (findings: [SecurityFinding], overall: String?) {
        var findings: [SecurityFinding] = []
        var overall: String?
        for raw in reply.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if overall == nil, let range = line.range(of: "Overall:") {
                overall = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("- [") || line.hasPrefix("* [") || line.hasPrefix("[") else { continue }
            line = line.drop { $0 == "-" || $0 == "*" || $0 == " " }.description
            guard let close = line.firstIndex(of: "]"),
                  let severity = SecurityFinding.Severity(rawValue: line[line.index(after: line.startIndex)..<close].lowercased()) else { continue }
            let rest = String(line[line.index(after: close)...])
            var parts = rest.components(separatedBy: " — ")
            if parts.count < 3 { parts = rest.components(separatedBy: " – ") }
            if parts.count < 3 { parts = rest.components(separatedBy: " - ") }
            guard parts.count >= 3 else { continue }
            let location = parts[0].trimmingCharacters(in: .whitespaces)
            let title = parts[1].trimmingCharacters(in: .whitespaces)
            let fix = parts[2...].joined(separator: " — ").trimmingCharacters(in: .whitespaces)
            var file = location
            var number = 0
            if let colon = location.lastIndex(of: ":"), let value = Int(location[location.index(after: colon)...]) {
                file = String(location[..<colon])
                number = value
            }
            // The title says what's wrong; the fix only helps when it doesn't ("…a key from the secret store").
            var category = SecurityToolOutput.categoryFor(title)
            if category == .code { category = SecurityToolOutput.categoryFor(fix) }
            findings.append(SecurityFinding(
                rule: "audit.\(source.lowercased())", category: category == .code ? .audit : category, severity: severity,
                title: title, why: "\(source) found this reading the code.", fix: fix, file: file, line: number,
                evidence: "", reference: nil, source: source))
        }
        return (findings, overall)
    }
}
