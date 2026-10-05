import Foundation

/// What shipping now would include: the next version and a changelog drafted from the
/// commits since the last tag. Conventional commit prefixes (feat, fix, …) sort entries;
/// anything else counts as a change.
public struct ReleaseDraft: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var text: String
        public var hash: String
        public var id: String { hash }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public var title: String
        public var entries: [Entry]
        public var id: String { title }
    }

    public var previous: String?
    public var version: String
    public var sections: [Section]
    /// Commits left out: merges, version bumps and chores.
    public var skipped: Int

    public var isEmpty: Bool { sections.isEmpty }

    public init(previousTag: String?, commits: [GitSnapshot.Commit]) {
        previous = previousTag
        var added: [Entry] = [], fixed: [Entry] = [], changed: [Entry] = []
        var breaking = false
        var skipped = 0
        for commit in commits {
            let parsed = Self.parse(commit.subject)
            breaking = breaking || parsed.breaking
            let entry = Entry(text: parsed.text, hash: commit.hash)
            switch parsed.kind {
            case "feat", "add": added.append(entry)
            case "fix", "bug": fixed.append(entry)
            case "chore", "ci", "build", "style", "release", "bump", "merge": skipped += 1
            default: changed.append(entry)
            }
        }
        self.skipped = skipped
        sections = [Section(title: "Added", entries: added), Section(title: "Changed", entries: changed), Section(title: "Fixed", entries: fixed)]
            .filter { !$0.entries.isEmpty }
        version = Self.next(after: previousTag, breaking: breaking, features: !added.isEmpty)
    }

    /// `feat(parser)!: Thing` → kind "feat", breaking, "Thing". Unprefixed subjects have no kind.
    static func parse(_ subject: String) -> (kind: String?, breaking: Bool, text: String) {
        if subject.hasPrefix("Merge ") { return ("merge", false, subject) }
        guard let match = subject.firstMatch(of: /^([a-zA-Z]+)(\([^)]*\))?(!)?:\s*(.+)$/) else {
            return (nil, false, subject)
        }
        let text = String(match.4)
        return (match.1.lowercased(), match.3 != nil, text.prefix(1).uppercased() + text.dropFirst())
    }

    /// Bumps a semantic version: major for breaking changes (minor before 1.0), minor for
    /// features, patch otherwise. Keeps a leading "v" if the last tag had one.
    public static func next(after tag: String?, breaking: Bool, features: Bool) -> String {
        guard let tag, let match = tag.firstMatch(of: /^(v?)(\d+)\.(\d+)\.(\d+)/),
              var major = Int(match.2), var minor = Int(match.3), var patch = Int(match.4) else {
            return "v0.1.0"
        }
        if breaking, major > 0 {
            major += 1; minor = 0; patch = 0
        } else if breaking || features {
            minor += 1; patch = 0
        } else {
            patch += 1
        }
        return "\(match.1)\(major).\(minor).\(patch)"
    }

    public var markdown: String {
        var lines = ["## \(version)"]
        for section in sections {
            lines.append("")
            lines.append("### \(section.title)")
            lines += section.entries.map { "- \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// A GitHub Actions run, from `gh run list`.
public struct CIRun: Equatable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var workflow: String
    public var branch: String
    /// queued, in_progress, completed.
    public var status: String
    /// success, failure, cancelled, skipped… once completed.
    public var conclusion: String
    public var created: Date?
    public var url: URL?

    public var isRunning: Bool { status != "completed" }
    public var succeeded: Bool { conclusion == "success" }

    public enum Unavailable: Error, Equatable, Sendable {
        case noWorkflows, noGitHubCLI, failed(String)
    }

    public static func hasWorkflows(projectRoot root: URL) -> Bool {
        let folder = root.appending(path: ".github/workflows")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.contains { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
    }

    public static func load(projectRoot root: URL, limit: Int = 6) async -> Result<[CIRun], Unavailable> {
        guard hasWorkflows(projectRoot: root) else { return .failure(.noWorkflows) }
        guard Shell.which("gh") != nil else { return .failure(.noGitHubCLI) }
        let output = await Shell.run(
            ["gh", "run", "list", "--limit", "\(limit)", "--json", "databaseId,displayTitle,workflowName,headBranch,status,conclusion,createdAt,url"],
            in: root
        )
        guard output.succeeded else { return .failure(.failed(output.message)) }
        return .success(parse(output.stdout))
    }

    static func parse(_ json: String) -> [CIRun] {
        let formatter = ISO8601DateFormatter()
        return (JSONValue(line: json)?.array ?? []).compactMap { run in
            guard let id = run["databaseId"]?.int else { return nil }
            return CIRun(
                id: id,
                title: run["displayTitle"]?.string ?? "",
                workflow: run["workflowName"]?.string ?? "",
                branch: run["headBranch"]?.string ?? "",
                status: run["status"]?.string ?? "",
                conclusion: run["conclusion"]?.string ?? "",
                created: run["createdAt"]?.string.flatMap(formatter.date(from:)),
                url: run["url"]?.string.flatMap(URL.init(string:))
            )
        }
    }
}

extension Git {
    /// Creates an annotated tag at HEAD. It stays local until pushed.
    public static func tag(_ name: String, message: String, in root: URL) async throws {
        let output = await Shell.run(["git", "tag", "-a", name, "-m", message], in: root)
        if !output.succeeded { throw CommandError(output: output.message) }
    }
}
