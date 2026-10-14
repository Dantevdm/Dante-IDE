import Foundation

/// Earlier conversations in this project, read back from Claude Code's own transcripts in
/// `~/.claude/projects/<encoded path>`, so one can be shown again and continued.
public enum ClaudeHistory {
    public struct Conversation: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var detail: String
        public var date: Date
    }

    /// Conversations newest first, leaving out one-prompt quick runs (commit messages and
    /// the like) unless they're all there is.
    public static func conversations(for root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser, limit: Int = 40) -> [Conversation] {
        let events = ClaudeTranscripts.sessions(in: ClaudeTranscripts.folder(for: root, home: home), limit: limit * 2)
        let kept = events.filter { !$0.isQuick }
        return (kept.isEmpty ? events : kept).prefix(limit).compactMap { event in
            guard let id = event.reference else { return nil }
            return Conversation(id: id, title: cleaned(event.title), detail: event.detail ?? "", date: event.date)
        }
    }

    public static func transcriptURL(for id: String, root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        ClaudeTranscripts.folder(for: root, home: home).appending(path: "\(id).jsonl")
    }

    /// Dante adds what's on screen to each message inside <dante-context>; the person
    /// didn't type it.
    static func cleaned(_ text: String) -> String {
        guard let range = text.range(of: "<dante-context>") else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The transcript as panel items: what the person typed, Claude's replies, and the tools
    /// it used with how each ended. Subagent and system lines are left out.
    public static func items(fromTranscript text: String) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var toolIndex: [String: Int] = [:]
        var textBlocks: [String: Int] = [:]
        var lines: [String] = []
        // Only user and assistant lines are parsed; progress and snapshot lines are most of a
        // long transcript (see `TranscriptScan`).
        TranscriptScan.lines(text) { line in
            let type = TranscriptScan.topLevelType(line)
            if type == "user" || type == "assistant" { lines.append(TranscriptScan.text(line)) }
        }
        for line in lines {
            guard let json = JSONValue(line: line), json["isSidechain"]?.bool != true, json["isMeta"]?.bool != true else { continue }
            let message = json["message"]
            switch json["type"]?.string {
            case "user":
                if let content = message?["content"]?.string {
                    let typed = cleaned(content)
                    guard !typed.isEmpty, !typed.hasPrefix("<") else { continue }
                    items.append(TranscriptItem(id: "user-\(json["uuid"]?.string ?? UUID().uuidString)", content: .user(typed)))
                    continue
                }
                var typed: [String] = []
                var attachments: [String] = []
                for block in message?["content"]?.array ?? [] {
                    switch block["type"]?.string {
                    case "tool_result":
                        guard let id = block["tool_use_id"]?.string, let position = toolIndex[id],
                              case .tool(var tool) = items[position].content else { continue }
                        let failed = block["is_error"]?.bool == true
                        let text = block["content"]?.string ?? (block["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
                        tool.status = failed ? (text.contains("declined") || text.contains("denied") ? .declined : .failed(text)) : .done
                        items[position].content = .tool(tool)
                    case "text":
                        if let text = block["text"]?.string { typed.append(cleaned(text)) }
                    case "image": attachments.append("image")
                    case "document": attachments.append(block["title"]?.string ?? "document")
                    default: break
                    }
                }
                let joined = typed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if (!joined.isEmpty && !joined.hasPrefix("<")) || !attachments.isEmpty {
                    items.append(TranscriptItem(id: "user-\(json["uuid"]?.string ?? UUID().uuidString)", content: .user(joined, attachments: attachments)))
                }
            case "assistant":
                let messageID = message?["id"]?.string ?? UUID().uuidString
                for block in message?["content"]?.array ?? [] {
                    switch block["type"]?.string {
                    case "text":
                        guard let text = block["text"]?.string, !text.isEmpty else { continue }
                        let count = textBlocks[messageID, default: 0]
                        textBlocks[messageID] = count + 1
                        items.append(TranscriptItem(id: "\(messageID)-t\(count)", content: .assistant(text)))
                    case "tool_use":
                        guard let id = block["id"]?.string, toolIndex[id] == nil else { continue }
                        toolIndex[id] = items.count
                        items.append(TranscriptItem(id: id, content: .tool(ToolActivity(id: id, name: block["name"]?.string ?? "", input: block["input"] ?? [:], status: .done))))
                    default: break
                    }
                }
            default:
                continue
            }
        }
        return items
    }
}
