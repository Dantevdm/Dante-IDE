import Foundation

/// A branch name for working on a task: its id and the first words of its title.
public enum TaskBranch {
    public static func name(for task: PlanTask, maxLength: Int = 48) -> String {
        let words = task.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var name = task.id.lowercased()
        for word in words {
            guard name.count + 1 + word.count <= maxLength else { break }
            name += "-" + word
        }
        return name
    }
}

/// A pull request title and description, drafted by Claude from a task and its diff.
public struct PullRequestDraft: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    public static let system = """
        You write GitHub pull request descriptions. Reply with the title on the first line, a blank \
        line, then the description in markdown. No preamble and no code fence around the reply.
        """

    public static func prompt(task: PlanTask, diff: String, commits: [String]) -> String {
        var parts = ["Write a pull request for task \(task.id): \(task.title)."]
        if let note = task.note, !note.isEmpty { parts.append("The task's note: \(note)") }
        parts.append("""
            Keep the title under 70 characters. In the description, say what changed and why in a few \
            short paragraphs or bullets, then a "Testing" section with how it was checked if the diff shows tests. \
            Don't invent anything the diff doesn't show.
            """)
        if !commits.isEmpty { parts.append("Commits:\n" + commits.map { "- \($0)" }.joined(separator: "\n")) }
        parts.append("Changes:\n" + diff)
        return parts.joined(separator: "\n\n")
    }

    /// The first line is the title (a "Title:" label or leading # is dropped); the rest is the body.
    public static func parse(_ answer: String) -> PullRequestDraft {
        var lines = CommitMessage.clean(answer).components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard !lines.isEmpty else { return PullRequestDraft(title: "", body: "") }
        var title = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        while title.hasPrefix("#") { title.removeFirst() }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)) }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.count > 1, let first = title.first, first == title.last, "\"'`*".contains(first) {
            title = String(title.dropFirst().dropLast())
        }
        var body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("description:") { body = String(body.dropFirst(12)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return PullRequestDraft(title: title, body: body)
    }
}

/// GitHub through the `gh` command line tool, signed in by the user.
public enum GitHub {
    public static var isAvailable: Bool { Shell.which("gh") != nil }

    /// Whether `origin` (or the first remote) is on GitHub.
    public static func hasGitHubRemote(in root: URL) async -> Bool {
        let remotes = await Shell.run(["git", "remote", "-v"], in: root)
        return remotes.stdout.contains("github.com")
    }

    /// The branch pull requests go into: the remote's HEAD, else main or master.
    public static func defaultBranch(in root: URL, branches: [GitBranch]) async -> String {
        let head = await Shell.run(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root)
        if head.succeeded, let name = head.stdout.components(separatedBy: "/").dropFirst().joined(separator: "/").nilIfEmpty {
            return name
        }
        let names = Set(branches.map(\.localName))
        return names.contains("main") || !names.contains("master") ? "main" : "master"
    }

    /// Commit subjects on this branch that aren't on `base`.
    public static func commits(since base: String, in root: URL) async -> [String] {
        for ref in ["origin/\(base)", base] {
            let output = await Shell.run(["git", "log", "\(ref)..HEAD", "--format=%s"], in: root)
            if output.succeeded { return output.stdout.components(separatedBy: "\n").filter { !$0.isEmpty } }
        }
        return []
    }

    /// The diff of this branch against `base`, for drafting a pull request.
    public static func branchDiff(since base: String, in root: URL, limit: Int = 60_000) async -> String {
        for ref in ["origin/\(base)", base] {
            let stat = await Shell.run(["git", "diff", "--stat", "--no-color", "\(ref)...HEAD"], in: root)
            guard stat.succeeded else { continue }
            let patch = await Shell.run(["git", "diff", "--no-color", "--no-ext-diff", "-U2", "\(ref)...HEAD"], in: root, trimming: false)
            let body = patch.stdout.count > limit ? String(patch.stdout.prefix(limit)) + "\n… (diff truncated)" : patch.stdout
            return stat.stdout + "\n\n" + body
        }
        return ""
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Opens a pull request for the pushed `head` branch and returns its address.
    public static func createPullRequest(title: String, body: String, base: String, head: String, draft: Bool, in root: URL) async throws -> URL {
        var arguments = ["gh", "pr", "create", "--title", title, "--body", body, "--base", base, "--head", head]
        if draft { arguments.append("--draft") }
        let output = await Shell.run(arguments, in: root, extra: ["GH_PROMPT_DISABLED": "1"])
        if let url = pullRequestURL(in: output.stdout) ?? pullRequestURL(in: output.stderr), output.succeeded || output.stderr.contains("already exists") {
            return url
        }
        throw Failure(message: output.message.isEmpty ? "gh couldn’t open the pull request." : output.message)
    }

    /// The last pull request address in gh's output.
    static func pullRequestURL(in output: String) -> URL? {
        output.components(separatedBy: .whitespacesAndNewlines)
            .last { $0.hasPrefix("https://") && $0.contains("/pull/") }
            .flatMap(URL.init(string:))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
