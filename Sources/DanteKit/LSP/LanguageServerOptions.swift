import Foundation

/// What the person set for one language server in Settings: whether it runs, a command
/// to use instead of the one Dante finds, and settings (JSON) for the server.
public struct LanguageServerOptions: Codable, Equatable, Sendable {
    public var enabled = true
    /// "path/to/server --stdio", split on spaces; quotes keep a path with spaces together.
    public var command = ""
    /// A JSON object: sent as initializationOptions, and the answer to workspace/configuration.
    public var settings = ""

    public init(enabled: Bool = true, command: String = "", settings: String = "") {
        self.enabled = enabled
        self.command = command
        self.settings = settings
    }

    static let key = "languageServerOptions"

    public static func load(defaults: UserDefaults = .standard) -> [String: LanguageServerOptions] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: LanguageServerOptions].self, from: $0) } ?? [:]
    }

    public static func save(_ all: [String: LanguageServerOptions], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(all.filter { $0.value != LanguageServerOptions() }), forKey: key)
    }

    /// The command split into words.
    public var commandWords: [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in command {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The settings as JSON, or nil when empty; `settingsError` says why it isn't valid.
    public var settingsJSON: JSONValue? {
        let trimmed = settings.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = JSONValue(line: trimmed.replacingOccurrences(of: "\n", with: " ")), value.object != nil else { return nil }
        return value
    }

    public var settingsError: String? {
        let trimmed = settings.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, settingsJSON == nil else { return nil }
        return "Settings must be a JSON object, like {\"python\": {\"analysis\": {\"typeCheckingMode\": \"strict\"}}}"
    }

    /// The part of the settings a server asks for: `section` is dotted ("python.analysis");
    /// none means all of them.
    public func configuration(section: String?) -> JSONValue {
        guard var value = settingsJSON else { return .null }
        guard let section, !section.isEmpty else { return value }
        for key in section.split(separator: ".") {
            guard let next = value[String(key)] else { return .null }
            value = next
        }
        return value
    }
}

extension LanguageServer {
    /// The server with the person's command tried first.
    public func applying(_ options: LanguageServerOptions?) -> LanguageServer {
        guard let options, !options.commandWords.isEmpty else { return self }
        var server = self
        server.commands = [options.commandWords]
        return server
    }
}
