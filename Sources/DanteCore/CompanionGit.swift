import Foundation

/// Version control from the device: the project's repository as the Mac's Changes panel sees
/// it, and what was asked of it. The Mac does the work through the window's own git model, so
/// its panel follows along; network commands never prompt, and one that needs a password says
/// so (`needsPassword`) rather than waiting.
public struct CompanionGit: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        public var oldPath: String?
        /// Git's letter for the staged and unstaged sides (M, A, D, R, ?, U), nil when clean.
        public var staged: String?
        public var unstaged: String?
        public var id: String { path }

        public var isConflicted: Bool { staged == "U" || unstaged == "U" }
        public var isUntracked: Bool { unstaged == "?" }
        public var fileName: String { (path as NSString).lastPathComponent }
        public var folder: String { (path as NSString).deletingLastPathComponent }

        public init(path: String, oldPath: String? = nil, staged: String? = nil, unstaged: String? = nil) {
            self.path = path
            self.oldPath = oldPath
            self.staged = staged
            self.unstaged = unstaged
        }

        /// A word for a letter: "Modified", "Added"…
        public static func label(_ letter: String?) -> String {
            switch letter {
            case "M": "Modified"
            case "A": "Added"
            case "D": "Deleted"
            case "R": "Renamed"
            case "C": "Copied"
            case "T": "Type changed"
            case "?": "New"
            case "U": "Conflict"
            default: "Changed"
            }
        }
    }

    public struct Branch: Codable, Equatable, Sendable, Identifiable {
        public var name: String
        public var isRemote: Bool
        public var isCurrent: Bool
        public var subject: String
        public var date: Date?
        public var id: String { (isRemote ? "remote/" : "") + name }

        public init(name: String, isRemote: Bool = false, isCurrent: Bool = false, subject: String = "", date: Date? = nil) {
            self.name = name
            self.isRemote = isRemote
            self.isCurrent = isCurrent
            self.subject = subject
            self.date = date
        }
    }

    public struct Commit: Codable, Equatable, Sendable, Identifiable {
        public var hash: String
        public var subject: String
        public var date: Date?
        /// Not yet on the upstream.
        public var unpushed: Bool
        public var id: String { hash }

        public init(hash: String, subject: String, date: Date? = nil, unpushed: Bool = false) {
            self.hash = hash
            self.subject = subject
            self.date = date
            self.unpushed = unpushed
        }
    }

    /// One file's diff, cut at `CompanionGit.diffLimit` lines.
    public struct Diff: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case hunk, context, added, removed }
        public struct Line: Codable, Equatable, Sendable {
            public var kind: Kind
            public var text: String
            public var number: Int?
            public init(kind: Kind, text: String, number: Int? = nil) {
                self.kind = kind
                self.text = text
                self.number = number
            }
        }

        public var path: String
        public var staged: Bool
        public var lines: [Line]
        public var isBinary: Bool
        public var truncated: Bool

        public init(path: String, staged: Bool, lines: [Line], isBinary: Bool = false, truncated: Bool = false) {
            self.path = path
            self.staged = staged
            self.lines = lines
            self.isBinary = isBinary
            self.truncated = truncated
        }

        public var added: Int { lines.filter { $0.kind == .added }.count }
        public var removed: Int { lines.filter { $0.kind == .removed }.count }
    }

    /// False for a folder without git; everything else is then empty.
    public var isRepository: Bool
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var changes: [Change]
    public var branches: [Branch]
    public var commits: [Commit]
    /// "merge", "rebase"… stopped on conflicts, which are resolved on the Mac.
    public var operation: String?
    /// The commit message being written on the Mac (or drafted for the device).
    public var message: String
    /// A likely secret in what's about to be committed, or what the writer said instead.
    public var warning: String?
    /// What the last action did ("Pushed main"), or why it failed.
    public var notice: String?
    public var failure: String?
    /// The failure needs a password, which only the Mac's terminal can ask for.
    public var needsPassword: Bool
    public var diff: Diff?

    public init(isRepository: Bool = true, branch: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0,
                changes: [Change] = [], branches: [Branch] = [], commits: [Commit] = [], operation: String? = nil,
                message: String = "", warning: String? = nil, notice: String? = nil, failure: String? = nil,
                needsPassword: Bool = false, diff: Diff? = nil) {
        self.isRepository = isRepository
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
        self.branches = branches
        self.commits = commits
        self.operation = operation
        self.message = message
        self.warning = warning
        self.notice = notice
        self.failure = failure
        self.needsPassword = needsPassword
        self.diff = diff
    }

    public static let diffLimit = 1_500

    public var staged: [Change] { changes.filter { $0.staged != nil && !$0.isConflicted } }
    public var unstaged: [Change] { changes.filter { $0.unstaged != nil && !$0.isConflicted } }
    public var conflicted: [Change] { changes.filter(\.isConflicted) }
    public var localBranches: [Branch] { branches.filter { !$0.isRemote } }

    /// With nothing staged a commit takes every change, as on the Mac.
    public var commitsEverything: Bool { staged.isEmpty }
    public var canCommit: Bool { !changes.isEmpty && conflicted.isEmpty && operation == nil }

    /// "2 to push · 1 to pull", "Up to date", "Not published".
    public var syncSummary: String {
        guard branch != nil else { return "No branch" }
        guard upstream != nil else { return "Not published yet" }
        var parts: [String] = []
        if ahead > 0 { parts.append("\(ahead) to push") }
        if behind > 0 { parts.append("\(behind) to pull") }
        return parts.isEmpty ? "Up to date" : parts.joined(separator: " · ")
    }
}

/// What the device asks of the repository.
public enum CompanionGitAction: Codable, Equatable, Sendable {
    case status
    case diff(path: String, staged: Bool)
    case stage(paths: [String])
    case unstage(paths: [String])
    /// Throws away changes to these files; the device confirms first.
    case discard(paths: [String])
    /// Drafts a message from what will be committed (staging everything when nothing is).
    case writeMessage
    case commit(message: String, push: Bool)
    case push
    case pull
    case fetch
    case checkout(name: String, isRemote: Bool)
    case createBranch(name: String)

    /// Commands that change something, so the Mac reloads its panel afterwards.
    public var changes: Bool {
        switch self {
        case .status, .diff, .fetch: false
        default: true
        }
    }
}
