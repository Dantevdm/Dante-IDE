import CryptoKit
import DanteCore
import Foundation

/// Dante's models as the companion sees them.
extension CompanionSnapshot.Project {
    /// A stable id for a project folder that doesn't send its path.
    public static func id(for root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        return Data(digest).base64URL.prefix(12).description
    }
}

extension CompanionSnapshot.Job {
    public init(_ record: JobRecord, phase: JobPhase, lastReply: String, now: Date = Date()) {
        let state: State = switch phase {
        case .starting: .starting
        case .working: .working
        case .waiting: .waiting
        case .asking: .asking
        case .ready: .ready
        case .paused: .paused
        case .failed: .failed
        case .merged: .merged
        case .discarded: .discarded
        }
        var label = phase.label
        if case .failed(let reason) = phase, !reason.isEmpty { label += ": \(reason)" }
        var away: String?
        if record.awayMinutes != nil {
            if let end = record.awayEnded(at: now) {
                away = "Away ended · \(end.sentence)"
            } else if let until = record.awayUntil {
                away = "Away · \(max(1, Int(until.timeIntervalSince(now) / 60))) min left"
            } else {
                away = "Away"
            }
        }
        self.init(id: record.id, title: record.title, state: state, label: label, lastReply: Self.trimmed(lastReply), away: away)
    }

    /// The end of a long reply is what matters on a phone.
    public static func trimmed(_ text: String, limit: Int = 1200) -> String {
        text.count > limit ? "…" + String(text.suffix(limit)) : text
    }
}

extension CompanionSnapshot.Approval {
    public init(_ item: JobInbox.Item) {
        let tool = item.tool
        let questions = ClarifyingQuestion.parse(tool.input).map {
            CompanionSnapshot.Question(question: $0.question, options: $0.options.map(\.label))
        }
        let detail: String
        if let change = tool.change {
            detail = change.lines.compactMap { line in
                switch line.kind {
                case .added: "+ " + line.text
                case .removed: "- " + line.text
                case .context: "  " + line.text
                case .gap: "  …"
                case .file: line.text
                }
            }.joined(separator: "\n")
        } else if let command = tool.input["command"]?.string {
            detail = command
        } else if let plan = tool.input["plan"]?.string {
            detail = plan
        } else {
            detail = ""
        }
        let notes = [tool.securityNote, tool.ruleNote].compactMap { $0 }
        self.init(id: item.id, job: item.job, from: item.from, title: ClaudeSession.attentionLabel(tool.name, input: tool.input),
                  detail: detail, questions: questions, note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }
}

extension TranscriptItem {
    /// The newest reply in a transcript, for the snapshot.
    public static func lastReply(in items: [TranscriptItem]) -> String {
        for item in items.reversed() {
            if case .assistant(let text) = item.content, !text.isEmpty { return text }
        }
        return ""
    }
}
