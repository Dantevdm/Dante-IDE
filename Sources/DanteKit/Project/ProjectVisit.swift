import Foundation

/// What a project looked like when Dante last closed it, kept per Mac in user defaults:
/// when, the commit HEAD was on, and each task's state.
public struct ProjectVisit: Codable, Equatable, Sendable {
    public var date: Date
    public var head: String?
    public var branch: String?
    public var taskStates: [String: TaskState]

    public init(date: Date, head: String?, branch: String?, taskStates: [String: TaskState]) {
        self.date = date
        self.head = head
        self.branch = branch
        self.taskStates = taskStates
    }

    static let key = "projectVisits"

    public static func load(for root: URL, defaults: UserDefaults = .standard) -> ProjectVisit? {
        guard let data = defaults.dictionary(forKey: key)?[root.standardizedFileURL.path] as? Data else { return nil }
        return try? JSONDecoder().decode(ProjectVisit.self, from: data)
    }

    public func save(for root: URL, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        var all = defaults.dictionary(forKey: Self.key) ?? [:]
        all[root.standardizedFileURL.path] = data
        defaults.set(all, forKey: Self.key)
    }

    /// The project as it is now. Reads `.git` directly, so it's quick enough for quitting.
    public static func now(root: URL, tasks: [PlanTask]) -> ProjectVisit {
        ProjectVisit(
            date: Date(),
            head: Git.headCommit(in: root),
            branch: Git.currentBranch(in: root),
            taskStates: Dictionary(tasks.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        )
    }
}

/// What changed between the last visit and now, for Home.
public struct SinceLastVisit: Equatable, Sendable {
    public struct Commit: Equatable, Sendable, Identifiable {
        public var hash: String
        public var subject: String
        public var author: String
        public var date: Date?
        public var id: String { hash }
    }

    public struct TaskMove: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// Nil for a task that's new since then.
        public var from: TaskState?
        public var to: TaskState
    }

    public var since: Date
    public var commits: [Commit] = []
    /// More commits than are listed.
    public var moreCommits = 0
    public var filesChanged = 0
    public var insertions = 0
    public var deletions = 0
    public var taskMoves: [TaskMove] = []
    public struct BranchChange: Equatable, Sendable {
        public var from: String
        public var to: String
    }
    public var branchChange: BranchChange?

    public init(since: Date) {
        self.since = since
    }

    public var isEmpty: Bool {
        commits.isEmpty && taskMoves.isEmpty && filesChanged == 0 && branchChange == nil
    }

    /// Tasks that are new or in a different state, in board order.
    /// No tasks recorded last time (none yet, or the file couldn't be read) means there's
    /// nothing to compare with, rather than every task being new.
    public static func taskMoves(from previous: [String: TaskState], to tasks: [PlanTask]) -> [TaskMove] {
        guard !previous.isEmpty else { return [] }
        return tasks.compactMap { task in
            let before = previous[task.id]
            guard before != task.state else { return nil }
            return TaskMove(id: task.id, title: task.title, from: before, to: task.state)
        }
    }

    /// Compares the repository and tasks with `visit`. Commits are those reachable from HEAD
    /// and not from the old HEAD; if that commit is gone, those made since the visit.
    @MainActor
    public static func load(since visit: ProjectVisit, root: URL, tasks: [PlanTask], limit: Int = 8) async -> SinceLastVisit {
        var result = SinceLastVisit(since: visit.date)
        result.taskMoves = taskMoves(from: visit.taskStates, to: tasks)
        let branch = Git.currentBranch(in: root)
        if let before = visit.branch, let branch, before != branch { result.branchChange = BranchChange(from: before, to: branch) }

        let format = "--format=%H%x1f%s%x1f%an%x1f%cI"
        var range = ["--since=\(ISO8601DateFormatter().string(from: visit.date))", "HEAD"]
        if let head = visit.head, await Shell.run(["git", "cat-file", "-e", "\(head)^{commit}"], in: root).succeeded {
            range = ["\(head)..HEAD"]
            let stat = await Shell.run(["git", "diff", "--shortstat", head, "HEAD"], in: root)
            (result.filesChanged, result.insertions, result.deletions) = parseShortStat(stat.stdout)
        }
        let log = await Shell.run(["git", "log", format] + range, in: root)
        let commits = parseLog(log.stdout)
        result.commits = Array(commits.prefix(limit))
        result.moreCommits = max(commits.count - limit, 0)
        return result
    }

    static func parseLog(_ output: String) -> [Commit] {
        let formatter = ISO8601DateFormatter()
        return output.components(separatedBy: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1F}")
            guard fields.count == 4 else { return nil }
            return Commit(hash: fields[0], subject: fields[1], author: fields[2], date: formatter.date(from: fields[3]))
        }
    }

    /// " 3 files changed, 10 insertions(+), 2 deletions(-)"
    static func parseShortStat(_ output: String) -> (files: Int, insertions: Int, deletions: Int) {
        func number(before word: String) -> Int {
            guard let range = output.range(of: word) else { return 0 }
            let digits = output[..<range.lowerBound].reversed().drop { $0 == " " }.prefix { $0.isNumber }
            return Int(String(digits.reversed())) ?? 0
        }
        return (number(before: " file"), number(before: " insertion"), number(before: " deletion"))
    }
}
