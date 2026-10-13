import Foundation

/// Claude reads the branch's diff before a pull request goes up, the way a reviewer would,
/// and answers with a short list of findings tagged by how much they matter.
public struct ReviewFinding: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable, CaseIterable {
        case blocker, issue, nit
    }

    public var severity: Severity
    public var file: String?
    public var line: Int?
    public var text: String
    public var id: String { "\(severity.rawValue):\(file ?? ""):\(line ?? 0):\(text)" }
}

public enum BranchReview {
    public static let system = """
        You review pull requests. Reply only with findings, one per line, each as \
        `- [blocker|issue|nit] path/to/file:line — what is wrong and what to do`. \
        Use blocker for bugs, security problems and data loss; issue for things worth fixing \
        before merging; nit for style. If nothing needs changing, reply with the single line `No findings.`
        """

    /// Diffs past `limit` characters are cut, so the request stays within one command line.
    public static func prompt(task: PlanTask?, diff: String, commits: [String], limit: Int = 150_000) -> String {
        var parts = ["Review the changes on this branch before I open a pull request."]
        if let task { parts.append("They finish task \(task.id): \(task.title).\(task.note.map { " Note: \($0)" } ?? "")") }
        parts.append("Look for bugs, missing error handling, security problems, leftover debugging, secrets, and tests that should have changed. Don't comment on what's fine.")
        if !commits.isEmpty { parts.append("Commits:\n" + commits.map { "- \($0)" }.joined(separator: "\n")) }
        let cut = diff.count > limit ? String(diff.prefix(limit)) + "\n[diff cut at \(limit) characters]" : diff
        parts.append("Changes:\n" + cut)
        return parts.joined(separator: "\n\n")
    }

    public static func parse(_ answer: String) -> [ReviewFinding] {
        answer.components(separatedBy: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") || line.hasPrefix("*") else { return nil }
            line = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let severity = ReviewFinding.Severity(rawValue: line[line.index(after: line.startIndex)..<close].lowercased().trimmingCharacters(in: .whitespaces))
            else { return nil }
            var rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            var file: String?
            var number: Int?
            for separator in [" — ", " - ", ": "] {
                guard let range = rest.range(of: separator) else { continue }
                let location = rest[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "` "))
                guard location.contains("."), !location.contains(" ") else { break }
                let pieces = location.split(separator: ":")
                file = pieces.first.map(String.init)
                number = pieces.count > 1 ? Int(pieces[1].split(separator: "-")[0]) : nil
                rest = String(rest[range.upperBound...])
                break
            }
            return ReviewFinding(severity: severity, file: file, line: number, text: rest.trimmingCharacters(in: .whitespaces))
        }
    }

    /// For the Claude panel: fix what the review found.
    public static func fixPrompt(_ findings: [ReviewFinding]) -> String {
        let list = findings.map { finding in
            "- [\(finding.severity.rawValue)] \(finding.file.map { $0 + (finding.line.map { ":\($0)" } ?? "") + " — " } ?? "")\(finding.text)"
        }
        return "A review of this branch found these. Fix the blockers and issues, and the nits if they're quick; tell me if you disagree with any.\n" + list.joined(separator: "\n")
    }
}
