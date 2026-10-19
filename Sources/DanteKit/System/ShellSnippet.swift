import Foundation

/// A code block in a reply that reads as commands to run, turned into one line to type into
/// the terminal: prompts (`$ `) and comments go, continued lines are joined, and separate
/// commands are chained with `&&`, so nothing runs before the person presses Return.
public enum ShellSnippet {
    static let shellTags: Set<String> = ["bash", "sh", "shell", "zsh", "console", "terminal", "fish", "shell-session", "shellsession"]
    static let notShell: Set<String> = ["swift", "python", "py", "js", "javascript", "ts", "typescript", "go", "rust", "json", "yaml", "yml",
                                        "sql", "java", "kotlin", "ruby", "html", "css", "toml", "xml", "diff", "markdown", "md", "text", "txt"]
    /// Programs a command line in a reply usually starts with, for blocks without a language.
    static let programs: Set<String> = [
        "docker", "docker-compose", "podman", "git", "gh", "npm", "npx", "pnpm", "yarn", "bun", "bunx", "deno", "node",
        "brew", "make", "cd", "go", "cargo", "rustup", "swift", "xcodebuild", "xcrun", "xcode-select", "python", "python3",
        "pip", "pip3", "pipx", "uv", "poetry", "pytest", "ruby", "gem", "bundle", "rails", "rake", "java", "mvn", "./mvnw",
        "gradle", "./gradlew", "dotnet", "php", "composer", "kubectl", "helm", "terraform", "tofu", "aws", "gcloud", "az",
        "curl", "wget", "ssh", "scp", "rsync", "psql", "mysql", "sqlite3", "redis-cli", "open", "ls", "cat", "cp", "mv",
        "mkdir", "rm", "touch", "chmod", "export", "source", "echo", "sudo", "claude", "codex", "dante", "ollama", "flyway",
        "lsof", "kill", "pkill", "ps", "tail", "head", "grep", "rg", "find", "jq", "env", "which", "defaults", "launchctl",
    ]

    /// The line to type, or nil when the block isn't commands.
    public static func command(from code: String, language: String?) -> String? {
        let tag = language?.lowercased().trimmingCharacters(in: .whitespaces)
        if let tag, !tag.isEmpty, !shellTags.contains(tag) { return nil }
        var commands: [String] = []
        var pending = ""
        for raw in code.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if pending.isEmpty {
                if line.isEmpty || line.hasPrefix("#") { continue }
                for prompt in ["$ ", "% ", "> "] where line.hasPrefix(prompt) { line = String(line.dropFirst(prompt.count)) }
            }
            if line.hasSuffix("\\") {
                pending += line.dropLast().trimmingCharacters(in: .whitespaces) + " "
                continue
            }
            commands.append(pending + line)
            pending = ""
        }
        if !pending.isEmpty { commands.append(pending.trimmingCharacters(in: .whitespaces)) }
        guard !commands.isEmpty, commands.count <= 8 else { return nil }
        // Without a shell tag, every line has to start like a command.
        if tag == nil || tag?.isEmpty == true {
            let looksRight = commands.allSatisfy { command in
                let first = command.split(separator: " ").first.map(String.init) ?? ""
                return programs.contains(first) || (first.hasPrefix("./") && first.count > 2) || (first.contains("=") && !first.hasPrefix("="))
            }
            guard looksRight else { return nil }
        }
        return commands.joined(separator: " && ")
    }
}
