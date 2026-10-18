import Foundation

/// The Stage's caption: the end of what Claude is saying, as it streams in, so the newest
/// words are always on screen. Whole sentences where they fit, else the last words.
public enum StageCaption {
    public static let length = 200

    public static func tail(of markdown: String, length: Int = length) -> String {
        let text = SpokenReply.plain(markdown)
        guard text.count > length else { return text }
        var result = ""
        for sentence in SpokenReply.sentences(text).reversed() {
            if !result.isEmpty, result.count + sentence.count + 1 > length { break }
            result = sentence + (result.isEmpty ? "" : " ") + result
        }
        if result.count <= length { return result }
        // One long sentence: its last words, from a word boundary.
        let end = text.suffix(length - 1)
        let start = end.firstIndex(of: " ").map { end.index(after: $0) } ?? end.startIndex
        return "…" + end[start...]
    }
}

/// The Stage's numbers for today, from the agent ledger.
public struct StageTally: Equatable, Sendable {
    public var localJobs = 0
    public var claudeJobs = 0
    /// Jobs Grok and Jev did.
    public var cloudJobs = 0
    public var tokensKeptLocal = 0
    /// The busiest local model today, if any.
    public var topLocalModel: String?

    public init() {}

    public init(jobs: [AgentJob], since start: Date) {
        var models: [String: Int] = [:]
        for job in jobs where job.date >= start {
            switch job.provider {
            case .local:
                localJobs += 1
                tokensKeptLocal += job.tokens
                models[job.model, default: 0] += 1
            case .claude:
                claudeJobs += 1
            case .grok, .jev:
                cloudJobs += 1
            }
        }
        topLocalModel = models.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }
}
