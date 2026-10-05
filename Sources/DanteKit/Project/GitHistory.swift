import Foundation

/// What Home and Ship show about the repository: recent commits, uncommitted changes
/// and the latest tag. Read with the git CLI, so it needs git installed.
public struct GitSnapshot: Equatable, Sendable {
    public struct Commit: Equatable, Sendable, Identifiable {
        public var hash: String
        public var subject: String
        public var date: Date
        public var id: String { hash }

        public init(hash: String, subject: String, date: Date) {
            self.hash = hash
            self.subject = subject
            self.date = date
        }
    }

    public var isRepository = false
    public var recent: [Commit] = []
    /// Files with uncommitted changes, including untracked ones.
    public var changedFiles = 0
    public var latestTag: String?
    /// Commits since `latestTag`, or the whole history without one.
    public var sinceTag: [Commit] = []
    /// Commits not yet pushed to the upstream branch; nil without an upstream.
    public var ahead: Int?

    public init() {}

    /// The field separator in `git log` output. Commit subjects can't contain it.
    static let separator = "\u{1F}"

    public static func load(in root: URL, recentLimit: Int = 8, sinceTagLimit: Int = 400) async -> GitSnapshot {
        var snapshot = GitSnapshot()
        let inside = await Shell.run(["git", "rev-parse", "--is-inside-work-tree"], in: root)
        guard inside.succeeded, inside.stdout == "true" else { return snapshot }
        snapshot.isRepository = true

        async let status = Shell.run(["git", "status", "--porcelain"], in: root)
        async let tag = Shell.run(["git", "describe", "--tags", "--abbrev=0"], in: root)
        async let log = Shell.run(["git", "log", "-\(recentLimit)", "--format=%H\(separator)%ct\(separator)%s"], in: root)
        async let ahead = Shell.run(["git", "rev-list", "--count", "@{upstream}..HEAD"], in: root)

        let statusOutput = await status
        snapshot.changedFiles = statusOutput.succeeded ? statusOutput.stdout.split(separator: "\n").count : 0
        snapshot.recent = parseLog(await log.stdout)
        let aheadOutput = await ahead
        snapshot.ahead = aheadOutput.succeeded ? Int(aheadOutput.stdout) : nil

        let tagOutput = await tag
        snapshot.latestTag = tagOutput.succeeded && !tagOutput.stdout.isEmpty ? tagOutput.stdout : nil
        let range = snapshot.latestTag.map { ["\($0)..HEAD"] } ?? []
        let since = await Shell.run(["git", "log", "-\(sinceTagLimit)", "--no-merges", "--format=%H\(separator)%ct\(separator)%s"] + range, in: root)
        snapshot.sinceTag = parseLog(since.stdout)
        return snapshot
    }

    static func parseLog(_ output: String) -> [Commit] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: separator)
            guard parts.count >= 3, let seconds = TimeInterval(parts[1]) else { return nil }
            return Commit(hash: parts[0], subject: parts[2...].joined(separator: separator), date: Date(timeIntervalSince1970: seconds))
        }
    }
}
