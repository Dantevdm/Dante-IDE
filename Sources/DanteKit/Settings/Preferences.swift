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
        claudeModel = defaults.string(forKey: Keys.claudeModel).flatMap(ClaudeModel.init(rawValue:)) ?? .default
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
        static let claudeModel = "claudeModel"
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
