import Foundation

/// Lines a diff adds that look like a secret: cloud and API keys, private keys, tokens,
/// and passwords assigned a literal. Checked before a commit message is drafted, so the
/// warning doesn't depend on Claude noticing.
public struct SecretFinding: Equatable, Sendable {
    public var file: String
    /// The line in the new file.
    public var line: Int
    public var kind: String

    public var sentence: String { "\(kind) in \(file):\(line)" }
}

public enum SecretScan {
    private static let patterns: [(kind: String, regex: NSRegularExpression)] = [
        ("An AWS access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("A private key", #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY"#),
        ("An Anthropic API key", #"\bsk-(?:ant)-[A-Za-z0-9_\-]{20,}"#),
        ("An OpenAI API key", #"\bsk-(?:proj-)?[A-Za-z0-9]{32,}"#),
        ("A GitHub token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{40,}"#),
        ("A Slack token", #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
        ("A Stripe secret key", #"\b[rs]k_live_[A-Za-z0-9]{20,}"#),
        ("A Google API key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        ("A password", #"(?i)\b(?:password|passwd|pwd|secret|api_?key|access_?token|auth_?token)\b["']?\s*[:=]\s*["'][^"'\s$<{]{6,}["']"#),
        ("A connection string with a password", #"\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^:/\s"']+:[^@/\s"'$<{]{3,}@"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// Placeholder values that aren't secrets.
    private static let placeholders = ["example", "changeme", "change-me", "password", "xxxxxx", "your_", "your-", "dummy", "placeholder", "redacted", "******", "test", "secret"]

    /// Findings in the lines a unified diff adds, at most one per line.
    public static func findings(inDiff diff: String) -> [SecretFinding] {
        var found: [SecretFinding] = []
        var file = ""
        var line = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("+++ ") {
                let path = raw.dropFirst(4)
                file = path.hasPrefix("b/") ? String(path.dropFirst(2)) : String(path)
                continue
            }
            if raw.hasPrefix("@@") {
                // "@@ -a,b +c,d @@": the new file's lines start at c.
                if let plus = raw.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    line = Int(plus.dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                continue
            }
            if raw.hasPrefix("+") {
                let text = String(raw.dropFirst())
                if let kind = kind(of: text) { found.append(SecretFinding(file: file, line: line, kind: kind)) }
                line += 1
            } else if !raw.hasPrefix("-"), !raw.hasPrefix("\\") {
                line += 1
            }
        }
        return found
    }

    static func kind(of line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        for (kind, regex) in patterns {
            guard let match = regex.firstMatch(in: line, range: range), let found = Range(match.range, in: line) else { continue }
            let value = line[found].lowercased()
            if placeholders.contains(where: { value.contains("\"\($0)") || value.contains("'\($0)") || value.contains(":\($0)@") }) { continue }
            return kind
        }
        return nil
    }

    /// One sentence for a list of findings.
    public static func warning(_ findings: [SecretFinding]) -> String? {
        guard let first = findings.first else { return nil }
        let more = findings.count - 1
        let sentence = first.sentence.prefix(1).lowercased() + first.sentence.dropFirst()
        return "This commit adds what looks like a secret: \(sentence)" + (more > 0 ? " and \(more) more" : "") + ". Take it out before committing."
    }
}
