import Foundation

/// A Claude Code skill: a folder with a SKILL.md whose front matter names it and says when
/// to use it. Project skills live in `.claude/skills`, personal ones in `~/.claude/skills`.
public struct ClaudeSkill: Identifiable, Equatable, Sendable {
    public enum Scope: String, Sendable {
        case project, personal
    }

    public var name: String
    public var description: String
    public var scope: Scope
    /// The SKILL.md file.
    public var file: URL
    public var id: String { file.path }

    public init(name: String, description: String, scope: Scope, file: URL) {
        self.name = name
        self.description = description
        self.scope = scope
        self.file = file
    }
}

/// Something worth teaching Claude about this project, with the prompt that has Claude
/// write the skill from how the project actually does it.
public struct SkillSuggestion: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var reason: String
    public var prompt: String
}

public enum ClaudeSkills {
    /// `name:` and `description:` from a SKILL.md's front matter.
    public static func frontMatter(_ text: String) -> (name: String?, description: String?) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        var name: String?
        var description: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            func value(_ key: String) -> String? {
                guard line.hasPrefix(key + ":") else { return nil }
                let raw = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            name = name ?? value("name")
            description = description ?? value("description")
        }
        return (name, description)
    }

    public static func load(root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ClaudeSkill] {
        func skills(in folder: URL, scope: ClaudeSkill.Scope) -> [ClaudeSkill] {
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return entries.compactMap { entry in
                let file = entry.appending(path: "SKILL.md")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                let meta = frontMatter(text)
                return ClaudeSkill(name: meta.name ?? entry.lastPathComponent, description: meta.description ?? "", scope: scope, file: file)
            }
            .sorted { $0.name < $1.name }
        }
        return skills(in: root.appending(path: ".claude/skills"), scope: .project) + skills(in: home.appending(path: ".claude/skills"), scope: .personal)
    }

    /// The SKILL.md a new skill goes in: a lowercase, hyphenated folder name.
    public static func folderName(_ title: String) -> String {
        let words = title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.joined(separator: "-")
    }

    /// Skills that would pay off for this project and aren't there yet, from what's in it.
    /// `files` are project-relative paths; `existing` are the skills already installed.
    public static func suggestions(files: [String], stack: [String], hasDante: Bool, existing: [ClaudeSkill]) -> [SkillSuggestion] {
        let names = Set(files.map { ($0 as NSString).lastPathComponent.lowercased() })
        let folders = Set(files.flatMap { $0.split(separator: "/").dropLast().map { $0.lowercased() } })
        let has = { (name: String) in names.contains(name) }
        let tests = files.contains { SystemMap.isTest($0) && SystemMap.codeExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        let lowerStack = stack.map { $0.lowercased() }
        var found: [SkillSuggestion] = []

        func add(_ id: String, _ title: String, _ reason: String, _ how: String) {
            let folder = folderName(id)
            found.append(SkillSuggestion(id: folder, title: title, reason: reason, prompt: """
            Create a Claude Code skill in .claude/skills/\(folder)/SKILL.md for this project: \(title.lowercased()).
            Start the file with YAML front matter: `name: \(folder)` and a one-sentence `description:` saying when to use it.
            \(how)
            Base every step on how this project actually does it (read the code first, name real files and commands), keep it under 80 lines, and show me the file before writing it.
            """))
        }

        let routeFiles = files.filter { ["handlers.go", "routes.go", "router.go", "routes.ts", "routes.js", "urls.py", "views.py", "main.py", "app.py"].contains(($0 as NSString).lastPathComponent.lowercased()) }
        if !routeFiles.isEmpty || folders.contains("api") || folders.contains("handlers") || folders.contains("routes") {
            add("add-endpoint", "Add an API endpoint",
                "The project serves an HTTP API" + (routeFiles.first.map { " (\($0))" } ?? "") + ".",
                "Cover the handler, where routes are registered, validation and error responses, the database access it uses, the client call if there is a frontend, and the test to add.")
        }
        if folders.contains("views") || folders.contains("pages") || folders.contains("screens") || folders.contains("components") {
            add("new-screen", "Add a frontend screen",
                "The frontend is built from views or pages.",
                "Cover where screens live, how they're routed and added to navigation, how they fetch data and handle loading and errors, and the shared helpers and styles to reuse.")
        }
        if folders.contains("migrations") || folders.contains("migrate") || names.contains { $0.hasSuffix(".sql") } || files.contains(where: { $0.hasSuffix("schema.prisma") }) {
            add("db-change", "Change the database schema",
                "The project keeps a database schema in the repo.",
                "Cover writing the migration (and how to undo it), where the schema and seed data live, how to run it locally, and what to check in code that reads the changed tables.")
        }
        if has("docker-compose.yml") || has("docker-compose.yaml") || has("compose.yaml") || has("compose.yml") {
            add("local-env", "Run and debug the local environment",
                "The project runs with Docker Compose.",
                "Cover starting the services, checking health and logs, the ports and environment variables involved, and the usual reasons a service won't come up.")
        }
        if tests {
            add("write-tests", "Write tests the project's way",
                "The project has tests" + (lowerStack.isEmpty ? "" : " (\(stack.prefix(2).joined(separator: ", ")))") + ".",
                "Cover where tests live, naming, fixtures and helpers, how to run one test or the suite, and what a good test here checks.")
        }
        if files.contains(where: { $0.hasPrefix(".github/workflows/") }) || has("changelog.md") || has(".goreleaser.yaml") || has(".goreleaser.yml") {
            add("release", "Cut a release",
                "The project has CI or a changelog.",
                "Cover versioning, the changelog, tagging, what CI checks, and how to confirm the release went out.")
        }
        add("review-changes", "Review changes before committing",
            "Catches convention slips before they reach a commit.",
            "List the project's conventions to check (naming, error handling, logging, tests to update, files never to commit) and how to report findings briefly.")

        // A suggestion already covered by an installed skill of the same or a similar name is left out.
        let installed = existing.map { folderName($0.name) }
        return found.filter { suggestion in
            !installed.contains { $0 == suggestion.id || $0.contains(suggestion.id) || suggestion.id.contains($0) }
        }
    }

    /// The prompt for an occasional look at whether the skills still fit.
    public static func reviewPrompt(existing: [ClaudeSkill]) -> String {
        let list = existing.filter { $0.scope == .project }.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        return """
        Review this project's Claude Code skills in .claude/skills\(list.isEmpty ? " (there are none yet)" : ":\n" + list)
        Look at how the project works now and at recent changes (git log). Say which skills are out of date, which repeated kinds of work deserve a new skill, and which skills could go. Don't write anything yet; give me a short list to choose from.
        """
    }

    /// Reviews are due every fortnight, and whenever there has never been one.
    public static func reviewDue(lastReview: Date?, now: Date = .now) -> Bool {
        guard let lastReview else { return true }
        return now.timeIntervalSince(lastReview) > 14 * 86_400
    }
}

/// A file Claude Code reads into every conversation: CLAUDE.md and friends.
public struct ClaudeMemoryFile: Identifiable, Equatable, Sendable {
    public var title: String
    public var note: String
    public var url: URL
    public var exists: Bool
    public var characters: Int
    public var id: String { url.path }

    /// About four characters a token for English and code.
    public var tokens: Int { characters / 4 }

    public static func load(root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ClaudeMemoryFile] {
        let candidates: [(String, String, URL)] = [
            ("CLAUDE.md", "Project memory, checked in", root.appending(path: "CLAUDE.md")),
            (".claude/CLAUDE.md", "Project memory, checked in", root.appending(path: ".claude/CLAUDE.md")),
            ("CLAUDE.local.md", "Your notes for this project, not checked in", root.appending(path: "CLAUDE.local.md")),
            ("~/.claude/CLAUDE.md", "Your memory for every project", home.appending(path: ".claude/CLAUDE.md")),
        ]
        return candidates.compactMap { title, note, url in
            let text = try? String(contentsOf: url, encoding: .utf8)
            // The optional ones only show when they exist; CLAUDE.md always does, to offer making it.
            guard text != nil || title == "CLAUDE.md" else { return nil }
            return ClaudeMemoryFile(title: title, note: note, url: url, exists: text != nil, characters: text?.count ?? 0)
        }
    }
}

/// An MCP server from `claude mcp list`.
public struct MCPServer: Identifiable, Equatable, Sendable {
    public var name: String
    /// The command or URL it runs from, as Claude Code prints it.
    public var source: String
    public var connected: Bool
    public var status: String
    public var id: String { name }

    /// Lines like `github: npx -y @modelcontextprotocol/server-github - ✓ Connected`.
    public static func parse(_ output: String) -> [MCPServer] {
        output.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard let match = line.firstMatch(of: /^([^:\s][^:]*):\s+(.+?)\s+-\s+(✓|✗|⚠|!)\s*(.*)$/) else { return nil }
            return MCPServer(name: String(match.1), source: String(match.2), connected: match.3 == "✓", status: String(match.4))
        }
    }
}

/// Permission rules from `.claude/settings.json` and `.claude/settings.local.json`.
public struct ClaudePermissions: Equatable, Sendable {
    public var allow: [String] = []
    public var deny: [String] = []
    public var ask: [String] = []

    public init(allow: [String] = [], deny: [String] = [], ask: [String] = []) {
        self.allow = allow
        self.deny = deny
        self.ask = ask
    }

    public static func parse(_ texts: [String]) -> ClaudePermissions {
        var result = ClaudePermissions()
        for text in texts {
            guard let json = JSONValue(line: text.replacingOccurrences(of: "\n", with: " ")), let permissions = json["permissions"] else { continue }
            result.allow += permissions["allow"]?.array?.compactMap(\.string) ?? []
            result.deny += permissions["deny"]?.array?.compactMap(\.string) ?? []
            result.ask += permissions["ask"]?.array?.compactMap(\.string) ?? []
        }
        return result
    }

    public static func load(root: URL) -> ClaudePermissions {
        parse([".claude/settings.json", ".claude/settings.local.json"].compactMap { try? String(contentsOf: root.appending(path: $0), encoding: .utf8) })
    }

    public var isEmpty: Bool { allow.isEmpty && deny.isEmpty && ask.isEmpty }
}

/// A Claude Code plugin from `claude plugin list --json [--available]`: skills, commands,
/// agents and hooks bundled together, installed from a marketplace.
public struct ClaudePlugin: Identifiable, Equatable, Sendable {
    public var name: String
    public var marketplace: String?
    public var description: String
    public var version: String?
    public var enabled: Bool
    public var id: String { marketplace.map { "\(name)@\($0)" } ?? name }

    /// Installed and available plugins. Field names vary between Claude Code versions,
    /// so each is read from whichever spelling is there.
    public static func parse(_ json: String) -> (installed: [ClaudePlugin], available: [ClaudePlugin]) {
        guard let value = JSONValue(line: json.replacingOccurrences(of: "\n", with: " ")) else { return ([], []) }
        func plugins(_ list: JSONValue?) -> [ClaudePlugin] {
            (list?.array ?? []).compactMap { entry in
                let id = entry["id"]?.string ?? entry["pluginId"]?.string
                guard let name = entry["name"]?.string ?? id?.components(separatedBy: "@").first, !name.isEmpty else { return nil }
                let marketplace = entry["marketplace"]?.string ?? entry["marketplaceName"]?.string
                    ?? id.flatMap { $0.contains("@") ? $0.components(separatedBy: "@").last : nil }
                return ClaudePlugin(
                    name: name, marketplace: marketplace,
                    description: entry["description"]?.string ?? entry["manifest"]?["description"]?.string ?? "",
                    version: entry["version"]?.string,
                    enabled: entry["enabled"]?.bool ?? entry["isEnabled"]?.bool ?? true)
            }
        }
        if value.array != nil { return (plugins(value), []) }
        return (plugins(value["installed"]), plugins(value["available"]))
    }
}
