import Darwin
import Foundation
import Yams

/// What Claude may touch, from `claude:` in `.dante/project.yaml`:
///
///     claude:
///       propose: [src/, test/, docs/]   # where changes are expected
///       flag: [migrations/, infra/]     # allowed, but called out for extra care
///       never: [".env*", secrets/]      # refused outright, reads included
///
/// A pattern ending in `/` is a folder (matched at the root or anywhere below it);
/// anything else is a glob matched against the path and the file name.
public struct ClaudeRules: Equatable, Sendable {
    public var propose: [String]
    public var flag: [String]
    public var never: [String]

    public init(propose: [String] = [], flag: [String] = [], never: [String] = []) {
        self.propose = propose
        self.flag = flag
        self.never = never
    }

    public var isEmpty: Bool { propose.isEmpty && flag.isEmpty && never.isEmpty }

    public static func parse(projectYAML yaml: String) -> ClaudeRules {
        guard let root = (try? Yams.load(yaml: yaml)) as? [String: Any],
              let claude = root["claude"] as? [String: Any] else { return ClaudeRules() }
        func list(_ key: String) -> [String] {
            if let values = claude[key] as? [Any] { return values.map { "\($0)" } }
            if let value = claude[key] as? String { return [value] }
            return []
        }
        return ClaudeRules(propose: list("propose"), flag: list("flag"), never: list("never"))
    }

    public static func load(projectRoot: URL) -> ClaudeRules {
        guard let yaml = try? String(contentsOf: projectRoot.appending(path: ".dante/project.yaml"), encoding: .utf8) else {
            return ClaudeRules()
        }
        return parse(projectYAML: yaml)
    }

    // MARK: Matching

    public enum Verdict: Equatable, Sendable {
        case allowed
        /// Allowed, with a note for the reviewer.
        case note(String)
        /// Refused; the message goes back to Claude.
        case blocked(String)
    }

    /// Judges a tool call. `root` resolves absolute paths into project-relative ones.
    public func verdict(toolName: String, input: JSONValue, root: URL) -> Verdict {
        if toolName == "Bash", let command = input["command"]?.string {
            if let pattern = never.first(where: { Self.command(command, mentions: $0) }) {
                return .blocked("This project’s rules (.dante/project.yaml, claude.never) don’t allow commands that touch \(pattern).")
            }
            if let pattern = flag.first(where: { Self.command(command, mentions: $0) }) {
                return .note("Touches \(pattern), which this project flags for extra care.")
            }
            return .allowed
        }

        guard let path = Self.path(in: input) else { return .allowed }
        let relative = ProposedChange.relativePath(of: URL(filePath: path, relativeTo: root), in: root)
        if let pattern = never.first(where: { Self.path(relative, matches: $0) }) {
            return .blocked("This project’s rules (.dante/project.yaml, claude.never) don’t allow touching \(pattern).")
        }
        guard ProposedChange.toolNames.contains(toolName) || toolName == "NotebookEdit" else { return .allowed }
        if let pattern = flag.first(where: { Self.path(relative, matches: $0) }) {
            return .note("\(pattern) is flagged in this project’s rules: review with extra care.")
        }
        if !propose.isEmpty, !propose.contains(where: { Self.path(relative, matches: $0) }) {
            return .note("Outside where this project expects changes (\(propose.joined(separator: ", "))).")
        }
        return .allowed
    }

    /// Claude Code permission rules that refuse `never` paths inside Claude Code itself,
    /// so reads (which don't ask for approval) are covered too.
    public var denyRules: [String] {
        never.flatMap { pattern -> [String] in
            let glob = pattern.hasSuffix("/") ? pattern + "**" : pattern
            let path = glob.contains("/") ? "./\(glob)" : "**/\(glob)"
            return ["Read(\(path))", "Edit(\(path))"]
        }
    }

    /// `--settings` JSON carrying `denyRules`, or nil when there's nothing to deny.
    public var settingsJSON: String? {
        guard !never.isEmpty else { return nil }
        let rules: JSONValue = .array(denyRules.map { .string($0) })
        return JSONValue.object(["permissions": ["deny": rules]]).jsonLine
    }

    static func path(in input: JSONValue) -> String? {
        input["file_path"]?.string ?? input["notebook_path"]?.string ?? input["path"]?.string
    }

    static func path(_ relative: String, matches pattern: String) -> Bool {
        let pattern = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
        if pattern.hasSuffix("/") {
            let folder = String(pattern.dropLast())
            return relative == folder || relative.hasPrefix(pattern) || relative.contains("/" + pattern)
        }
        let name = (relative as NSString).lastPathComponent
        return fnmatch(pattern, relative, 0) == 0 || fnmatch(pattern, name, 0) == 0
    }

    /// Whether a shell command names a path matching the pattern. A heuristic: it checks
    /// each word, so it catches `cat .env` but not paths built at runtime.
    static func command(_ command: String, mentions pattern: String) -> Bool {
        let words = command.split { $0.isWhitespace || ";|&<>()'\"`=".contains($0) }
        return words.contains { word in
            let token = word.hasPrefix("./") ? String(word.dropFirst(2)) : String(word)
            return path(token, matches: pattern)
        }
    }
}
