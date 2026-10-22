import Foundation

/// Conservative, local classification; deciding how to route never spends cloud tokens.
public enum TaskRouting {
    public enum Difficulty: String, Sendable { case routine, standard, complex }
    public struct Decision: Equatable, Sendable {
        public let difficulty: Difficulty
        public let localKind: DelegateKind?
        public let reason: String
        public var effort: String { difficulty == .routine ? "low" : "medium" }
        public var instructions: String {
            "Usage budget: \(reason) Keep investigation scoped to the request. Use local delegate for bounded summaries, log triage, boilerplate drafts and writing when available; verify code drafts. Ask another cloud agent only for a concrete unresolved risk or an explicit request for review. Escalate investigation when evidence demands it; do not claim success without checking."
        }
    }

    public static func classify(_ text: String, hasAttachments: Bool = false, hasInstructions: Bool = false) -> Decision {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Risk takes priority over apparent simplicity. Unknown and follow-up requests
        // retain normal reasoning rather than guessing from message length.
        let risk = ["security", "auth", "password", "secret", "permission", "migration", "production", "deploy", "race condition", "deadlock", "architecture", "refactor", "payment", "delete", "vulnerability", "encrypt"]
        if risk.contains(where: lower.contains) {
            return .init(difficulty: .complex, localKind: nil, reason: "This request may affect correctness, security or system design.")
        }
        // Only literal, self-contained prose transformations go directly to Ollama.
        // Project questions, code changes, attachments and supplied app instructions stay agent-backed.
        if !hasAttachments, !hasInstructions, text.count <= 12_000,
           let colon = lower.firstIndex(of: ":"), lower[..<colon].count <= 100 {
            let command = String(lower[..<colon])
            let body = lower[lower.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            let writing = ["reword this", "rewrite this", "fix the grammar", "proofread this", "translate this"]
            let summaries = ["summarize this", "summarise this", "condense this"]
            let kind: DelegateKind? = writing.contains(where: command.hasPrefix) ? .writing : (summaries.contains(where: command.hasPrefix) ? .summary : nil)
            let references = ["above", "previous", "attached", "our conversation", "this project", "```", "func ", "class ", "select "]
            if body.count >= 20, let kind, !references.contains(where: body.contains),
               !["file", "code", "project", "repo", "above", "previous", "function", "script"].contains(where: command.contains) {
                return .init(difficulty: .routine, localKind: kind, reason: "Self-contained prose transformation; no project access needed.")
            }
        }
        let routine = ["rename ", "change the label", "change the color", "change the colour", "fix the typo", "update the text", "remove the button", "add a tooltip", "format this", "explain this function"]
        if !hasAttachments, text.count < 1500, routine.contains(where: lower.hasPrefix) {
            return .init(difficulty: .routine, localKind: nil, reason: "A focused, routine change or explanation.")
        }
        return .init(difficulty: .standard, localKind: nil, reason: "The request needs project or conversation context.")
    }

    /// Prefer a small suitable model that fits comfortably; never load a cloud, vision
    /// or embedding model as a supposed local saving.
    public static func localModel(for kind: DelegateKind, installed: [OllamaModel], memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String? {
        let budget = Int64(min(memory / 4, UInt64(Int64.max)))
        let usable = installed.filter { !$0.isCloud && !$0.isEmbedding && !$0.isVision && $0.size > 0 && $0.size <= budget }
        for family in kind.preferred {
            if let model = usable.filter({ $0.name.lowercased().hasPrefix(family) }).min(by: { $0.size < $1.size }) { return model.name }
        }
        return nil
    }
}
