import Foundation

/// One question to Claude Code with no tools and no saved session, for small jobs like a
/// commit message: `claude -p <prompt> --tools ""`. Uses the user's own Claude Code login.
public enum ClaudeQuick {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func text(_ prompt: String, system: String? = nil, in root: URL) async throws -> String {
        guard Shell.which("claude") != nil else {
            throw Failure(message: "Claude Code isn’t installed, so Dante can’t ask it. Install it from claude.com/code.")
        }
        var arguments = ["claude", "-p", prompt, "--output-format", "text", "--tools", "", "--no-session-persistence"]
        if let system { arguments += ["--append-system-prompt", system] }
        let output = await Shell.run(arguments, in: root)
        guard output.succeeded, !output.stdout.isEmpty else {
            throw Failure(message: output.message.isEmpty ? "Claude didn’t answer." : output.message)
        }
        return output.stdout
    }
}

/// Builds the request for a commit message and tidies the answer.
public enum CommitMessage {
    public static let system = "You write git commit messages. Reply with the commit message only: no preamble, no code fences, no quotes."

    public static func prompt(diff: String, recentSubjects: [String], tasks: [String]) -> String {
        var parts = ["Write a commit message for the staged changes below."]
        parts.append("Use a short imperative subject line (under 72 characters), then a blank line and a brief body only if the change needs explaining. Say why, not just what.")
        if !recentSubjects.isEmpty {
            parts.append("Match the style of this repository's recent subjects:\n" + recentSubjects.prefix(10).map { "- \($0)" }.joined(separator: "\n"))
        }
        if !tasks.isEmpty {
            parts.append("Tasks in progress (mention one only if the diff clearly finishes it):\n" + tasks.map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append("Staged changes:\n" + diff)
        return parts.joined(separator: "\n\n")
    }

    /// Strips fences, quotes and "Here's a commit message:" lead-ins.
    public static func clean(_ answer: String) -> String {
        var lines = answer.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if let first = lines.first, first.lowercased().hasPrefix("here") && first.hasSuffix(":") { lines.removeFirst() }
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1, let first = text.first, first == text.last, "\"'`".contains(first) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}
