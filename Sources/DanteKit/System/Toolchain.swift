import Foundation

/// The command-line tools Dante leans on, whether each is installed, and how to get it.
/// Dante never installs anything itself: it shows the command for the person to run.
public struct Tool: Identifiable, Equatable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case essentials = "Essentials"
        case databases = "Database clients"
        case languageServers = "Language servers"
        case runtimes = "Languages"
    }

    public var id: String
    public var name: String
    public var group: Group
    /// What Dante uses it for.
    public var purpose: String
    /// Executables to look for, first found wins.
    public var executables: [String]
    /// Arguments that print a version.
    public var versionArguments: [String]
    /// Homebrew keg-only installs that aren't on PATH (libpq's psql).
    public var extraPaths: [String]
    public var install: String
    /// Only worth listing when the project uses it (a language server for Go in a Go project).
    public var languages: [String]

    public static let all: [Tool] = [
        Tool(id: "claude", name: "Claude Code", group: .essentials, purpose: "The Claude panel, inline edits and commit messages",
             executables: ["claude"], versionArguments: ["--version"], extraPaths: [], install: "curl -fsSL https://claude.ai/install.sh | bash", languages: []),
        Tool(id: "git", name: "Git", group: .essentials, purpose: "Changes, branches, blame and history",
             executables: ["git"], versionArguments: ["--version"], extraPaths: [], install: "xcode-select --install", languages: []),
        Tool(id: "gh", name: "GitHub CLI", group: .essentials, purpose: "Pull requests and CI runs in Ship",
             executables: ["gh"], versionArguments: ["--version"], extraPaths: [], install: "brew install gh", languages: []),
        Tool(id: "docker", name: "Docker", group: .essentials, purpose: "Containers in Env, and databases inside them",
             executables: ["docker"], versionArguments: ["--version"], extraPaths: [], install: "brew install --cask docker", languages: []),
        Tool(id: "psql", name: "psql", group: .databases, purpose: "PostgreSQL in the Data area",
             executables: ["psql"], versionArguments: ["--version"], extraPaths: ["/opt/homebrew/opt/libpq/bin", "/usr/local/opt/libpq/bin", "/Applications/Postgres.app/Contents/Versions/latest/bin"],
             install: "brew install libpq && brew link --force libpq", languages: []),
        Tool(id: "mysql", name: "mysql", group: .databases, purpose: "MySQL and MariaDB in the Data area",
             executables: ["mysql"], versionArguments: ["--version"], extraPaths: ["/opt/homebrew/opt/mysql-client/bin", "/usr/local/opt/mysql-client/bin"],
             install: "brew install mysql-client && brew link --force mysql-client", languages: []),
        Tool(id: "sqlite3", name: "sqlite3", group: .databases, purpose: "SQLite files in the Data area",
             executables: ["sqlite3"], versionArguments: ["--version"], extraPaths: [], install: "brew install sqlite", languages: []),
        Tool(id: "sourcekit-lsp", name: "SourceKit-LSP", group: .languageServers, purpose: "Swift: errors, completion, go to definition",
             executables: ["sourcekit-lsp"], versionArguments: ["--help"], extraPaths: ["/Library/Developer/CommandLineTools/usr/bin", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"], install: "xcode-select --install", languages: ["Swift"]),
        Tool(id: "gopls", name: "gopls", group: .languageServers, purpose: "Go: errors, completion, go to definition",
             executables: ["gopls"], versionArguments: ["version"], extraPaths: ["~/go/bin"], install: "go install golang.org/x/tools/gopls@latest", languages: ["Go"]),
        Tool(id: "typescript-language-server", name: "TypeScript server", group: .languageServers, purpose: "JavaScript and TypeScript: errors, completion",
             executables: ["typescript-language-server"], versionArguments: ["--version"], extraPaths: ["~/.bun/bin"],
             install: "npm install -g typescript typescript-language-server", languages: ["JavaScript", "TypeScript"]),
        Tool(id: "pyright", name: "Pyright", group: .languageServers, purpose: "Python: errors, completion",
             executables: ["pyright-langserver", "basedpyright-langserver", "pylsp"], versionArguments: ["--version"], extraPaths: [],
             install: "npm install -g pyright", languages: ["Python"]),
        Tool(id: "rust-analyzer", name: "rust-analyzer", group: .languageServers, purpose: "Rust: errors, completion",
             executables: ["rust-analyzer"], versionArguments: ["--version"], extraPaths: ["~/.cargo/bin"], install: "rustup component add rust-analyzer", languages: ["Rust"]),
        Tool(id: "go", name: "Go", group: .runtimes, purpose: "Building and testing Go code",
             executables: ["go"], versionArguments: ["version"], extraPaths: ["/usr/local/go/bin"], install: "brew install go", languages: ["Go"]),
        Tool(id: "node", name: "Node.js", group: .runtimes, purpose: "Running JavaScript tooling",
             executables: ["node"], versionArguments: ["--version"], extraPaths: [], install: "brew install node", languages: ["JavaScript", "TypeScript"]),
        Tool(id: "python3", name: "Python", group: .runtimes, purpose: "Running Python code and tests",
             executables: ["python3"], versionArguments: ["--version"], extraPaths: [], install: "brew install python", languages: ["Python"]),
    ]

    /// Essentials and database clients always; language tools when the project uses the language.
    public static func relevant(stack: [String]) -> [Tool] {
        let lower = Set(stack.map { $0.lowercased() })
        return all.filter { tool in
            tool.languages.isEmpty || tool.languages.contains { lower.contains($0.lowercased()) }
        }
    }

    /// The first line that carries a version number, tidied: "psql (PostgreSQL) 16.4" → "16.4".
    public static func version(from output: String) -> String? {
        for line in output.split(separator: "\n").prefix(3) {
            if let match = line.firstMatch(of: /(\d+\.\d+(?:\.\d+)?)/) { return String(match.1) }
        }
        return nil
    }
}

public struct ToolStatus: Equatable, Sendable {
    public var path: String?
    public var version: String?
    public var installed: Bool { path != nil }

    public static func check(_ tool: Tool) async -> ToolStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path: String?
        for executable in tool.executables {
            if let found = Shell.which(executable) { path = found; break }
            for folder in tool.extraPaths {
                let candidate = (folder.replacingOccurrences(of: "~", with: home) as NSString).appendingPathComponent(executable)
                if FileManager.default.isExecutableFile(atPath: candidate) { path = candidate; break }
            }
            if path != nil { break }
        }
        guard let path else { return ToolStatus(path: nil, version: nil) }
        // Docker's daemon and sourcekit's help can be slow or chatty; one short call each.
        let output = await Shell.run([path] + tool.versionArguments, in: FileManager.default.temporaryDirectory)
        return ToolStatus(path: path, version: Tool.version(from: output.stdout + "\n" + output.stderr))
    }
}
