import Foundation

// What the Mac's voice and the phone's voice share: the talk key, replies made fit to say
// out loud, and speaking them as they stream. Moved from DanteKit for the companion app.

/// A held talk key, including permission/startup and the final recognition after release.
/// Tickets prevent a quick tap's late permission callback from opening the microphone.
public struct PushToTalk: Sendable {
    public enum Phase: Sendable { case idle, starting, listening, finishing }
    public private(set) var phase: Phase = .idle
    private var generation = 0

    public init() {}

    public mutating func press() -> Int? {
        guard phase == .idle else { return nil }
        generation += 1
        phase = .starting
        return generation
    }

    public func canStart(_ ticket: Int) -> Bool { phase == .starting && generation == ticket }

    @discardableResult
    public mutating func started(_ ticket: Int) -> Bool {
        guard canStart(ticket) else { return false }
        phase = .listening
        return true
    }

    /// True exactly once when a recording should finish; releasing during startup cancels it.
    public mutating func release() -> Bool {
        switch phase {
        case .starting: cancel(); return false
        case .listening: phase = .finishing; return true
        case .idle, .finishing: return false
        }
    }

    public mutating func cancel() {
        generation += 1
        phase = .idle
    }
}

/// Claude's reply as something to say out loud: no code, no markdown, the first few sentences.
public enum SpokenReply {
    public static let length = 320
    public static let conversationInstructions = """
    This is a spoken conversation. Lead with a short, direct answer in natural sentences.
    Speak like the user's personal assistant: explain the purpose, result and next step in
    everyday English. Say "I'll check the project files", not "I'll run cat or rg".
    Never read shell commands, tool names, flags, paths or implementation mechanics aloud;
    leave those details on screen. Use your judgement for routine implementation choices.
    Ask a question only when a missing answer materially changes the outcome or when an
    actual permission is required. Don't ask whether to continue work already requested.
    Keep ordinary replies to one or two sentences, then let the user follow up. For work
    that needs investigation, briefly say what you are checking and carry out the requested
    work. Put code, long lists and detailed evidence on screen; keep the spoken explanation
    concise. These instructions apply to this voice turn.
    """

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
        let text = MarkdownText.plain(lines.joined(separator: " "))
        // Paths and long identifiers read badly; say the file name instead.
        return text.split(separator: " ").map { word in
            word.contains("/") && word.count > 12 ? Substring((word as NSString).lastPathComponent) : word
        }.joined(separator: " ")
    }

    public static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty { result.append(sentence) }
        }
        return result
    }

    /// Describes the purpose of a command without reading syntax into someone's ear.
    /// Compound or unfamiliar commands stay general rather than claiming they're reads.
    public static func action(forCommand command: String) -> String {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ![";", "|", "&", ">", "<", "$(", "`", "\n"].contains(where: command.contains) else { return "run a project command" }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let program = words.first else { return "carry out the next step" }
        let executable = (program as NSString).lastPathComponent
        if ["cat", "head", "tail", "less"].contains(executable) { return "read a project file" }
        if ["rg", "grep", "find"].contains(executable) { return "search the project" }
        if ["ls", "pwd", "stat"].contains(executable) { return "check the project files" }
        if ["rm", "rmdir"].contains(executable) { return "delete files" }
        if executable == "git" {
            switch words.dropFirst().first {
            case "status", "diff", "log", "show": return "review the project changes"
            case "push": return "send commits to the remote repository"
            case "commit": return "save a commit"
            default: return "run a version-control command"
            }
        }
        if ["swift", "npm", "pnpm", "yarn", "cargo", "go", "make", "pytest", "xcodebuild"].contains(executable) {
            if executable == "pytest" || words.contains("test") { return "run the tests" }
            if words.contains("build") { return "build the app" }
            if words.contains("lint") { return "check the code" }
        }
        return "run a project command"
    }
}

/// Claude's reply spoken as it streams: each sentence once it's complete, up to a limit, then
/// a pointer to the screen. Feed it the reply's text so far each time it grows.
public struct SpokenStream: Sendable {
    public static let more = "There’s more on screen."

    public var limit: Int
    private var spokenSentences = 0
    private var spokenCharacters = 0
    public private(set) var isCut = false

    public init(limit: Int = 700) {
        self.limit = limit
    }

    /// A quiet stream can release its last sentence after a brief stability check, without
    /// waiting for the next sentence or the end of the agent's turn.
    public mutating func feed(_ markdown: String, final: Bool, settled: Bool = false) -> [String] {
        guard !isCut else { return [] }
        let sentences = SpokenReply.sentences(SpokenReply.plain(markdown))
        let complete = settled && sentences.last.map(Self.endsSentence) == true
        let ready = final || complete ? sentences : Array(sentences.dropLast())
        guard ready.count > spokenSentences else { return [] }
        var result: [String] = []
        for sentence in ready[spokenSentences...] {
            spokenSentences += 1
            if spokenCharacters > 0, spokenCharacters + sentence.count > limit {
                isCut = true
                result.append(Self.more)
                break
            }
            spokenCharacters += sentence.count
            result.append(sentence)
        }
        return result
    }

    private static func endsSentence(_ text: String) -> Bool {
        let end = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”’)]}")))
        guard let last = end.last else { return false }
        if last == "!" || last == "?" { return true }
        guard last == ".", !end.hasSuffix("..") else { return false }
        let word = end.split(separator: " ").last.map(String.init) ?? ""
        // Don't commit a title, initial, decimal or version while its continuation is coming.
        let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "e.g.", "i.e.", "vs.", "etc."]
        if abbreviations.contains(word.lowercased()) { return false }
        if word.dropLast().last?.isNumber == true { return false }
        return word.range(of: #"^(?:[A-Za-z]\.)+$"#, options: .regularExpression) == nil
    }
}

/// Sentences waiting to be spoken, handed to the synthesiser in chunks. Each utterance is
/// synthesised on its own and starts its intonation afresh, so one per sentence sounds choppy;
/// but waiting for the whole reply is slow. The first sentence goes straight away, and
/// bounded chunks are prepared behind whatever is playing, up to the caller's capacity.
public struct SpeechQueue: Sendable {
    /// Keep synthesis work short enough to prepare while the previous chunk is playing.
    public static let chunkLimit = 180
    private var pending: [String] = []

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    public mutating func add(_ sentence: String) {
        var chunk = ""
        for word in sentence.split(whereSeparator: { $0.isWhitespace }) {
            if !chunk.isEmpty, chunk.count + 1 + word.count > Self.chunkLimit {
                pending.append(chunk)
                chunk = ""
            }
            chunk += (chunk.isEmpty ? "" : " ") + word
        }
        if !chunk.isEmpty { pending.append(chunk) }
    }

    /// The next chunk to hand over, when there's room for one beside the `outstanding`
    /// utterances (handed over and not yet finished).
    public mutating func next(outstanding: Int, capacity: Int = 2) -> String? {
        guard outstanding < capacity, !pending.isEmpty else { return nil }
        var chunk = pending.removeFirst()
        while let next = pending.first, chunk.count + 1 + next.count <= Self.chunkLimit {
            chunk += " " + pending.removeFirst()
        }
        return chunk
    }

    public mutating func reset() {
        pending.removeAll()
    }
}

/// Markdown as plain text: images dropped, links' text kept, tags and emphasis removed.
public enum MarkdownText {
    private static let images = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]*\)"#)
    private static let links = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)
    private static let tags = try! NSRegularExpression(pattern: #"</?[A-Za-z][^>]*>"#)
    private static let emphasis = try! NSRegularExpression(pattern: #"(\*\*|__|\*|`|~~)"#)
    private static let spaces = try! NSRegularExpression(pattern: #"\s+"#)

    public static func plain(_ text: String) -> String {
        var result = text
        for (pattern, template) in [(images, ""), (links, "$1"), (tags, ""), (emphasis, ""), (spaces, " ")] {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
