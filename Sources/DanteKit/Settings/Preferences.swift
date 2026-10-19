import Foundation
import Observation

/// The app's settings, remembered per Mac in user defaults. Theme and font size live in the
/// app's `ThemeStore`; everything else the Settings window shows is here.
@MainActor
@Observable
public final class Preferences {
    public static let shared = Preferences()

    public enum AutoSave: String, CaseIterable, Sendable {
        case off, afterDelay, onFocusChange

        public var label: String {
            switch self {
            case .off: "Off"
            case .afterDelay: "After a short delay"
            case .onFocusChange: "When Dante loses focus"
            }
        }
    }

    /// Claude Code's model aliases; `default` leaves the choice to Claude Code.
    public enum ClaudeModel: String, CaseIterable, Sendable {
        case `default`, opus, sonnet, haiku

        public var label: String {
            switch self {
            case .default: "Claude Code’s default"
            case .opus: "Opus"
            case .sonnet: "Sonnet"
            case .haiku: "Haiku"
            }
        }

        /// The `--model` value, or nil to pass none.
        public var argument: String? { self == .default ? nil : rawValue }
    }

    private let defaults: UserDefaults

    /// Spaces per indent level; 0 means the language's usual width.
    public var indentWidth: Int { didSet { defaults.set(indentWidth, forKey: Keys.indentWidth) } }
    public var wrapsLines: Bool { didSet { defaults.set(wrapsLines, forKey: Keys.wrapsLines) } }
    public var completesWhileTyping: Bool { didSet { defaults.set(completesWhileTyping, forKey: Keys.completesWhileTyping) } }
    public var formatsOnSave: Bool { didSet { defaults.set(formatsOnSave, forKey: Keys.formatsOnSave) } }
    public var trimsTrailingWhitespace: Bool { didSet { defaults.set(trimsTrailingWhitespace, forKey: Keys.trimsTrailingWhitespace) } }
    public var insertsFinalNewline: Bool { didSet { defaults.set(insertsFinalNewline, forKey: Keys.insertsFinalNewline) } }
    public var autoSave: AutoSave { didSet { defaults.set(autoSave.rawValue, forKey: Keys.autoSave) } }
    public var claudeAsksFirst: Bool { didSet { defaults.set(claudeAsksFirst, forKey: Keys.claudeAsksFirst) } }
    public var claudeModel: ClaudeModel { didSet { defaults.set(claudeModel.rawValue, forKey: Keys.claudeModel) } }
    /// Let Claude hand small jobs to models in Ollama on this Mac (the `delegate` tool).
    public var delegatesToLocalModels: Bool { didSet { defaults.set(delegatesToLocalModels, forKey: Keys.delegatesToLocalModels) } }
    /// After a spoken reply, listen for a follow-up without the talk key.
    public var keepsConversation: Bool { didSet { defaults.set(keepsConversation, forKey: Keys.keepsConversation) } }
    /// Listen for "Hey Dante" while Dante is open (recognised on this Mac). Off until asked for.
    public var listensForWakeWord: Bool { didSet { defaults.set(listensForWakeWord, forKey: Keys.listensForWakeWord) } }
    /// The voice replies are read in (an `AVSpeechSynthesisVoice` identifier); empty picks the best English one.
    public var voiceIdentifier: String { didSet { defaults.set(voiceIdentifier, forKey: Keys.voiceIdentifier) } }
    /// The microphone Dante listens with (a Core Audio device UID); empty picks one that
    /// doesn't drop a Bluetooth headset into its low-quality call mode.
    public var microphone: String { didSet { defaults.set(microphone, forKey: Keys.microphone) } }
    /// How fast replies are read, 0.4 (slow) … 0.62 (fast).
    public var speechRate: Double { didSet { defaults.set(speechRate, forKey: Keys.speechRate) } }
    /// Let Claude ask OpenAI's Codex (when installed) for second opinions.
    public var asksCodex: Bool { didSet { defaults.set(asksCodex, forKey: Keys.asksCodex) } }
    /// The model Codex uses; empty for Codex's default.
    public var codexModel: String { didSet { defaults.set(codexModel, forKey: Keys.codexModel) } }
    /// How hard Codex thinks (its reasoning effort); empty for the model's default.
    public var codexEffort: String { didSet { defaults.set(codexEffort, forKey: Keys.codexEffort) } }
    /// Who new windows' conversations start with: Claude or Codex.
    public var agentEngine: AgentEngine { didSet { defaults.set(agentEngine.rawValue, forKey: Keys.agentEngine) } }
    /// Ask OSV.dev about the project's dependencies when scanning (sends package names and versions).
    public var checksDependenciesOnline: Bool { didSet { defaults.set(checksDependenciesOnline, forKey: Keys.checksDependenciesOnline) } }
    /// The Grok model `ask_grok` uses; empty picks the best the key has.
    public var grokModel: String { didSet { defaults.set(grokModel, forKey: Keys.grokModel) } }
    /// Looker's vision model; empty for the best installed.
    public var lookerModel: String { didSet { defaults.set(lookerModel, forKey: Keys.lookerModel) } }
    /// How much Claude may do without asking.
    public var approvalLevel: ApprovalLevel { didSet { defaults.set(approvalLevel.rawValue, forKey: Keys.approvalLevel) } }
    /// Read Claude's replies out after you speak to it.
    public var speaksReplies: Bool { didSet { defaults.set(speaksReplies, forKey: Keys.speaksReplies) } }
    /// Geist and Geist Mono, as in the design; off uses the system fonts.
    public var usesGeist: Bool { didSet { defaults.set(usesGeist, forKey: Keys.usesGeist) } }
    /// A macOS notification when a monitoring alarm starts firing. Off until asked for.
    public var notifiesOnAlarms: Bool { didSet { defaults.set(notifiesOnAlarms, forKey: Keys.notifiesOnAlarms) } }
    /// A notification when Claude finishes or waits for approval while Dante isn't in front.
    public var notifiesOnClaude: Bool { didSet { defaults.set(notifiesOnClaude, forKey: Keys.notifiesOnClaude) } }
    /// The orb in the menu bar that shows what Claude is doing.
    public var showsPresence: Bool { didSet { defaults.set(showsPresence, forKey: Keys.showsPresence) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        indentWidth = defaults.integer(forKey: Keys.indentWidth)
        wrapsLines = bool(Keys.wrapsLines, false)
        completesWhileTyping = bool(Keys.completesWhileTyping, true)
        formatsOnSave = bool(Keys.formatsOnSave, false)
        trimsTrailingWhitespace = bool(Keys.trimsTrailingWhitespace, false)
        insertsFinalNewline = bool(Keys.insertsFinalNewline, false)
        autoSave = defaults.string(forKey: Keys.autoSave).flatMap(AutoSave.init(rawValue:)) ?? .off
        claudeAsksFirst = bool(Keys.claudeAsksFirst, true)
        delegatesToLocalModels = bool(Keys.delegatesToLocalModels, true)
        speaksReplies = bool(Keys.speaksReplies, true)
        grokModel = defaults.string(forKey: Keys.grokModel) ?? ""
        lookerModel = defaults.string(forKey: Keys.lookerModel) ?? ""
        asksCodex = bool(Keys.asksCodex, true)
        codexModel = defaults.string(forKey: Keys.codexModel) ?? ""
        codexEffort = defaults.string(forKey: Keys.codexEffort) ?? ""
        agentEngine = defaults.string(forKey: Keys.agentEngine).flatMap(AgentEngine.init(rawValue:)) ?? .claude
        checksDependenciesOnline = bool(Keys.checksDependenciesOnline, false)
        keepsConversation = bool(Keys.keepsConversation, true)
        listensForWakeWord = bool(Keys.listensForWakeWord, false)
        voiceIdentifier = defaults.string(forKey: Keys.voiceIdentifier) ?? ""
        speechRate = defaults.object(forKey: Keys.speechRate) as? Double ?? 0.52
        microphone = defaults.string(forKey: Keys.microphone) ?? ""
        approvalLevel = defaults.string(forKey: Keys.approvalLevel).flatMap(ApprovalLevel.init(rawValue:)) ?? .ask
        claudeModel = defaults.string(forKey: Keys.claudeModel).flatMap(ClaudeModel.init(rawValue:)) ?? .default
        usesGeist = bool(Keys.usesGeist, true)
        notifiesOnAlarms = bool(Keys.notifiesOnAlarms, false)
        notifiesOnClaude = bool(Keys.notifiesOnClaude, false)
        showsPresence = bool(Keys.showsPresence, true)
    }

    /// The indent width for a file: the chosen one, or the language's usual one.
    public func indentWidth(for language: Language) -> Int {
        indentWidth > 0 ? indentWidth : Self.usualIndentWidth(for: language)
    }

    public nonisolated static func usualIndentWidth(for language: Language) -> Int {
        switch language {
        case .python, .swift, .java, .kotlin, .csharp, .rust, .php: 4
        default: 2
        }
    }

    /// The text to write when saving, after the chosen whitespace tidying. Markdown keeps
    /// trailing spaces, since two of them are a line break there.
    public func tidied(_ text: String, language: Language) -> String {
        SaveTidy.apply(to: text, trimTrailingWhitespace: trimsTrailingWhitespace && language != .markdown, finalNewline: insertsFinalNewline)
    }

    enum Keys {
        static let indentWidth = "indentWidth"
        static let wrapsLines = "wrapsLines"
        static let completesWhileTyping = "completesWhileTyping"
        static let formatsOnSave = "formatsOnSave"
        static let trimsTrailingWhitespace = "trimsTrailingWhitespace"
        static let insertsFinalNewline = "insertsFinalNewline"
        static let autoSave = "autoSave"
        static let claudeAsksFirst = "claudeAsksFirst"
        static let delegatesToLocalModels = "delegatesToLocalModels"
        static let speaksReplies = "speaksReplies"
        static let grokModel = "grokModel"
        static let lookerModel = "lookerModel"
        static let asksCodex = "asksCodex"
        static let codexModel = "codexModel"
        static let codexEffort = "codexEffort"
        static let agentEngine = "agentEngine"
        static let checksDependenciesOnline = "checksDependenciesOnline"
        static let keepsConversation = "keepsConversation"
        static let listensForWakeWord = "listensForWakeWord"
        static let voiceIdentifier = "voiceIdentifier"
        static let speechRate = "speechRate"
        static let microphone = "microphone"
        static let approvalLevel = "approvalLevel"
        static let claudeModel = "claudeModel"
        static let usesGeist = "usesGeist"
        static let notifiesOnAlarms = "notifiesOnAlarms"
        static let notifiesOnClaude = "notifiesOnClaude"
        static let showsPresence = "showsPresence"
    }
}

/// Whitespace tidying on save.
public enum SaveTidy {
    public static func apply(to text: String, trimTrailingWhitespace: Bool, finalNewline: Bool) -> String {
        var result = text
        if trimTrailingWhitespace {
            result = result.components(separatedBy: "\n").map { line in
                var line = Substring(line)
                let carriageReturn = line.hasSuffix("\r")
                if carriageReturn { line = line.dropLast() }
                while let last = line.last, last == " " || last == "\t" { line = line.dropLast() }
                return String(line) + (carriageReturn ? "\r" : "")
            }.joined(separator: "\n")
        }
        if finalNewline, !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return result
    }
}
