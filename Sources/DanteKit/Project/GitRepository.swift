import Foundation

/// The working tree as `git status` sees it: the branch, how far it is from its upstream,
/// and each changed file with its staged and unstaged state.
public struct GitStatus: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case modified = "M", added = "A", deleted = "D", renamed = "R", copied = "C"
        case typeChanged = "T", untracked = "?", conflicted = "U"

        public var label: String {
            switch self {
            case .modified: "Modified"
            case .added: "Added"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .copied: "Copied"
            case .typeChanged: "Type changed"
            case .untracked: "Untracked"
            case .conflicted: "Conflict"
            }
        }

        /// The single letter shown beside a file.
        public var letter: String { self == .untracked ? "U" : (self == .conflicted ? "!" : rawValue) }
    }

    public struct Change: Equatable, Sendable, Identifiable {
        public var path: String
        /// The path before a rename or copy.
        public var oldPath: String?
        /// What's in the index compared with HEAD; nil when nothing is staged.
        public var staged: Kind?
        /// What's in the working tree compared with the index; nil when it matches.
        public var unstaged: Kind?
        public var id: String { path }

        public var isConflicted: Bool { staged == .conflicted || unstaged == .conflicted }
        public var isUntracked: Bool { unstaged == .untracked }

        public init(path: String, oldPath: String? = nil, staged: Kind? = nil, unstaged: Kind? = nil) {
            self.path = path
            self.oldPath = oldPath
            self.staged = staged
            self.unstaged = unstaged
        }
    }

    /// nil on a detached HEAD.
    public var branch: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    /// A repository with no commits yet.
    public var isNewRepository = false
    public var changes: [Change] = []

    public init() {}

    public var staged: [Change] { changes.filter { $0.staged != nil && !$0.isConflicted } }
    public var unstaged: [Change] { changes.filter { $0.unstaged != nil && !$0.isConflicted } }
    public var conflicted: [Change] { changes.filter(\.isConflicted) }

    /// Parses `git status --porcelain=v1 --branch -z`.
    public static func parse(_ output: String) -> GitStatus {
        var status = GitStatus()
        var fields = output.components(separatedBy: "\0")[...]
        while let field = fields.popFirst() {
            guard field.count >= 3 else { continue }
            if field.hasPrefix("## ") {
                status.parseBranch(String(field.dropFirst(3)))
                continue
            }
            let x = field[field.startIndex], y = field[field.index(after: field.startIndex)]
            let path = String(field.dropFirst(3))
            var change = Change(path: path)
            if x == "?" && y == "?" {
                change.unstaged = .untracked
            } else if x == "!" {
                continue
            } else if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                change.staged = .conflicted
                change.unstaged = .conflicted
            } else {
                change.staged = x == " " ? nil : Kind(rawValue: String(x))
                change.unstaged = y == " " ? nil : Kind(rawValue: String(y))
            }
            // A rename or copy is followed by the old path in its own field.
            if x == "R" || x == "C" { change.oldPath = fields.popFirst() }
            status.changes.append(change)
        }
        return status
    }

    /// `main...origin/main [ahead 1, behind 2]`, `HEAD (no branch)` or `No commits yet on main`.
    private mutating func parseBranch(_ line: String) {
        var text = line
        if text.hasPrefix("No commits yet on ") {
            isNewRepository = true
            text = String(text.dropFirst("No commits yet on ".count))
        }
        if text.hasPrefix("HEAD (no branch)") { return }
        if let bracket = text.firstIndex(of: "[") {
            let counts = text[bracket...].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            for part in counts.components(separatedBy: ", ") {
                let words = part.split(separator: " ")
                guard words.count == 2, let number = Int(words[1]) else { continue }
                if words[0] == "ahead" { ahead = number } else if words[0] == "behind" { behind = number }
            }
            text = String(text[..<bracket]).trimmingCharacters(in: .whitespaces)
        }
        let parts = text.components(separatedBy: "...")
        branch = parts[0]
        upstream = parts.count > 1 ? parts[1] : nil
    }
}

/// A branch, local or on a remote.
public struct GitBranch: Equatable, Sendable, Identifiable, Hashable {
    public var name: String
    public var isRemote: Bool
    public var isCurrent: Bool
    public var upstream: String?
    public var subject: String
    public var date: Date?
    public var id: String { (isRemote ? "remote/" : "") + name }

    public init(name: String, isRemote: Bool = false, isCurrent: Bool = false, upstream: String? = nil, subject: String = "", date: Date? = nil) {
        self.name = name
        self.isRemote = isRemote
        self.isCurrent = isCurrent
        self.upstream = upstream
        self.subject = subject
        self.date = date
    }

    static let format = "%(refname)%1f%(HEAD)%1f%(upstream:short)%1f%(committerdate:unix)%1f%(subject)"

    /// Parses `git for-each-ref --format=<format> refs/heads refs/remotes`. Remote branches
    /// that a local branch already tracks are left out, as are `origin/HEAD` pointers.
    public static func parse(_ output: String) -> [GitBranch] {
        var branches: [GitBranch] = []
        for line in output.split(separator: "\n") {
            let fields = line.components(separatedBy: "\u{1F}")
            guard fields.count >= 5 else { continue }
            let ref = fields[0]
            let date = Double(fields[3]).map { Date(timeIntervalSince1970: $0) }
            let subject = fields[4...].joined(separator: "\u{1F}")
            if ref.hasPrefix("refs/heads/") {
                branches.append(GitBranch(name: String(ref.dropFirst("refs/heads/".count)), isCurrent: fields[1] == "*",
                                          upstream: fields[2].isEmpty ? nil : fields[2], subject: subject, date: date))
            } else if ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") {
                branches.append(GitBranch(name: String(ref.dropFirst("refs/remotes/".count)), isRemote: true, subject: subject, date: date))
            }
        }
        let tracked = Set(branches.compactMap(\.upstream))
        return branches.filter { !$0.isRemote || !tracked.contains($0.name) }
    }

    /// The local name for checking out a remote branch: `origin/feature/x` → `feature/x`.
    public var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// Whether a new branch name is one git accepts (a cheap version of `check-ref-format`).
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."),
              !name.hasSuffix(".lock"), !name.contains(".."), !name.contains("//"), !name.contains("@{"), name != "@" else { return false }
        return !name.unicodeScalars.contains { $0.value < 0x20 || $0 == "\u{7F}" || " ~^:?*[\\".unicodeScalars.contains($0) }
    }
}

/// One file's diff, split into hunks of lines with their old and new line numbers.
public struct UnifiedDiff: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case context, added, removed }
        public var kind: Kind
        public var text: String
        public var oldNumber: Int?
        public var newNumber: Int?
        public var id: Int
    }

    public struct Hunk: Equatable, Sendable, Identifiable {
        public var header: String
        public var lines: [Line]
        public var id: Int
    }

    public var hunks: [Hunk] = []
    public var isBinary = false

    public var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }

    public init() {}

    public static func parse(_ output: String) -> UnifiedDiff {
        var diff = UnifiedDiff()
        var oldLine = 0, newLine = 0, nextID = 0
        for raw in output.components(separatedBy: "\n") {
            if raw.hasPrefix("Binary files ") { diff.isBinary = true; continue }
            if let match = raw.firstMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/) {
                oldLine = Int(match.1) ?? 0
                newLine = Int(match.2) ?? 0
                diff.hunks.append(Hunk(header: raw, lines: [], id: diff.hunks.count))
                continue
            }
            guard !diff.hunks.isEmpty, let first = raw.first else { continue }
            let text = String(raw.dropFirst())
            let line: Line
            switch first {
            case "+": line = Line(kind: .added, text: text, oldNumber: nil, newNumber: newLine, id: nextID); newLine += 1
            case "-": line = Line(kind: .removed, text: text, oldNumber: oldLine, newNumber: nil, id: nextID); oldLine += 1
            case " ": line = Line(kind: .context, text: text, oldNumber: oldLine, newNumber: newLine, id: nextID); oldLine += 1; newLine += 1
            default: continue // "\ No newline at end of file"
            }
            nextID += 1
            diff.hunks[diff.hunks.count - 1].lines.append(line)
        }
        return diff
    }

    /// An untracked file shown as all added lines.
    public static func added(_ text: String) -> UnifiedDiff {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var diff = UnifiedDiff()
        diff.hunks = [Hunk(header: "@@ -0,0 +1,\(lines.count) @@", lines: lines.enumerated().map {
            Line(kind: .added, text: $0.element, oldNumber: nil, newNumber: $0.offset + 1, id: $0.offset)
        }, id: 0)]
        return diff
    }
}

/// Git commands for the Changes panel and the branch switcher. Each returns git's own
/// message on failure. Network commands never prompt: `needsCredentials` spots the case
/// where they would have, so the caller can offer the terminal instead.
public enum GitRepository {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        /// The command to run in the terminal instead, where git can ask for a password.
        public var terminalCommand: String?
        public var needsCredentials: Bool { Git.needsCredentials(message) }

        public init(message: String, terminalCommand: String? = nil) {
            self.message = message
            self.terminalCommand = terminalCommand
        }
        public var errorDescription: String? { message }
    }

    public static func status(in root: URL) async -> GitStatus? {
        let output = await Shell.run(["git", "status", "--porcelain=v1", "--branch", "-z", "--untracked-files=all"], in: root, trimming: false)
        return output.succeeded ? GitStatus.parse(output.stdout) : nil
    }

    public static func branches(in root: URL) async -> [GitBranch] {
        let output = await Shell.run(["git", "for-each-ref", "--sort=-committerdate", "--format=\(GitBranch.format)", "refs/heads", "refs/remotes"], in: root)
        return output.succeeded ? GitBranch.parse(output.stdout) : []
    }

    /// The diff of one file: what's staged, or what's in the working tree but not staged.
    public static func diff(of change: GitStatus.Change, staged: Bool, in root: URL) async -> UnifiedDiff {
        if !staged, change.isUntracked {
            let url = root.appending(path: change.path)
            guard let data = try? Data(contentsOf: url) else { return UnifiedDiff() }
            guard data.count < 2_000_000, let text = String(data: data, encoding: .utf8) else {
                var binary = UnifiedDiff()
                binary.isBinary = true
                return binary
            }
            return .added(text)
        }
        var arguments = ["git", "diff", "--no-color", "--no-ext-diff", "-U3"]
        if staged { arguments.append("--cached") }
        arguments += ["--", change.path]
        if let old = change.oldPath, staged { arguments.append(old) }
        let output = await Shell.run(arguments, in: root, trimming: false)
        return UnifiedDiff.parse(output.stdout)
    }

    /// Everything staged, for writing a commit message.
    public static func stagedDiff(in root: URL, limit: Int = 60_000) async -> String {
        let stat = await Shell.run(["git", "diff", "--cached", "--stat", "--no-color"], in: root)
        let patch = await Shell.run(["git", "diff", "--cached", "--no-color", "--no-ext-diff", "-U2"], in: root, trimming: false)
        let body = patch.stdout.count > limit ? String(patch.stdout.prefix(limit)) + "\n… (diff truncated)" : patch.stdout
        return stat.stdout + "\n\n" + body
    }

    /// Everything not yet committed, staged or not, with new files listed by name.
    public static func workingDiff(in root: URL, limit: Int = 60_000) async -> String {
        let stat = await Shell.run(["git", "diff", "HEAD", "--stat", "--no-color"], in: root)
        let patch = await Shell.run(["git", "diff", "HEAD", "--no-color", "--no-ext-diff", "-U2"], in: root, trimming: false)
        let untracked = await Shell.run(["git", "ls-files", "--others", "--exclude-standard"], in: root)
        var text = stat.stdout
        if !untracked.stdout.isEmpty { text += "\nNew files:\n" + untracked.stdout }
        let body = patch.stdout.count > limit ? String(patch.stdout.prefix(limit)) + "\n… (diff truncated)" : patch.stdout
        return text + "\n\n" + body
    }

    public static func recentSubjects(in root: URL, count: Int = 12) async -> [String] {
        let output = await Shell.run(["git", "log", "-\(count)", "--format=%s"], in: root)
        return output.succeeded ? output.stdout.components(separatedBy: "\n").filter { !$0.isEmpty } : []
    }

    public static func stage(_ paths: [String], in root: URL) async throws {
        try await git(["add", "-A", "--"] + paths, in: root)
    }

    public static func stageAll(in root: URL) async throws {
        try await git(["add", "-A"], in: root)
    }

    public static func unstage(_ paths: [String], in root: URL, newRepository: Bool) async throws {
        if newRepository {
            try await git(["rm", "--cached", "-r", "-q", "--"] + paths, in: root)
        } else {
            try await git(["reset", "-q", "HEAD", "--"] + paths, in: root)
        }
    }

    /// Throws away unstaged changes. Untracked files go to the Trash rather than being deleted.
    public static func discard(_ changes: [GitStatus.Change], in root: URL) async throws {
        let untracked = changes.filter(\.isUntracked)
        let tracked = changes.filter { !$0.isUntracked }.map(\.path)
        for change in untracked {
            try FileManager.default.trashItem(at: root.appending(path: change.path), resultingItemURL: nil)
        }
        if !tracked.isEmpty { try await git(["checkout", "--"] + tracked, in: root) }
    }

    public static func commit(message: String, amend: Bool = false, in root: URL) async throws {
        var arguments = ["commit", "-q", "-m", message]
        if amend { arguments.append("--amend") }
        try await git(arguments, in: root)
    }

    /// Pushes the current branch, setting its upstream on the first push.
    public static func push(branch: String, hasUpstream: Bool, in root: URL) async throws {
        if hasUpstream {
            try await git(["push"], in: root, network: true)
        } else {
            let remote = await Shell.run(["git", "remote"], in: root).stdout.components(separatedBy: "\n").first { !$0.isEmpty }
            guard let remote else { throw Failure(message: "This repository has no remote to push to. Add one with `git remote add origin <url>`.") }
            try await git(["push", "-u", remote, branch], in: root, network: true)
        }
    }

    /// Pulls with fast-forward only, so a pull never leaves a merge to sort out by surprise.
    public static func pull(in root: URL) async throws {
        try await git(["pull", "--ff-only"], in: root, network: true)
    }

    public static func fetch(in root: URL) async throws {
        try await git(["fetch", "--all", "--prune"], in: root, network: true)
    }

    public static func checkout(_ branch: GitBranch, in root: URL) async throws {
        if branch.isRemote {
            try await git(["checkout", "-q", "--track", branch.name], in: root)
        } else {
            try await git(["checkout", "-q", branch.name], in: root)
        }
    }

    public static func createBranch(_ name: String, in root: URL) async throws {
        try await git(["checkout", "-q", "-b", name], in: root)
    }

    private static func git(_ arguments: [String], in root: URL, network: Bool = false) async throws {
        var extra: [String: String] = [:]
        if network {
            // Fail rather than wait on an SSH passphrase or host-key prompt nobody can see.
            extra["GIT_SSH_COMMAND"] = ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] ?? "ssh -o BatchMode=yes"
        }
        let output = await Shell.run(["git"] + arguments, in: root, extra: extra)
        guard output.succeeded else {
            let message = [output.stderr, output.stdout].first { !$0.isEmpty } ?? "git \(arguments.first ?? "") failed."
            throw Failure(message: message.replacingOccurrences(of: "\nhint: ", with: "\n").replacingOccurrences(of: "hint: ", with: ""),
                          terminalCommand: network ? (["git"] + arguments).joined(separator: " ") : nil)
        }
    }
}
