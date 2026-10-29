import Foundation

/// A message typed while a step waits for approval answers that step. Queued behind it, the
/// message would wait for the turn to end and the turn for the approval, so neither moved:
/// "yes, go ahead please" approves it, "no" declines it, and anything else declines it with
/// the message, which reaches the agent at once (as Claude Code does with "No, and tell
/// Claude what to do differently").
public enum WaitingReply: Equatable, Sendable {
    case approve, decline, instead(String)

    public static func read(_ text: String) -> WaitingReply {
        let words = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty && !fillers.contains($0) }
        let phrase = words.joined(separator: " ")
        if yes.contains(phrase) { return .approve }
        if no.contains(phrase) { return .decline }
        return .instead(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let fillers: Set<String> = ["please", "pls", "ok", "okay", "sure", "yeah", "yep", "just", "then", "thanks", "thank", "you"]
    private static let yes: Set<String> = [
        "", "yes", "go ahead", "yes go ahead", "go", "do it", "yes do it", "approve", "approve it", "allow", "allow it",
        "continue", "proceed", "carry on", "go for it", "y",
    ]
    private static let no: Set<String> = ["no", "don't", "dont", "decline", "stop", "no don't", "n", "cancel"]

    /// What the agent is told when the step is declined for a typed message.
    public static func declined(saying text: String) -> String {
        "The user didn’t approve this step and replied instead: \(text)"
    }
}
