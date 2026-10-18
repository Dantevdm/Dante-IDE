import Foundation

/// Security checks on the lines an agent's edit adds, before it's approved. A high or
/// critical finding makes the edit wait for you at any approval level.
public enum SecurityReview {
    /// Rules that judge a whole file, which a few added lines can't.
    static let wholeFileRules: Set<String> = ["docker.root", "gha.pwn-request", "deps.unlocked"]

    public static func findings(in change: ProposedChange, root: URL) -> [SecurityFinding] {
        let base = root.standardizedFileURL.path + "/"
        var path = change.url.path.hasPrefix(base) ? String(change.url.path.dropFirst(base.count)) : change.displayPath
        var findings: [SecurityFinding] = []
        for line in change.lines {
            if line.kind == .file { path = line.text.trimmingCharacters(in: .whitespaces); continue }
            guard line.kind == .added, !line.text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            for var finding in SecurityScanner.scan(text: line.text, path: path) where !wholeFileRules.contains(finding.rule) {
                finding.line = line.newNumber ?? 0
                findings.append(finding)
            }
        }
        return SecurityScanner.sorted(findings)
    }

    /// "Security: SQL built from a string (line 12) and 1 more."
    public static func note(for findings: [SecurityFinding]) -> String? {
        guard let worst = findings.first(where: { $0.severity >= .medium }) else { return nil }
        let more = findings.filter { $0.severity >= .medium }.count - 1
        let place = worst.line > 0 ? " (line \(worst.line))" : ""
        return "Security: \(worst.title)\(place)\(more > 0 ? " and \(more) more" : ""). \(worst.fix)"
    }

    public static func blocks(_ findings: [SecurityFinding]) -> Bool {
        findings.contains { $0.severity >= .high }
    }
}
