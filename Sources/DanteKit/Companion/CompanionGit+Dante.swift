import Foundation

/// The device's view of a repository, made from what the Changes panel reads (pure, tested).
extension CompanionGit {
    public static func make(status: GitStatus?, branches: [GitBranch], commits: [Commit], operation: String?,
                            message: String, warning: String?, notice: String?, failure: GitRepository.Failure?,
                            diff: Diff? = nil) -> CompanionGit {
        guard let status else { return CompanionGit(isRepository: false) }
        return CompanionGit(
            branch: status.branch, upstream: status.upstream, ahead: status.ahead, behind: status.behind,
            changes: status.changes.map { Change(path: $0.path, oldPath: $0.oldPath, staged: $0.staged?.rawValue, unstaged: $0.unstaged?.rawValue) },
            // Local branches first, then the remote ones not checked out here; HEAD aliases left out.
            branches: branches.filter { !$0.name.hasSuffix("/HEAD") }
                .sorted { ($0.isRemote ? 1 : 0, $0.isCurrent ? 0 : 1) < ($1.isRemote ? 1 : 0, $1.isCurrent ? 0 : 1) }
                .map { Branch(name: $0.name, isRemote: $0.isRemote, isCurrent: $0.isCurrent, subject: $0.subject, date: $0.date) },
            commits: commits.enumerated().map { index, commit in
                var marked = commit
                marked.unpushed = status.upstream != nil && index < status.ahead
                return marked
            },
            operation: operation, message: message, warning: warning, notice: notice,
            failure: failure?.message, needsPassword: failure?.needsCredentials ?? false, diff: diff)
    }

    /// A unified diff for the device, numbered by the new side (the old one for removals).
    public static func diff(_ unified: UnifiedDiff, path: String, staged: Bool) -> Diff {
        var lines: [Diff.Line] = []
        var truncated = false
        for hunk in unified.hunks {
            if lines.count >= diffLimit { truncated = true; break }
            lines.append(.init(kind: .hunk, text: hunk.header))
            for line in hunk.lines {
                if lines.count >= diffLimit { truncated = true; break }
                switch line.kind {
                case .context: lines.append(.init(kind: .context, text: line.text, number: line.newNumber))
                case .added: lines.append(.init(kind: .added, text: line.text, number: line.newNumber))
                case .removed: lines.append(.init(kind: .removed, text: line.text, number: line.oldNumber))
                }
            }
        }
        return Diff(path: path, staged: staged, lines: lines, isBinary: unified.isBinary, truncated: truncated)
    }

    /// `git log` lines written with `commitFormat`.
    public static func parseCommits(_ output: String) -> [Commit] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, !parts[0].isEmpty else { return nil }
            return Commit(hash: parts[0], subject: parts[1], date: Double(parts[2]).map { Date(timeIntervalSince1970: $0) })
        }
    }

    public static let commitFormat = "%h%x1f%s%x1f%ct"

    /// The branch's latest commits, newest first.
    public static func recentCommits(in root: URL, count: Int = 20) async -> [Commit] {
        let output = await Shell.run(["git", "log", "-\(count)", "--format=\(commitFormat)"], in: root)
        return output.succeeded ? parseCommits(output.stdout) : []
    }
}
