import Foundation

/// What a spoken line asks for: a few commands Dante handles itself, else a message for Claude.
public enum VoiceCommand: Equatable, Sendable {
    /// Stop whatever Claude is doing.
    case stop
    /// Bring a project's window forward (by its name as spoken).
    case show(project: String)
    /// Approve or turn down what's waiting.
    case approve, decline
    /// Said by mistake: do nothing.
    case cancel
    /// Open the Stage (full screen) or leave it.
    case stage(Bool)
    case ask(String)

    /// `projects` are the open projects' names, matched loosely ("dante ide" finds "Dante IDE").
    public static func parse(_ utterance: String, projects: [String]) -> VoiceCommand {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lower = text.lowercased().filter { !",.!?;:".contains($0) }.replacingOccurrences(of: "’", with: "'")
        guard !lower.isEmpty else { return .cancel }
        if ["stop", "stop it", "stop that", "cancel that", "hold on", "wait"].contains(lower) { return .stop }
        if ["never mind", "nevermind", "forget it", "nothing"].contains(lower) { return .cancel }
        if ["yes", "yes do it", "do it", "approve", "approve it", "go ahead", "apply it", "apply them", "yes please"].contains(lower) { return .approve }
        if ["no", "don't", "dont", "decline", "no thanks", "don't do that"].contains(lower) { return .decline }
        let spoken = lower.replacingOccurrences(of: "the ", with: "").replacingOccurrences(of: "please", with: "").trimmingCharacters(in: .whitespaces)
        if stageOpeners.contains(spoken) { return .stage(true) }
        if stageClosers.contains(spoken) { return .stage(false) }
        for prefix in ["show me ", "switch to ", "open ", "go to "] where lower.hasPrefix(prefix) {
            let name = String(lower.dropFirst(prefix.count)).replacingOccurrences(of: "the ", with: "")
            if let project = projects.first(where: { matches($0, name) }) { return .show(project: project) }
        }
        return .ask(text)
    }

    static let stageOpeners: Set<String> = [
        "stage", "open stage", "show stage", "go full screen", "full screen", "fullscreen", "big screen",
        "jarvis", "hey jarvis", "show me everything", "take over", "on tv", "go big",
    ]
    static let stageClosers: Set<String> = [
        "minimise", "minimize", "minimise it", "minimize it", "close", "close it", "close stage", "exit",
        "exit full screen", "leave", "go back", "back", "dismiss", "hide", "hide it", "small", "shrink",
        "that's all", "thats all", "exit stage", "leave stage", "done here",
    ]

    static func matches(_ project: String, _ spoken: String) -> Bool {
        let squash = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let (a, b) = (squash(project), squash(spoken.replacingOccurrences(of: " project", with: "")))
        return !b.isEmpty && (a == b || a.hasPrefix(b) || b.hasPrefix(a))
    }
}

/// Claude's reply as something to say out loud: no code, no markdown, the first few sentences.
public enum SpokenReply {
    public static let length = 320

    public static func text(from markdown: String) -> String {
        let text = plain(markdown)
        guard text.count > length else { return text }
        var result = ""
        for sentence in sentences(text) {
            if !result.isEmpty, result.count + sentence.count > length { break }
            result += (result.isEmpty ? "" : " ") + sentence
        }
        return result.isEmpty ? String(text.prefix(length)) : result
    }

    /// The reply without code blocks, tables, markdown or long paths.
    public static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        var fence = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fence.toggle(); continue }
            if fence || line.hasPrefix("|") || line.hasPrefix("---") { continue }
            var cleaned = line
            while let first = cleaned.first, "#>-*•".contains(first) { cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if !cleaned.isEmpty { lines.append(cleaned) }
        }
        let text = DocExcerpt.plain(lines.joined(separator: " "))
        // Paths and long identifiers read badly; say the file name instead.
        return text.split(separator: " ").map { word in
            word.contains("/") && word.count > 12 ? Substring((word as NSString).lastPathComponent) : word
        }.joined(separator: " ")
    }

    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty { result.append(sentence) }
        }
        return result
    }
}
