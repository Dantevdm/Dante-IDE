import Foundation

/// A language server Dante knows how to start, and the languages it handles.
public struct LanguageServer: Hashable, Sendable {
    public var name: String
    /// Alternatives, tried in order; the first whose executable exists wins.
    public var commands: [[String]]
    public var languageIDs: [Language: String]

    public static let all: [LanguageServer] = [
        LanguageServer(name: "SourceKit-LSP", commands: [["xcrun", "sourcekit-lsp"], ["sourcekit-lsp"]], languageIDs: [.swift: "swift"]),
        LanguageServer(name: "TypeScript", commands: [["typescript-language-server", "--stdio"]], languageIDs: [.typescript: "typescript", .javascript: "javascript"]),
        LanguageServer(name: "Pyright", commands: [["pyright-langserver", "--stdio"], ["basedpyright-langserver", "--stdio"], ["pylsp"]], languageIDs: [.python: "python"]),
        LanguageServer(name: "gopls", commands: [["gopls"]], languageIDs: [.go: "go"]),
        LanguageServer(name: "rust-analyzer", commands: [["rust-analyzer"]], languageIDs: [.rust: "rust"]),
        LanguageServer(name: "clangd", commands: [["clangd"]], languageIDs: [.c: "c", .cpp: "cpp"]),
    ]

    public static func `for`(_ language: Language) -> LanguageServer? {
        all.first { $0.languageIDs[language] != nil }
    }

    /// Folders searched besides PATH: where Go, Cargo and Bun install tools.
    static func extraFolders(home: String) -> [String] {
        ["\(home)/go/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// The first command whose executable can be found, with its full path.
    public func resolve(environment: [String: String]) -> (executable: URL, arguments: [String])? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + Self.extraFolders(home: home)
        for command in commands {
            guard let program = command.first else { continue }
            if program == "xcrun" {
                guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun"),
                      Self.xcrunFinds(command[1]) else { continue }
                return (URL(filePath: "/usr/bin/xcrun"), Array(command.dropFirst()))
            }
            for folder in folders {
                let path = (folder as NSString).appendingPathComponent(program)
                if FileManager.default.isExecutableFile(atPath: path) {
                    return (URL(filePath: path), Array(command.dropFirst()))
                }
            }
        }
        return nil
    }

    // MARK: On a remote project's host

    /// A script for the host that prints `name<TAB>path args…` for each server it has: the
    /// first of the server's commands found on PATH or in the usual tool folders. xcrun
    /// commands are skipped; hosts are rarely Macs.
    public static func hostProbeScript(_ servers: [LanguageServer] = all) -> String {
        var lines = [#"PATH="$PATH:$HOME/go/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$HOME/.local/bin""#]
        for server in servers {
            let commands = server.commands.filter { $0.first != "xcrun" && !$0.isEmpty }
            guard !commands.isEmpty else { continue }
            let branches = commands.map { command in
                let rest = command.dropFirst().map(Shell.quote).joined(separator: " ")
                return "if p=$(command -v \(Shell.quote(command[0])) 2>/dev/null); then printf '%s\\t%s\\n' \(Shell.quote(server.name)) \"$p\(rest.isEmpty ? "" : " " + rest)\""
            }
            lines.append(branches.joined(separator: "; el") + "; fi")
        }
        return lines.joined(separator: "\n")
    }

    /// The probe's output as server name → command words on the host.
    public static func hostCommands(fromProbe output: String) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].hasPrefix("/") else { continue }
            found[parts[0]] = parts[1].split(separator: " ").map(String.init)
        }
        return found
    }

    private static func xcrunFinds(_ tool: String) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["--find", tool]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// A zero-based line and UTF-16 offset, as LSP counts them.
public struct LSPPosition: Hashable, Sendable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    init?(_ json: JSONValue?) {
        guard let line = json?["line"]?.int, let character = json?["character"]?.int else { return nil }
        self.init(line: line, character: character)
    }

    var json: JSONValue { ["line": .number(Double(line)), "character": .number(Double(character))] }

    /// The position of a UTF-16 offset in `text`.
    public init(offset: Int, in text: NSString) {
        let clamped = min(max(offset, 0), text.length)
        var line = 0
        var lineStart = 0
        var index = 0
        while index < clamped {
            let unit = text.character(at: index)
            if unit == 0x0A {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        self.init(line: line, character: clamped - lineStart)
    }

    /// The UTF-16 offset of this position in `text`, clamped to its line.
    public func offset(in text: NSString) -> Int {
        var currentLine = 0
        var index = 0
        while currentLine < line, index < text.length {
            if text.character(at: index) == 0x0A { currentLine += 1 }
            index += 1
        }
        if currentLine < line { return text.length }
        var end = index
        while end < text.length, text.character(at: end) != 0x0A { end += 1 }
        return min(index + character, end)
    }
}

/// Where each line starts, for converting many positions in the same text in one pass.
public struct LineIndex: Sendable {
    private let starts: [Int]
    private let length: Int

    public init(_ text: NSString) {
        var starts = [0]
        for index in 0..<text.length where text.character(at: index) == 0x0A {
            starts.append(index + 1)
        }
        self.starts = starts
        length = text.length
    }

    public func offset(of position: LSPPosition) -> Int {
        guard position.line < starts.count else { return length }
        let start = starts[max(position.line, 0)]
        let end = position.line + 1 < starts.count ? starts[position.line + 1] - 1 : length
        return min(start + max(position.character, 0), end)
    }

    public func range(of range: LSPRange) -> NSRange {
        let lower = offset(of: range.start)
        return NSRange(location: lower, length: max(offset(of: range.end) - lower, 0))
    }
}

public struct LSPRange: Hashable, Sendable {
    public var start: LSPPosition
    public var end: LSPPosition

    init?(_ json: JSONValue?) {
        guard let start = LSPPosition(json?["start"]), let end = LSPPosition(json?["end"]) else { return nil }
        self.start = start
        self.end = end
    }

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    public func nsRange(in text: NSString) -> NSRange {
        let lower = start.offset(in: text)
        return NSRange(location: lower, length: max(end.offset(in: text) - lower, 0))
    }
}

public struct LSPDiagnostic: Hashable, Sendable, Identifiable {
    public enum Severity: Int, Sendable, Comparable {
        case error = 1, warning, information, hint
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var range: LSPRange
    public var severity: Severity
    public var message: String
    public var source: String?
    public var id: String { "\(range.start.line):\(range.start.character):\(message)" }

    public init(range: LSPRange, severity: Severity, message: String, source: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }

    init?(_ json: JSONValue) {
        guard let range = LSPRange(json["range"]), let message = json["message"]?.string else { return nil }
        self.init(range: range, severity: json["severity"]?.int.flatMap(Severity.init(rawValue:)) ?? .error,
                  message: message, source: json["source"]?.string)
    }
}

public struct LSPLocation: Hashable, Sendable {
    public var url: URL
    public var range: LSPRange

    /// Reads a definition result: a Location, an array of them, or LocationLinks.
    static func list(_ json: JSONValue) -> [LSPLocation] {
        let items = json.array ?? (json.isNull ? [] : [json])
        return items.compactMap { item in
            let uri = item["uri"]?.string ?? item["targetUri"]?.string
            let range = LSPRange(item["targetSelectionRange"]) ?? LSPRange(item["range"]) ?? LSPRange(item["targetRange"])
            guard let uri, let url = URL(string: uri), url.isFileURL, let range else { return nil }
            return LSPLocation(url: url.standardizedFileURL, range: range)
        }
    }
}
