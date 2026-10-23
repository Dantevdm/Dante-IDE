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
    /// Pick each request's effort, and answer self-contained prose locally (`TaskRouting`).
    public var automaticTaskRouting: Bool { didSet { defaults.set(automaticTaskRouting, forKey: Keys.automaticTaskRouting) } }
    /// Let Claude hand small jobs to models in Ollama on this Mac (the `delegate` tool).
    public var delegatesToLocalModels: Bool { didSet { defaults.set(delegatesToLocalModels, forKey: Keys.delegatesToLocalModels) } }
    /// After a spoken reply, listen for a follow-up without the talk key.
    public var keepsConversation: Bool { didSet { defaults.set(keepsConversation, forKey: Keys.keepsConversation) } }
    /// Listen for "Hey Dante" while Dante is open (recognised on this Mac). Off until asked for.
    public var listensForWakeWord: Bool { didSet { defaults.set(listensForWakeWord, forKey: Keys.listensForWakeWord) } }
    /// The voice replies are read in (an `AVSpeechSynthesisVoice` identifier); empty picks the best English one.
    public var voiceIdentifier: String { didSet { defaults.set(voiceIdentifier, forKey: Keys.voiceIdentifier) } }
    /// Speak with the natural voice (Kokoro, on this Mac) once it's set up; else Apple's.
    public var usesNaturalVoice: Bool { didSet { defaults.set(usesNaturalVoice, forKey: Keys.usesNaturalVoice) } }
    /// The natural voice's speaker (a Kokoro voice id such as `af_heart`).
    public var naturalVoice: String { didSet { defaults.set(naturalVoice, forKey: Keys.naturalVoice) } }
    /// The microphone Dante listens with (a Core Audio device UID); empty picks one that
    /// doesn't drop a Bluetooth headset into its low-quality call mode.
    public var microphone: String { didSet { defaults.set(microphone, forKey: Keys.microphone) } }
    /// How fast replies are read, 0.4 (slow) … 0.62 (fast).
    public var speechRate: Double { didSet { defaults.set(speechRate, forKey: Keys.speechRate) } }
    /// Let Claude ask OpenAI's Codex (when installed) for second opinions.
    public var asksCodex: Bool { didSet { defaults.set(asksCodex, forKey: Keys.asksCodex) } }
    /// Codex takes over a conversation when Claude's plan is nearly or fully used.
    public var switchesToCodexAtLimit: Bool { didSet { defaults.set(switchesToCodexAtLimit, forKey: Keys.switchesToCodexAtLimit) } }
    /// The model Codex uses; empty for Codex's default.
    public var codexModel: String { didSet { defaults.set(codexModel, forKey: Keys.codexModel) } }
    /// How hard Codex thinks (its reasoning effort); empty for the model's default.
    public var codexEffort: String { didSet { defaults.set(codexEffort, forKey: Keys.codexEffort) } }
    /// Each team role's model, by role id; a missing role uses its default.
    public var teamModels: [String: String] { didSet { defaults.set(teamModels, forKey: Keys.teamModels) } }
    /// Team roles switched off, by id.
    public var teamOff: [String] { didSet { defaults.set(teamOff, forKey: Keys.teamOff) } }
    /// The lead brings in the Documenter as decisions are made.
    public var documentsAsWeWork: Bool { didSet { defaults.set(documentsAsWeWork, forKey: Keys.documentsAsWeWork) } }
    /// Claude Code's `--effort` (low, medium, high); empty leaves it to Claude Code.
    public var claudeEffort: String { didSet { defaults.set(claudeEffort, forKey: Keys.claudeEffort) } }
    /// Who new windows' conversations start with: Claude or Codex.
    public var agentEngine: AgentEngine { didSet { defaults.set(agentEngine.rawValue, forKey: Keys.agentEngine) } }
    /// Ask OSV.dev about the project's dependencies when scanning (sends package names and versions).
    public var checksDependenciesOnline: Bool { didSet { defaults.set(checksDependenciesOnline, forKey: Keys.checksDependenciesOnline) } }
    /// The Grok model `ask_grok` uses; empty picks the best the key has.
    public var grokModel: String { didSet { defaults.set(grokModel, forKey: Keys.grokModel) } }
    /// Looker's vision model; empty for the best installed.
    public var lookerModel: String { didSet { defaults.set(lookerModel, forKey: Keys.lookerModel) } }
    /// The company standards library: a folder of standards docs and a `themes/` folder,
    /// shared by every project and kept outside every repo. Empty for none.
    public var standardsLibrary: String { didSet { defaults.set(standardsLibrary, forKey: Keys.standardsLibrary) } }
    /// The library in use: the folder chosen, else Dante's own (`Standards.ownLibrary`).
    public var standardsLibraryURL: URL? { standardsLibrary.isEmpty ? Standards.ownLibrary : URL(filePath: standardsLibrary, directoryHint: .isDirectory) }
    /// How much Claude may do without asking.
    public var approvalLevel: ApprovalLevel { didSet { defaults.set(approvalLevel.rawValue, forKey: Keys.approvalLevel) } }
    /// Read Claude's replies out after you speak to it.
    public var speaksReplies: Bool { didSet { defaults.set(speaksReplies, forKey: Keys.speaksReplies) } }
    /// Geist and Geist Mono, as in the design; off uses the system fonts.
    public var usesGeist: Bool { didSet { defaults.set(usesGeist, forKey: Keys.usesGeist) } }
    /// A macOS notification when a monitoring alarm starts firing. Off until asked for.
    public var notifiesOnAlarms: Bool { didSet { defaults.set(notifiesOnAlarms, forKey: Keys.notifiesOnAlarms) } }
    /// A notification when a pipeline run starts or finishes. Off until asked for.
    public var notifiesOnPipelines: Bool { didSet { defaults.set(notifiesOnPipelines, forKey: Keys.notifiesOnPipelines) } }
    /// Hands: the agent in charge may open apps, find folders and use the keyboard and mouse.
    public var handsEnabled: Bool { didSet { defaults.set(handsEnabled, forKey: Keys.handsEnabled) } }
    /// The agents' own browser (`BrowserTools`) for checking the app they build.
    public var agentsBrowse: Bool { didSet { defaults.set(agentsBrowse, forKey: Keys.agentsBrowse) } }
    /// The companion server for the iPhone and iPad app, on the tailnet. Off until asked for.
    public var companionEnabled: Bool { didSet { defaults.set(companionEnabled, forKey: Keys.companionEnabled) } }
    /// The morning update: the name it greets you by, whether it reads Outlook's mail and
    /// calendar (macOS asks once), and senders whose mail always counts (comma-separated).
    public var assistantName: String { didSet { defaults.set(assistantName, forKey: Keys.assistantName) } }
    public var briefingReadsMail: Bool { didSet { defaults.set(briefingReadsMail, forKey: Keys.briefingReadsMail) } }
    public var briefingReadsCalendar: Bool { didSet { defaults.set(briefingReadsCalendar, forKey: Keys.briefingReadsCalendar) } }
    public var briefingVIPs: String { didSet { defaults.set(briefingVIPs, forKey: Keys.briefingVIPs) } }
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
        automaticTaskRouting = bool(Keys.automaticTaskRouting, true)
        delegatesToLocalModels = bool(Keys.delegatesToLocalModels, true)
        speaksReplies = bool(Keys.speaksReplies, true)
        grokModel = defaults.string(forKey: Keys.grokModel) ?? ""
        lookerModel = defaults.string(forKey: Keys.lookerModel) ?? ""
        standardsLibrary = defaults.string(forKey: Keys.standardsLibrary) ?? ""
        asksCodex = bool(Keys.asksCodex, true)
        switchesToCodexAtLimit = bool(Keys.switchesToCodexAtLimit, true)
        codexModel = defaults.string(forKey: Keys.codexModel) ?? ""
        codexEffort = defaults.string(forKey: Keys.codexEffort) ?? ""
        claudeEffort = defaults.string(forKey: Keys.claudeEffort) ?? ""
        teamModels = defaults.dictionary(forKey: Keys.teamModels) as? [String: String] ?? [:]
        teamOff = defaults.stringArray(forKey: Keys.teamOff) ?? []
        documentsAsWeWork = defaults.object(forKey: Keys.documentsAsWeWork) as? Bool ?? true
        agentEngine = defaults.string(forKey: Keys.agentEngine).flatMap(AgentEngine.init(rawValue:)) ?? .claude
        checksDependenciesOnline = bool(Keys.checksDependenciesOnline, false)
        keepsConversation = bool(Keys.keepsConversation, true)
        listensForWakeWord = bool(Keys.listensForWakeWord, false)
        voiceIdentifier = defaults.string(forKey: Keys.voiceIdentifier) ?? ""
        speechRate = defaults.object(forKey: Keys.speechRate) as? Double ?? 0.52
        microphone = defaults.string(forKey: Keys.microphone) ?? ""
        usesNaturalVoice = bool(Keys.usesNaturalVoice, true)
        naturalVoice = defaults.string(forKey: Keys.naturalVoice) ?? NaturalVoice.defaultVoice
        approvalLevel = defaults.string(forKey: Keys.approvalLevel).flatMap(ApprovalLevel.init(rawValue:)) ?? .ask
        claudeModel = defaults.string(forKey: Keys.claudeModel).flatMap(ClaudeModel.init(rawValue:)) ?? .default
        usesGeist = bool(Keys.usesGeist, true)
        notifiesOnAlarms = bool(Keys.notifiesOnAlarms, false)
        notifiesOnClaude = bool(Keys.notifiesOnClaude, false)
        notifiesOnPipelines = bool(Keys.notifiesOnPipelines, false)
        companionEnabled = bool(Keys.companionEnabled, false)
        handsEnabled = bool(Keys.handsEnabled, false)
        assistantName = defaults.string(forKey: Keys.assistantName) ?? ""
        briefingReadsMail = bool(Keys.briefingReadsMail, false)
        briefingReadsCalendar = bool(Keys.briefingReadsCalendar, false)
        briefingVIPs = defaults.string(forKey: Keys.briefingVIPs) ?? ""
        agentsBrowse = bool(Keys.agentsBrowse, true)
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
        static let automaticTaskRouting = "automaticTaskRouting"
        static let delegatesToLocalModels = "delegatesToLocalModels"
        static let speaksReplies = "speaksReplies"
        static let grokModel = "grokModel"
        static let lookerModel = "lookerModel"
        static let standardsLibrary = "standardsLibrary"
        static let asksCodex = "asksCodex"
        static let switchesToCodexAtLimit = "switchesToCodexAtLimit"
        static let codexModel = "codexModel"
        static let codexEffort = "codexEffort"
        static let claudeEffort = "claudeEffort"
        static let teamModels = "teamModels"
        static let teamOff = "teamOff"
        static let documentsAsWeWork = "documentsAsWeWork"
        static let agentEngine = "agentEngine"
        static let checksDependenciesOnline = "checksDependenciesOnline"
        static let keepsConversation = "keepsConversation"
        static let listensForWakeWord = "listensForWakeWord"
        static let voiceIdentifier = "voiceIdentifier"
        static let speechRate = "speechRate"
        static let microphone = "microphone"
        static let usesNaturalVoice = "usesNaturalVoice"
        static let naturalVoice = "naturalVoice"
        static let approvalLevel = "approvalLevel"
        static let claudeModel = "claudeModel"
        static let usesGeist = "usesGeist"
        static let notifiesOnAlarms = "notifiesOnAlarms"
        static let notifiesOnClaude = "notifiesOnClaude"
        static let notifiesOnPipelines = "notifiesOnPipelines"
        static let companionEnabled = "companionEnabled"
        static let handsEnabled = "handsEnabled"
        static let assistantName = "assistantName"
        static let briefingReadsMail = "briefingReadsMail"
        static let briefingReadsCalendar = "briefingReadsCalendar"
        static let briefingVIPs = "briefingVIPs"
        static let agentsBrowse = "agentsBrowse"
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

extension Preferences {
    public func teamModel(_ role: TeamRole) -> TeamModel {
        teamModels[role.rawValue].flatMap(TeamModel.init(rawValue:)) ?? role.defaultModel
    }

    public var teamRolesOff: Set<TeamRole> { Set(teamOff.compactMap(TeamRole.init(rawValue:))) }
}
