import Foundation

/// How much Claude may do without asking. Whatever the level, `never` paths are refused and
/// edits with a rule note (`flag`, outside `propose`) still ask; questions always wait for you.
public enum ApprovalLevel: String, Sendable, CaseIterable, Identifiable {
    /// Claude Code's own rule: reads run, edits and other commands ask.
    case ask
    /// File edits apply straight away (each turn can still be undone); commands ask.
    case edits
    /// Edits and commands run without asking.
    case everything

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ask: "Ask before edits and commands"
        case .edits: "Apply edits, ask before commands"
        case .everything: "Don’t ask"
        }
    }

    public var short: String {
        switch self {
        case .ask: "Ask"
        case .edits: "Auto-edit"
        case .everything: "Auto"
        }
    }

    public var symbol: String {
        switch self {
        case .ask: "hand.raised"
        case .edits: "pencil.and.outline"
        case .everything: "bolt"
        }
    }
}

/// Whether a tool call can go ahead without asking, and the rules "Always allow" writes.
/// Rules use Claude Code's syntax in `.claude/settings.local.json`: `Bash(git log:*)` allows
/// commands starting `git log`, `Bash(make test)` that exact command, `Edit` every edit,
/// `WebFetch(domain:example.com)` one site, and an MCP tool by its name.
public enum ApprovalPolicy {
    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    /// Tools that need your answer, not your permission.
    static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    public static func approves(_ toolName: String, input: JSONValue, level: ApprovalLevel, allow: [String], hasRuleNote: Bool) -> Bool {
        guard !questionTools.contains(toolName), !hasRuleNote else { return false }
        if allowed(toolName, input: input, by: allow) { return true }
        switch level {
        case .ask: return false
        case .edits: return editTools.contains(toolName)
        case .everything: return true
        }
    }

    /// Whether allow rules cover the call. A command with several parts (pipes, `&&`) needs
    /// every part covered; one that substitutes commands or redirects output never is.
    public static func allowed(_ toolName: String, input: JSONValue, by rules: [String]) -> Bool {
        guard !rules.isEmpty else { return false }
        if toolName == "Bash" {
            guard let command = input["command"]?.string, let parts = commandParts(command) else { return false }
            return parts.allSatisfy { part in rules.contains { matches($0, command: part) } }
        }
        return rules.contains { rule in
            if rule == toolName { return true }
            if toolName == "WebFetch", rule.hasPrefix("WebFetch(domain:"), let url = input["url"]?.string.flatMap(URL.init(string:)), let host = url.host() {
                let domain = String(rule.dropFirst("WebFetch(domain:".count).dropLast())
                return host == domain || host.hasSuffix("." + domain)
            }
            return false
        }
    }

    static func matches(_ rule: String, command: String) -> Bool {
        if rule == "Bash" { return true }
        guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return false }
        let body = String(rule.dropFirst(5).dropLast())
        if body.hasSuffix(":*") {
            let prefix = String(body.dropLast(2))
            return command == prefix || command.hasPrefix(prefix + " ")
        }
        return command == body
    }

    /// The rules "Always allow" adds for a call: one per part of a command (its program, plus
    /// the subcommand for tools like git and npm), the edit tool, the site, or the MCP tool.
    public static func rules(for toolName: String, input: JSONValue) -> [String] {
        switch toolName {
        case "Bash":
            guard let command = input["command"]?.string, let parts = commandParts(command) else { return [] }
            var rules: [String] = []
            for part in parts {
                let rule = "Bash(\(prefix(of: part)):*)"
                if !rules.contains(rule) { rules.append(rule) }
            }
            return rules
        case "WebFetch":
            guard let host = input["url"]?.string.flatMap(URL.init(string:))?.host() else { return [] }
            return ["WebFetch(domain:\(host))"]
        case _ where editTools.contains(toolName):
            return [toolName == "MultiEdit" ? "Edit" : toolName]
        case _ where questionTools.contains(toolName):
            return []
        default:
            return [toolName]
        }
    }

    /// Programs whose first plain word after them is a subcommand worth keeping in a rule.
    static let subcommandTools: Set<String> = ["git", "npm", "pnpm", "yarn", "bun", "go", "swift", "cargo", "docker", "kubectl",
                                                "make", "gh", "uv", "pip", "poetry", "brew", "terraform", "dotnet", "mvn", "gradle"]

    /// "git -C ~/x log --oneline" → "git -C ~/x log"; "uniq -c" → "uniq".
    static func prefix(of command: String) -> String {
        let words = command.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = words.first else { return command }
        guard subcommandTools.contains(String(first)) else { return String(first) }
        var index = 1
        while index < words.count {
            let word = words[index]
            if word.hasPrefix("-") {
                // Options that take a value: keep the value with them.
                if ["-C", "-c", "--git-dir", "--work-tree", "-f", "--file", "-p", "--prefix"].contains(String(word)) { index += 1 }
                index += 1
                continue
            }
            return words[...index].joined(separator: " ")
        }
        return String(first)
    }

    /// The simple commands in a command line, or nil when it does something rules shouldn't
    /// vouch for: command substitution, backticks, output redirection or a subshell.
    static func commandParts(_ command: String) -> [String]? {
        if command.contains("$(") || command.contains("`") || command.contains("<(") { return nil }
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var characters = Array(command)[...]
        func flush() {
            let part = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { parts.append(part) }
            current = ""
        }
        while let c = characters.popFirst() {
            if let open = quote {
                current.append(c)
                if c == open { quote = nil }
                continue
            }
            switch c {
            case "\"", "'":
                quote = c
                current.append(c)
            case "|", "&", ";", "\n":
                if c == "&", characters.first != "&" {
                    // `2>&1` is a redirect between streams, not a separator; a lone `&` backgrounds.
                    if current.hasSuffix(">") { current.append(c); continue }
                    return nil
                }
                if characters.first == c { characters.removeFirst() }
                flush()
            case ">":
                // Writing into files isn't something an allow rule for the program covers,
                // except throwing output away or joining stderr to stdout.
                let rest = String(characters.prefix(10)).trimmingCharacters(in: .whitespaces)
                if !(rest.hasPrefix("/dev/null") || rest.hasPrefix("&1") || rest.hasPrefix("&2")) { return nil }
                current.append(c)
            case "(", ")":
                return nil
            default:
                current.append(c)
            }
        }
        guard quote == nil else { return nil }
        flush()
        // Strip harmless redirects so `cmd 2>/dev/null` matches a rule for `cmd`.
        return parts.map { part in
            part.replacingOccurrences(of: #"\s*\d?>\s*(/dev/null|&[12])"#, with: "", options: .regularExpression)
        }
    }

    /// `.claude/settings.local.json` with `rules` added to `permissions.allow`, keeping
    /// everything else in it. Nil `existing` starts a new file.
    public static func settings(adding rules: [String], to existing: String?) -> String {
        var root = existing.flatMap { JSONValue(line: $0.replacingOccurrences(of: "\n", with: " ")) }?.object ?? [:]
        var permissions = root["permissions"]?.object ?? [:]
        var allow = permissions["allow"]?.array?.compactMap(\.string) ?? []
        for rule in rules where !allow.contains(rule) { allow.append(rule) }
        permissions["allow"] = .array(allow.map { .string($0) })
        root["permissions"] = .object(permissions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(JSONValue.object(root))) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
