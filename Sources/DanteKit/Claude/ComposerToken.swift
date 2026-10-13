import Foundation

/// What the person is typing at the end of the Claude message box: an `@file` mention
/// or a `/command`, so the composer can offer a list to pick from.
public struct ComposerToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case mention, command }

    public var kind: Kind
    /// The text after `@` or `/`.
    public var query: String
    /// Where the token starts in the draft (at the `@` or `/`).
    public var start: String.Index

    /// The token the draft ends with. A command only at the very start of the message.
    public static func current(in draft: String) -> ComposerToken? {
        if draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) {
            return ComposerToken(kind: .command, query: String(draft.dropFirst()), start: draft.startIndex)
        }
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let query = draft[draft.index(after: at)...]
        guard !query.contains(where: \.isWhitespace) else { return nil }
        // "me@example.com" isn't a mention: the @ has to start a word.
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        return ComposerToken(kind: .mention, query: String(query), start: at)
    }

    /// The draft with the token replaced by `replacement` and a space after it.
    public func replacing(in draft: String, with replacement: String) -> String {
        String(draft[..<start]) + replacement + " "
    }

    /// Project files mentioned as `@path` in a message, in order, without repeats.
    public static func mentions(in text: String, files: Set<String>) -> [String] {
        var found: [String] = []
        for word in text.split(whereSeparator: \.isWhitespace) where word.hasPrefix("@") {
            let path = String(word.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)\"'"))
            if files.contains(path), !found.contains(path) { found.append(path) }
        }
        return found
    }
}

/// A `/` command in the Claude message box.
public struct ComposerCommand: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case compact
        case newConversation
        case context
        case history
        case skills
        /// Starts a message that asks Claude to use a skill.
        case skill(String)
    }

    public var name: String
    public var detail: String
    public var action: Action
    public var id: String { name }

    public static let builtIn: [ComposerCommand] = [
        ComposerCommand(name: "compact", detail: "Summarise the conversation to free up context", action: .compact),
        ComposerCommand(name: "new", detail: "Start a new conversation", action: .newConversation),
        ComposerCommand(name: "context", detail: "What's using the context window", action: .context),
        ComposerCommand(name: "history", detail: "Earlier conversations", action: .history),
        ComposerCommand(name: "skills", detail: "Skills, memory and connectors in the Claude area", action: .skills),
    ]

    /// Built-in commands and one per skill, filtered by what's been typed: prefix matches first.
    public static func matching(_ query: String, skills: [ClaudeSkill]) -> [ComposerCommand] {
        let all = builtIn + skills.map { ComposerCommand(name: $0.name, detail: $0.description.isEmpty ? "Skill" : $0.description, action: .skill($0.name)) }
        let lower = query.lowercased()
        guard !lower.isEmpty else { return all }
        let prefixed = all.filter { $0.name.lowercased().hasPrefix(lower) }
        let containing = all.filter { !$0.name.lowercased().hasPrefix(lower) && $0.name.lowercased().contains(lower) }
        return prefixed + containing
    }
}
