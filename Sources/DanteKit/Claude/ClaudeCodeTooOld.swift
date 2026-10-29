import Foundation

/// Claude Code passes a model it doesn't know to the API, which refuses it with an error
/// naming the version it needs. An alias never gets that far: an older Claude Code maps
/// `opus` to the newest Opus it knew, so the picker would say one model while another ran.
public enum ClaudeCodeTooOld {
    /// A sentence saying what to do, when `text` is that refusal.
    public static func explain(_ text: String) -> String? {
        guard text.contains("claude_code_version_too_old") || text.contains("does not support this model") else { return nil }
        let have = first(#"Claude Code (\d+\.\d+\.\d+)"#, in: text)
        let need = first(#"version (\d+\.\d+\.\d+) or newer"#, in: text)
        return "Claude Code\(have.map { " \($0)" } ?? "") is too old for the model you picked"
            + (need.map { " (it needs \($0) or newer)" } ?? "")
            + ". Run `claude update` in the terminal and send your message again, or pick Claude Code’s default under More models to keep working on this version."
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
