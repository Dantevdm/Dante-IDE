import Foundation

/// "Hey Dante": the phrase that starts listening hands-free, and what was said after it.
public enum WakeWord {
    static let pattern = try! NSRegularExpression(
        pattern: #"\b(?:hey|hi|hello|okay|ok|yo)[\s,.!-]+(?:dante|donte|dantay|dante's|jarvis)\b[\s,.!?:;-]*"#,
        options: [.caseInsensitive])

    /// What follows the last wake phrase in a transcript ("" when nothing yet), or nil when
    /// it wasn't said.
    public static func command(in transcript: String) -> String? {
        let range = NSRange(transcript.startIndex..., in: transcript)
        guard let match = pattern.matches(in: transcript, range: range).last,
              let end = Range(match.range, in: transcript)?.upperBound else { return nil }
        return String(transcript[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
