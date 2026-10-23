import Foundation

/// A piece of work handed to an agent that runs beside the main conversation: its own Claude
/// Code (or Codex) session in its own git worktree and branch, so jobs never edit the same
/// checkout as you or each other. Records are kept per project on this Mac, never in the repo.
public struct JobRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// Still being worked on, or waiting to be merged.
        case open
        /// Merged into the main checkout; the worktree is gone.
        case merged
        /// Thrown away with its worktree and branch.
        case discarded
    }

    public var id: String
    public var title: String
    /// What the job was asked to do, as written.
    public var brief: String
    public var branch: String
    /// The worktree's folder.
    public var worktree: String
    /// The commit the job started from.
    public var base: String
    /// The branch checked out in the main checkout when the job started.
    public var baseBranch: String?
    public var engine: AgentEngine
    public var created: Date
    /// The agent's conversation, so a job can be picked up again after Dante restarts.
    public var conversationID: String?
    public var outcome: Outcome
    public var closed: Date?
    /// Away mode: how long the job may go ahead without asking, from `awaySince`. nil asks
    /// as the window's approval level says.
    public var awayMinutes: Int?
    public var awaySince: Date?
    /// Away mode's other limits: how many steps may go ahead without asking, and how many
    /// output tokens its turns may use (a share of the plan's five-hour window). nil: no limit.
    public var awaySteps: Int?
    public var awayStepsUsed: Int?
    public var awayTokens: Int?
    public var awayTokensUsed: Int?
    /// The job type's id (`JobType`), when it was started as one.
    public var kind: String?
    /// What started it by itself, such as a failed CI run (`JobTrigger.ci`).
    public var trigger: String?
    /// The type's `paths`: edits elsewhere wait for the person.
    public var scope: [String]?
    /// The type's `commands`: more commands it may run while away.
    public var commands: [String]?

    public init(id: String = JobRecord.newID(), title: String, brief: String, branch: String, worktree: String, base: String,
                baseBranch: String?, engine: AgentEngine, created: Date = Date(), conversationID: String? = nil,
                outcome: Outcome = .open, closed: Date? = nil) {
        self.id = id
        self.title = title
        self.brief = brief
        self.branch = branch
        self.worktree = worktree
        self.base = base
        self.baseBranch = baseBranch
        self.engine = engine
        self.created = created
        self.conversationID = conversationID
        self.outcome = outcome
        self.closed = closed
    }

    public var worktreeURL: URL { URL(filePath: worktree, directoryHint: .isDirectory) }

    public var isAway: Bool { awayMinutes != nil }

    /// When away mode's time runs out.
    public var awayUntil: Date? {
        guard let awayMinutes, let awaySince else { return nil }
        return awaySince.addingTimeInterval(TimeInterval(awayMinutes * 60))
    }

    /// What ended away mode, if something has: its time, its steps or its tokens.
    public enum AwayEnd: String, Equatable, Sendable {
        case time, steps, tokens

        public var sentence: String {
            switch self {
            case .time: "Away time’s up"
            case .steps: "Away steps used up"
            case .tokens: "Away share of the plan used up"
            }
        }
    }

    public func awayEnded(at now: Date = Date()) -> AwayEnd? {
        guard isAway else { return nil }
        if let until = awayUntil, now >= until { return .time }
        if let steps = awaySteps, (awayStepsUsed ?? 0) >= steps { return .steps }
        if let tokens = awayTokens, (awayTokensUsed ?? 0) >= tokens { return .tokens }
        return nil
    }

    /// Away mode has run out (time, steps or tokens): from here on every step waits for the person.
    public func outOfTime(at now: Date = Date()) -> Bool {
        awayEnded(at: now) != nil
    }

    /// Goes away for `minutes` from now, with at most `steps` steps going ahead and `tokens`
    /// output tokens; nil comes back to asking. The counts start again each time.
    public mutating func setAway(_ minutes: Int?, steps: Int? = nil, tokens: Int? = nil, now: Date = Date()) {
        awayMinutes = minutes
        awaySince = minutes == nil ? nil : now
        awaySteps = minutes == nil ? nil : steps
        awayTokens = minutes == nil ? nil : tokens
        awayStepsUsed = minutes == nil ? nil : 0
        awayTokensUsed = minutes == nil ? nil : 0
    }

    /// Steps per minute away by default: enough for real work, not for a loop to spin all hour.
    public static let stepsPerMinute = 4

    public mutating func countAwayStep() {
        guard isAway else { return }
        awayStepsUsed = (awayStepsUsed ?? 0) + 1
    }

    public mutating func countAwayTokens(_ tokens: Int) {
        guard isAway, tokens > 0 else { return }
        awayTokensUsed = (awayTokensUsed ?? 0) + tokens
    }

    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}

/// Naming and briefing a new job.
public enum JobPlan {
    /// A short title from what the job was asked: the first sentence of the first line.
    public static func title(from brief: String) -> String {
        let line = brief.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        var sentence = line
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            sentence = String(line[..<end.lowerBound])
        }
        sentence = sentence.trimmingCharacters(in: CharacterSet(charactersIn: " .:;,!?"))
        guard sentence.count > 60 else { return sentence.isEmpty ? "Job" : sentence }
        // Cut at a word, not mid-word.
        let cut = sentence.prefix(60)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(atWord) + "…"
    }

    /// A branch-safe name: lowercase words joined by hyphens, at most five words.
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.prefix(5)
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? "job" : String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `dante/<slug>`, numbered when the name is taken by a branch or another job's folder.
    public static func branch(for slug: String, taken: Set<String>) -> String {
        let name = "dante/\(slug)"
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name)-\(number)") { number += 1 }
        return "\(name)-\(number)"
    }

    /// Where a project's job worktrees live: Application Support, out of the repo and out of
    /// the project's file watcher.
    public static func folder(for root: URL, in base: URL = defaultFolder()) -> URL {
        let path = root.standardizedFileURL.path
        return base.appending(path: "\(root.lastPathComponent)-\(String(SemanticIndex.hash(path), radix: 16).prefix(8))", directoryHint: .isDirectory)
    }

    public static func defaultFolder() -> URL {
        URL.applicationSupportDirectory.appending(path: "Dante/worktrees", directoryHint: .isDirectory)
    }

    /// The worktree's folder: the branch's last part, which is unique among the project's jobs.
    public static func worktree(branch: String, in folder: URL) -> URL {
        folder.appending(path: branch.split(separator: "/").last.map(String.init) ?? branch, directoryHint: .isDirectory)
    }

    /// A tool call's target as it reads in a job: commands usually start by changing into the
    /// worktree, which says nothing, so that part goes.
    public static func shortened(_ target: String, worktree: String) -> String {
        for prefix in ["cd \"\(worktree)\" && ", "cd \(Shell.quote(worktree)) && ", "cd \(worktree) && "] where target.hasPrefix(prefix) {
            return String(target.dropFirst(prefix.count))
        }
        return target
    }

    /// What the job's agent is told on top of the project's usual brief.
    public static func brief(for job: JobRecord, project: String) -> String {
        """
        You're working on a job for \(project), handed to you by the person using Dante: "\(job.title)". \
        You run in your own git worktree at \(job.worktree), on the branch \(job.branch), which started from \
        \(job.baseBranch.map { "\($0) at " } ?? "")\(job.base.prefix(8)). Other jobs and the person may be working \
        in other checkouts at the same time, so change files only inside this worktree. When the work is done, \
        commit it on this branch with a clear message. Don't push, merge, rebase or switch branches: Dante merges \
        the branch when the person accepts it. Finish with a short summary of what changed, how you checked it, \
        and anything left to do.
        """
    }
}

/// How a job is doing, from its record and its conversation.
public enum JobPhase: Equatable, Sendable {
    /// The worktree is being made.
    case starting
    case working
    /// Edits or commands waiting for approval.
    case waiting(Int)
    /// The agent asked a question.
    case asking
    /// The turn ended: the work is ready to look at.
    case ready
    /// Not running: Dante restarted, or the agent was stopped. The next message resumes it.
    case paused
    case failed(String)
    case merged
    case discarded

    public static func of(outcome: JobRecord.Outcome, live: Bool, working: Bool, failure: String?,
                          pending: [ToolActivity], replied: Bool) -> JobPhase {
        switch outcome {
        case .merged: return .merged
        case .discarded: return .discarded
        case .open: break
        }
        if let failure { return .failed(failure) }
        if pending.contains(where: { $0.name == "AskUserQuestion" }) { return .asking }
        if !pending.isEmpty { return .waiting(pending.count) }
        if working { return .working }
        guard live else { return .paused }
        return replied ? .ready : .starting
    }

    /// Needs the person: something to approve, answer or look at.
    public var needsYou: Bool {
        switch self {
        case .waiting, .asking, .ready, .failed: true
        default: false
        }
    }

    public var isActive: Bool {
        switch self {
        case .starting, .working, .waiting, .asking: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .waiting(let count): count == 1 ? "1 waiting" : "\(count) waiting"
        case .asking: "Has a question"
        case .ready: "Ready to review"
        case .paused: "Paused"
        case .failed: "Stopped"
        case .merged: "Merged"
        case .discarded: "Discarded"
        }
    }
}

/// What a job has changed against where it started: committed and not.
public struct JobChanges: Equatable, Sendable {
    public var files = 0
    public var insertions = 0
    public var deletions = 0
    /// New files git doesn't track yet.
    public var untracked = 0
    public var commits = 0
    /// Edits not committed yet.
    public var uncommitted = false

    public init(files: Int = 0, insertions: Int = 0, deletions: Int = 0, untracked: Int = 0, commits: Int = 0, uncommitted: Bool = false) {
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
        self.untracked = untracked
        self.commits = commits
        self.uncommitted = uncommitted
    }

    public var isEmpty: Bool { files == 0 && untracked == 0 && commits == 0 }

    /// Reads `git diff --shortstat`: " 3 files changed, 10 insertions(+), 2 deletions(-)".
    public static func shortstat(_ line: String) -> (files: Int, insertions: Int, deletions: Int) {
        func number(before word: String) -> Int {
            guard let range = line.range(of: #"(\d+) \#(word)"#, options: .regularExpression) else { return 0 }
            return Int(line[range].prefix { $0.isNumber }) ?? 0
        }
        return (number(before: "files? changed"), number(before: "insertions?"), number(before: "deletions?"))
    }

    /// Reads `git status --porcelain` for untracked files and whether anything is uncommitted.
    public static func status(_ porcelain: String) -> (untracked: Int, dirty: Bool) {
        let lines = porcelain.split(separator: "\n").filter { !$0.isEmpty }
        return (lines.filter { $0.hasPrefix("??") }.count, !lines.isEmpty)
    }

    public var summary: String {
        if isEmpty { return "No changes yet" }
        var parts: [String] = []
        let total = files + untracked
        parts.append(total == 1 ? "1 file" : "\(total) files")
        if insertions > 0 || deletions > 0 { parts.append("+\(insertions) −\(deletions)") }
        if commits > 0 { parts.append(commits == 1 ? "1 commit" : "\(commits) commits") }
        if uncommitted { parts.append("not committed") }
        return parts.joined(separator: " · ")
    }
}

/// Every conversation's questions and approvals in one list, oldest first.
public enum JobInbox {
    public struct Item: Identifiable, Equatable, Sendable {
        /// The job, or nil for the window's main conversation.
        public var job: String?
        /// The job's title, or "Main conversation".
        public var from: String
        public var tool: ToolActivity
        public var id: String { "\(job ?? "main")/\(tool.id)" }
        public var isQuestion: Bool { tool.name == "AskUserQuestion" }
        public var isEdit: Bool { tool.change != nil }
    }

    public struct Source: Sendable {
        public var job: String?
        public var title: String
        public var pending: [ToolActivity]

        public init(job: String?, title: String, pending: [ToolActivity]) {
            self.job = job
            self.title = title
            self.pending = pending
        }
    }

    public static func items(_ sources: [Source]) -> [Item] {
        sources.flatMap { source in source.pending.map { Item(job: source.job, from: source.title, tool: $0) } }
    }
}

/// A project's job records on this Mac.
public enum JobStore {
    public static func url(for root: URL, in folder: URL = defaultFolder()) -> URL {
        let path = root.standardizedFileURL.path
        return folder.appending(path: "\(root.lastPathComponent)-\(String(SemanticIndex.hash(path), radix: 16)).json")
    }

    public static func defaultFolder() -> URL {
        URL.applicationSupportDirectory.appending(path: "Dante/jobs", directoryHint: .isDirectory)
    }

    public static func load(for root: URL, in folder: URL = defaultFolder()) -> [JobRecord] {
        guard let data = try? Data(contentsOf: url(for: root, in: folder)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([JobRecord].self, from: data)) ?? []
    }

    /// What to write when one window saves: the records on disk (another window on the same
    /// project may have added some) with this window's versions in their place, without the
    /// ones it forgot, keeping every open job and the newest `keepClosed` finished ones.
    public static func merged(disk: [JobRecord], mine: [JobRecord], forgotten: Set<String>, keepClosed: Int = 30) -> [JobRecord] {
        var byID = Dictionary(disk.map { ($0.id, $0) }) { a, _ in a }
        for record in mine { byID[record.id] = record }
        let all = byID.values.filter { !forgotten.contains($0.id) }
        let open = all.filter { $0.outcome == .open }
        let closed = all.filter { $0.outcome != .open }.sorted { ($0.closed ?? $0.created) > ($1.closed ?? $1.created) }.prefix(keepClosed)
        return (open + closed).sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }

    public static func save(_ jobs: [JobRecord], for root: URL, in folder: URL = defaultFolder()) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(jobs).write(to: url(for: root, in: folder), options: .atomic)
    }
}

/// The git side of a job: making its worktree, counting its changes, merging and discarding it.
public enum JobWorktree {
    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Makes a worktree on a new branch from the main checkout's HEAD, and a record for it.
    public static func create(title: String, brief: String, engine: AgentEngine, repo: URL,
                              folder: URL? = nil) async throws -> JobRecord {
        guard let base = await git(["rev-parse", "HEAD"], in: repo).nonEmpty else {
            throw Failure(message: "The project has no commits yet, so a job has nothing to start from.")
        }
        let baseBranch = await git(["rev-parse", "--abbrev-ref", "HEAD"], in: repo).nonEmpty.flatMap { $0 == "HEAD" ? nil : $0 }
        let branches = await git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repo)
        let jobsFolder = folder ?? JobPlan.folder(for: repo)
        var taken = Set(branches.split(separator: "\n").map(String.init))
        // A folder left from an earlier job takes the name too.
        if let leftovers = try? FileManager.default.contentsOfDirectory(atPath: jobsFolder.path) {
            taken.formUnion(leftovers.map { "dante/\($0)" })
        }
        let branch = JobPlan.branch(for: JobPlan.slug(title), taken: taken)
        let path = JobPlan.worktree(branch: branch, in: jobsFolder)
        try FileManager.default.createDirectory(at: jobsFolder, withIntermediateDirectories: true)
        let added = await Shell.run(["git", "worktree", "add", "-b", branch, path.path, base], in: repo)
        guard added.succeeded else { throw Failure(message: "Couldn’t make the job’s worktree: \(added.message)") }
        return JobRecord(title: title, brief: brief, branch: branch, worktree: path.path, base: base,
                         baseBranch: baseBranch, engine: engine)
    }

    public static func changes(of job: JobRecord) async -> JobChanges {
        let root = job.worktreeURL
        guard FileManager.default.fileExists(atPath: root.path) else { return JobChanges() }
        // Against the start, so committed and uncommitted edits both count.
        let stat = JobChanges.shortstat(await git(["diff", "--shortstat", job.base], in: root))
        let status = JobChanges.status(await git(["status", "--porcelain"], in: root))
        let commits = Int(await git(["rev-list", "--count", "\(job.base)..HEAD"], in: root)) ?? 0
        return JobChanges(files: stat.files, insertions: stat.insertions, deletions: stat.deletions,
                          untracked: status.untracked, commits: commits, uncommitted: status.dirty)
    }

    /// Commits what the job left uncommitted, then merges its branch into whatever the main
    /// checkout has out, and removes the worktree. Git refuses when the merge would touch
    /// files with uncommitted edits in the main checkout, and nothing is lost.
    public static func merge(_ job: JobRecord, into repo: URL) async throws {
        let root = job.worktreeURL
        if FileManager.default.fileExists(atPath: root.path),
           JobChanges.status(await git(["status", "--porcelain"], in: root)).dirty {
            _ = await Shell.run(["git", "add", "-A"], in: root)
            let committed = await Shell.run(["git", "commit", "-q", "-m", job.title], in: root)
            guard committed.succeeded else { throw Failure(message: "Couldn’t commit the job’s last edits: \(committed.message)") }
        }
        let merged = await Shell.run(["git", "merge", "--no-ff", "--no-edit", "-m", "Merge \(job.branch)", "-m", job.title, job.branch], in: repo)
        guard merged.succeeded else {
            let conflicted = await git(["diff", "--name-only", "--diff-filter=U"], in: repo)
            if !conflicted.isEmpty {
                throw Failure(message: "The merge has conflicts in \(conflicted.split(separator: "\n").count) file(s). Resolve them in Changes, or abort the merge there.")
            }
            throw Failure(message: "Git didn’t merge \(job.branch): \(merged.message)")
        }
        await removeWorktree(job, repo: repo, deleteBranch: true, force: false)
    }

    /// Removes the worktree, and the branch when asked (a discarded job's work goes with it).
    public static func removeWorktree(_ job: JobRecord, repo: URL, deleteBranch: Bool, force: Bool) async {
        if FileManager.default.fileExists(atPath: job.worktree) {
            _ = await Shell.run(["git", "worktree", "remove"] + (force ? ["--force"] : []) + [job.worktree], in: repo)
        }
        _ = await Shell.run(["git", "worktree", "prune"], in: repo)
        if deleteBranch {
            _ = await Shell.run(["git", "branch", force ? "-D" : "-d", job.branch], in: repo)
        }
    }

    private static func git(_ arguments: [String], in directory: URL) async -> String {
        let output = await Shell.run(["git"] + arguments, in: directory)
        return output.succeeded ? output.stdout : ""
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// What a job's steps came to, for its card: how many went ahead, which commands ran and
/// failed (the command's own error) apart from which Dante refused before they ran (a rule),
/// and how many wait for the person.
public struct JobStepReport: Equatable, Sendable {
    public struct Step: Equatable, Sendable, Identifiable {
        public var id: String
        public var what: String
        public var why: String
    }

    public var done = 0
    public var failed: [Step] = []
    public var refused: [Step] = []
    public var waiting = 0

    public init(_ items: [TranscriptItem]) {
        for item in items {
            guard case .tool(let tool) = item.content else { continue }
            let what = tool.name == "Bash" ? (tool.input["command"]?.string ?? "a command") : ClaudeSession.attentionLabel(tool.name, input: tool.input)
            switch tool.status {
            case .done: done += 1
            case .failed(let message):
                failed.append(Step(id: tool.id, what: what, why: Self.firstLine(message)))
            case .declined where tool.blockedByRule:
                refused.append(Step(id: tool.id, what: what, why: tool.ruleNote ?? "A rule for jobs."))
            case .awaitingApproval: waiting += 1
            default: break
            }
        }
    }

    public var isEmpty: Bool { done == 0 && failed.isEmpty && refused.isEmpty && waiting == 0 }

    /// "14 steps done · 2 failed · 1 refused · 1 waiting for you"
    public var summary: String {
        var parts = ["\(done) step\(done == 1 ? "" : "s") done"]
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        if !refused.isEmpty { parts.append("\(refused.count) refused") }
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        return parts.joined(separator: " · ")
    }

    static func firstLine(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // An exit code line says less than the error before it.
        let line = lines.first { !$0.lowercased().hasPrefix("exit code") } ?? lines.first ?? ""
        return String(line.prefix(160))
    }
}
