import Foundation

/// What a spoken line asks for: a few commands Dante handles itself, else a message for Claude.
public enum VoiceCommand: Equatable, Sendable {
    /// Stop whatever Claude is doing.
    case stop
    /// Bring a project's window forward, or open a recent one (by its name as spoken).
    case show(project: String)
    /// Open some project: Dante asks which.
    case openProject
    /// Approve or turn down what's waiting.
    case approve, decline
    /// Said by mistake: do nothing.
    case cancel
    /// Open the Stage (full screen) or leave it.
    case stage(Bool)
    /// What Claude is doing, answered by Dante without a turn.
    case status
    /// How much of the usage window is left.
    case usage
    /// Ends a spoken conversation.
    case goodbye
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
        if let stage = fullScreen(spoken) { return .stage(stage) }
        let core = Self.core(spoken)
        if goodbyes.contains(core) { return .goodbye }
        if statusQuestions.contains(core) { return .status }
        if usageQuestions.contains(core) { return .usage }
        // Only the greeting comes off here: "switch to dante" names a project.
        var greeted = spoken.split(separator: " ").map(String.init)
        while let first = greeted.first, ["hey", "ok", "okay", "claude", "dante", "jarvis", "so"].contains(first) { greeted.removeFirst() }
        let request = greeted.joined(separator: " ")
        for prefix in ["show me ", "switch to ", "open up ", "open ", "go to ", "bring up "] where request.hasPrefix(prefix) {
            let name = String(request.dropFirst(prefix.count)).replacingOccurrences(of: "the ", with: "")
            if let project = projects.first(where: { matches($0, name) }) { return .show(project: project) }
        }
        if asksToOpenAProject(core) { return .openProject }
        return .ask(text)
    }

    /// "Open up in full screen", "can you go full screen": any short line about full screen.
    static func fullScreen(_ spoken: String) -> Bool? {
        let words = spoken.split(separator: " ")
        let text = " " + spoken.replacingOccurrences(of: "fullscreen", with: "full screen") + " "
        guard words.count <= 8, text.contains(" full screen ") || text.contains(" big screen ") else { return nil }
        let leaving = [" exit", " leave", " close", " out of ", " minimi", " stop", " turn off", " no more", " not "]
        return !leaving.contains { text.contains($0) }
    }

    /// "Open a new project", "are you able to open another project?", "open a project".
    static func asksToOpenAProject(_ core: String) -> Bool {
        let text = " " + core + " "
        guard text.contains(" open ") || text.contains(" start ") || text.contains(" switch ") else { return false }
        return [" a project", " new project", " another project", " other project", " different project", " some project", " a folder", " another folder"]
            .contains { text.contains($0) }
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

    static let goodbyes: Set<String> = [
        "thanks", "thank you", "thanks a lot", "cheers", "bye", "goodbye", "good bye", "that's it", "thats it",
        "that's everything", "thats everything", "nothing else", "all good", "we're done", "were done", "i'm done", "im done",
    ]
    static let statusQuestions: Set<String> = [
        "status", "what's the status", "whats the status", "what are you doing", "what are you up to", "what's happening",
        "whats happening", "what's going on", "whats going on", "how's it going", "hows it going", "progress", "where are we",
        "update", "give me an update", "any update", "are you done", "is it done", "what's left", "whats left",
    ]
    static let usageQuestions: Set<String> = [
        "usage", "how much usage", "how much usage is left", "how much usage do i have", "how much usage do i have left",
        "how much is left", "how much have i got left", "how much do i have left", "limits", "my limits", "how are my limits",
        "am i near the limit", "am i close to the limit", "how much claude is left", "how much claude do i have left",
    ]

    /// A line without the names it's addressed to: "hey claude what are you doing" → "what are you doing".
    static func core(_ spoken: String) -> String {
        var words = spoken.split(separator: " ").map(String.init)
        let names: Set<String> = ["hey", "ok", "okay", "claude", "dante", "jarvis", "so"]
        while let first = words.first, names.contains(first) { words.removeFirst() }
        while let last = words.last, names.contains(last) || last == "now" { words.removeLast() }
        return words.joined(separator: " ")
    }

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

    /// The sentences ready to say since the last call. Until `final`, the last sentence may
    /// still be growing, so it waits.
    public mutating func feed(_ markdown: String, final: Bool) -> [String] {
        guard !isCut else { return [] }
        let sentences = SpokenReply.sentences(SpokenReply.plain(markdown))
        let ready = final ? sentences : Array(sentences.dropLast())
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
}

/// Sentences waiting to be spoken, handed to the synthesiser in chunks. Each utterance is
/// synthesised on its own and starts its intonation afresh, so one per sentence sounds choppy;
/// but waiting for the whole reply is slow. The first sentence goes straight away, one more
/// waits behind whatever is playing, and the rest gather into the next chunk meanwhile.
public struct SpeechQueue: Sendable {
    private var pending: [String] = []

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    public mutating func add(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { pending.append(trimmed) }
    }

    /// The next chunk to hand over, when there's room for one beside the `outstanding`
    /// utterances (handed over and not yet finished).
    public mutating func next(outstanding: Int) -> String? {
        guard outstanding < 2, !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return pending.joined(separator: " ")
    }

    public mutating func reset() {
        pending.removeAll()
    }
}

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

/// Spoken answers Dante gives itself, without asking Claude.
public enum VoiceStatus {
    /// What Claude is up to across the open projects, most urgent first.
    public static func summary(_ sources: [PresenceSource]) -> String {
        guard !sources.isEmpty else { return "No projects are open." }
        var lines: [String] = []
        for source in sources where source.waiting > 0 {
            lines.append("\(source.project) needs you: \(source.waiting == 1 ? "one thing is" : "\(source.waiting) things are") waiting.")
        }
        for source in sources where source.waiting == 0 && source.claude == .working {
            lines.append(source.running.map { "In \(source.project), Claude is \(gerund($0))." } ?? "In \(source.project), Claude is thinking.")
        }
        for source in sources {
            if case .unavailable(let reason) = source.claude { lines.append("Claude can’t run in \(source.project): \(reason)") }
        }
        let free = sources.filter { $0.waiting == 0 && $0.claude == .idle }.map(\.project)
        if lines.isEmpty {
            return free.isEmpty ? "Nothing’s running." : "All quiet. Claude is free in \(list(free))."
        }
        return lines.prefix(3).joined(separator: " ")
    }

    /// The usage window, as well as Dante can estimate it.
    public static func usage(share: Double?, resets: Date?, limitReached: Bool, now: Date = Date(),
                             locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let at = resets.flatMap { $0 > now ? $0 : nil }.map { " It resets at \(time($0, locale: locale, timeZone: timeZone))." } ?? ""
        if limitReached { return "You’ve hit the limit.\(at)" }
        guard let share else { return "There’s no usage on record yet." }
        let percent = Int((share * 100).rounded())
        let feel = share < 0.5 ? "plenty left" : share < 0.85 ? "a fair amount used" : "close to your busiest"
        return "This five-hour window is at about \(percent)% of your busiest one: \(feel).\(at)"
    }

    /// "Edit SystemMap.swift" → "editing SystemMap.swift".
    static func gerund(_ running: String) -> String {
        let verbs = ["Edit": "editing", "Read": "reading", "Write": "writing", "Run": "running", "Search": "searching",
                     "Find": "finding", "Fetch": "fetching", "List": "listing", "Ask": "asking", "Delegate": "delegating",
                     "Create": "creating", "Delete": "deleting", "Check": "checking", "Test": "testing"]
        let words = running.split(separator: " ", maxSplits: 1).map(String.init)
        if let first = words.first, let verb = verbs[first] { return ([verb] + words.dropFirst()).joined(separator: " ") }
        return "working: \(running)"
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    static func time(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
