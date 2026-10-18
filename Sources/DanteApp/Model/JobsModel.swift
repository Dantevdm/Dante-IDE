import DanteKit
import Foundation
import Observation

/// One window's jobs: agents working beside the main conversation, each in its own worktree.
/// Records are saved per project on this Mac; a job's conversation runs while the window is
/// open and is resumed when you go back to it after a restart.
@MainActor
@Observable
final class JobsModel {
    private(set) var records: [JobRecord] = []
    private(set) var sessions: [String: ClaudeSession] = [:]
    private(set) var changes: [String: JobChanges] = [:]
    private(set) var failures: [String: String] = [:]
    /// The title of a job whose worktree is being made.
    private(set) var starting: String?
    /// Jobs being merged or discarded.
    private(set) var busy: Set<String> = []
    /// Why jobs can't run in this project, if they can't.
    private(set) var unavailable: String?
    private(set) var root: URL?

    /// Makes a job's conversation; set by the window, which knows the project's brief and rules.
    @ObservationIgnored var makeSession: ((JobRecord) -> ClaudeSession)?
    /// A job's away time ran out; the window tells the person.
    @ObservationIgnored var onAwayTimeUp: ((JobRecord) -> Void)?
    /// Jobs whose away time was already reported as up.
    @ObservationIgnored private var reportedTimeUp: Set<String> = []
    @ObservationIgnored private var clock: Task<Void, Never>?
    /// Ticks while any job is away, so the board's countdowns and time-up states move.
    private(set) var now = Date()

    /// The project's job types: `.dante/jobs/` and the built-in ones.
    private(set) var types: [JobType] = []
    /// Types that start by themselves which this Mac lets start, by id.
    private(set) var watching: Set<String> = []
    /// The type chosen in the New job form (the board's Start buttons set it).
    var draftType: String?
    /// The task chosen for a type that works from one.
    var draftTask: String?
    /// Why CI can't be watched, if it can't.
    private(set) var ciProblem: String?
    /// When the CI watch last looked.
    private(set) var ciChecked: Date?
    /// The branch checked out in the main checkout; the CI watch follows it.
    @ObservationIgnored var currentBranch: (() -> String?)?
    /// A job started by itself, from a trigger.
    @ObservationIgnored var onTriggered: ((JobRecord) -> Void)?
    @ObservationIgnored private var ciWatch: Task<Void, Never>?
    /// Runs already finished when the watch began, so old failures aren't news.
    @ObservationIgnored private var ciBaseline: Set<Int>?

    var open: [JobRecord] { records.filter { $0.outcome == .open } }
    /// Finished jobs, newest first, for the board's history.
    var closed: [JobRecord] { records.filter { $0.outcome != .open }.sorted { ($0.closed ?? $0.created) > ($1.closed ?? $1.created) } }

    func record(_ id: String) -> JobRecord? { records.first { $0.id == id } }

    func load(root: URL, remote: Bool) {
        stopAll()
        self.root = root
        sessions = [:]
        changes = [:]
        failures = [:]
        if remote {
            unavailable = "Jobs run on this Mac only for now, and this project lives on another host."
            records = []
            return
        }
        unavailable = FileManager.default.fileExists(atPath: root.appending(path: ".git").path) ? nil
            : "Jobs need a git repository: each one works on its own branch."
        // Keep only jobs whose worktree is still there; a missing one was removed by hand.
        records = JobStore.load(for: root).filter { $0.outcome != .open || FileManager.default.fileExists(atPath: $0.worktree) }
        // Time already up when the project opened isn't news.
        reportedTimeUp = Set(open.filter { $0.outOfTime() }.map(\.id))
        if open.contains(where: \.isAway) { watchTime() }
        watching = Self.savedWatching[root.standardizedFileURL.path].map(Set.init) ?? []
        reloadTypes()
        Task { await refreshChanges() }
    }

    // MARK: Job types

    func type(_ id: String?) -> JobType? { id.flatMap { id in types.first { $0.id == id } } }

    /// Reads `.dante/jobs/` again (the board does on every change in the project).
    func reloadTypes() {
        guard let root else { return }
        types = JobType.load(projectRoot: root)
        updateCIWatch()
    }

    var watchedTypes: [JobType] {
        unavailable == nil ? types.filter { $0.trigger == .ciFailed && watching.contains($0.id) } : []
    }

    /// Lets a type that starts by itself do so in this project on this Mac, or stops it.
    func setWatching(_ id: String, _ on: Bool) {
        guard let root else { return }
        if on { watching.insert(id) } else { watching.remove(id) }
        var saved = Self.savedWatching
        saved[root.standardizedFileURL.path] = watching.isEmpty ? nil : watching.sorted()
        UserDefaults.standard.set(saved, forKey: Self.watchingKey)
        updateCIWatch()
    }

    private static let watchingKey = "jobTypesWatching"
    private static var savedWatching: [String: [String]] {
        (UserDefaults.standard.dictionary(forKey: watchingKey) as? [String: [String]]) ?? [:]
    }

    /// Dante, not an agent, watches CI: `gh run list` every minute and a half while a type
    /// waits for failures, and a job only when one comes.
    private func updateCIWatch() {
        guard !watchedTypes.isEmpty else {
            ciWatch?.cancel()
            ciWatch = nil
            ciBaseline = nil
            ciProblem = nil
            ciChecked = nil
            return
        }
        guard ciWatch == nil else { return }
        ciWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkCI()
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }

    func checkCI() async {
        guard let root, !watchedTypes.isEmpty else { return }
        let result = await CIRun.load(projectRoot: root, limit: 15)
        guard !Task.isCancelled, root == self.root else { return }
        ciChecked = Date()
        switch result {
        case .failure(.noWorkflows): ciProblem = "This project has no GitHub Actions workflows to watch."
        case .failure(.noGitHubCLI): ciProblem = "Watching CI needs the GitHub CLI (gh), signed in."
        case .failure(.failed(let message)): ciProblem = "gh couldn’t list the runs: \(message)"
        case .success(let runs):
            ciProblem = nil
            guard let baseline = ciBaseline else {
                ciBaseline = JobTrigger.baseline(runs)
                return
            }
            let branch = currentBranch?()
            for type in watchedTypes {
                let branches = Set(type.branches.isEmpty ? [branch].compactMap { $0 } : type.branches.filter { $0 == branch })
                for run in JobTrigger.newFailures(in: runs, baseline: baseline, branches: branches, jobs: records) {
                    let engine = type.agent.flatMap(AgentEngine.init(rawValue:)) ?? Preferences.shared.agentEngine
                    let brief = type.request(JobType.subject(for: run), projectRoot: root)
                    if let job = await start(brief: brief, engine: engine, awayMinutes: type.awayMinutes, type: type, trigger: JobTrigger.ci(run)) {
                        onTriggered?(job)
                    }
                }
            }
        }
    }

    // MARK: Starting and running

    /// Makes the worktree and starts the agent on the brief.
    @discardableResult
    func start(brief: String, engine: AgentEngine, awayMinutes: Int? = nil, type: JobType? = nil, trigger: String? = nil) async -> JobRecord? {
        guard let root else { return nil }
        if let unavailable {
            failures["new"] = unavailable
            return nil
        }
        // One worktree at a time; a second job (from `dante job`, say) waits its turn.
        while starting != nil { try? await Task.sleep(for: .milliseconds(200)) }
        let title = JobPlan.title(from: brief)
        starting = title
        defer { starting = nil }
        do {
            var job = try await JobWorktree.create(title: title, brief: brief, engine: engine, repo: root)
            job.setAway(awayMinutes)
            if awayMinutes != nil { watchTime() }
            job.kind = type?.id
            job.trigger = trigger
            job.scope = type.flatMap { $0.paths.isEmpty ? nil : $0.paths }
            job.commands = type.flatMap { $0.commands.isEmpty ? nil : $0.commands }
            Self.seedSearchIndex(from: root, to: job.worktreeURL)
            records.append(job)
            save()
            let claude = wake(job.id)
            claude?.send(brief)
            return job
        } catch {
            failures["new"] = error.localizedDescription
            return nil
        }
    }

    var startFailure: String? { failures["new"] }
    func clearStartFailure() { failures["new"] = nil }

    /// The job's conversation, started (and resumed, after a restart) when needed.
    @discardableResult
    func wake(_ id: String) -> ClaudeSession? {
        if let claude = sessions[id] { return claude }
        guard let job = record(id), job.outcome == .open, let makeSession,
              FileManager.default.fileExists(atPath: job.worktree) else { return nil }
        let claude = makeSession(job)
        claude.onConversationStarted = { [weak self] conversation in self?.noteConversation(conversation, for: id) }
        sessions[id] = claude
        if let conversation = job.conversationID, job.engine == .claude {
            let url = ClaudeHistory.transcriptURL(for: conversation, root: job.worktreeURL)
            if FileManager.default.fileExists(atPath: url.path) {
                Task {
                    let items = await Task.detached(priority: .userInitiated) {
                        (try? String(contentsOf: url, encoding: .utf8)).map(ClaudeHistory.items(fromTranscript:)) ?? []
                    }.value
                    claude.resume(conversation: conversation, items: items)
                }
            }
        }
        return claude
    }

    private func noteConversation(_ conversation: String, for id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].conversationID != conversation else { return }
        records[index].conversationID = conversation
        save()
    }

    // MARK: Away mode

    /// Lets the job go ahead on its own for `minutes` from now, or (nil) back to asking.
    func setAway(_ id: String, minutes: Int?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].setAway(minutes)
        reportedTimeUp.remove(id)
        save()
        if minutes != nil { watchTime() }
    }

    /// Checks away jobs' time every few seconds while any are away, and reports each one
    /// whose time is up once.
    private func watchTime() {
        guard clock == nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.now = Date()
                let away = self.open.filter(\.isAway)
                for job in away where job.outOfTime(at: self.now) && !self.reportedTimeUp.contains(job.id) {
                    self.reportedTimeUp.insert(job.id)
                    self.onAwayTimeUp?(job)
                }
                if away.isEmpty { self.clock = nil; return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func phase(of id: String) -> JobPhase {
        guard let job = record(id) else { return .discarded }
        let claude = sessions[id]
        var failure: String?
        if case .unavailable(let reason)? = claude?.state { failure = reason }
        let replied = claude?.items.contains { if case .assistant = $0.content { true } else { false } } ?? false
        return JobPhase.of(outcome: job.outcome, live: claude != nil, working: claude?.state == .working,
                           failure: failure, pending: claude?.pendingApprovals ?? [], replied: replied)
    }

    /// Claude's latest words in the job, for the board.
    func lastReply(of id: String) -> String? {
        guard let claude = sessions[id] else { return nil }
        for item in claude.items.reversed() {
            if case .assistant(let text) = item.content { return AgentJob.gist(of: text) }
        }
        return nil
    }

    /// The tool running now, or the last one, as the panel words it.
    func activity(of id: String) -> String? {
        guard let claude = sessions[id], let job = record(id) else { return nil }
        for item in claude.items.reversed() {
            guard case .tool(let tool) = item.content else { continue }
            let target = JobPlan.shortened(tool.target(in: job.worktreeURL), worktree: job.worktree)
            return [tool.verb, target].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return nil
    }

    var inbox: [JobInbox.Item] {
        JobInbox.items(open.compactMap { job in
            sessions[job.id].map { JobInbox.Source(job: job.id, title: job.title, pending: $0.pendingApprovals) }
        })
    }

    var runningCount: Int { open.filter { phase(of: $0.id).isActive }.count }

    func refreshChanges() async {
        for job in open {
            changes[job.id] = await JobWorktree.changes(of: job)
        }
    }

    @ObservationIgnored private var pendingRefresh: [String: Task<Void, Never>] = [:]

    /// A job wrote a file: count its changes again shortly, once for a burst of edits.
    func changesMayHaveChanged(_ id: String) {
        pendingRefresh[id]?.cancel()
        pendingRefresh[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.refreshChanges(of: id)
        }
    }

    func refreshChanges(of id: String) async {
        guard let job = record(id) else { return }
        changes[id] = await JobWorktree.changes(of: job)
    }

    // MARK: Finishing

    /// Commits what's left, merges the branch into the main checkout and removes the worktree.
    func merge(_ id: String) async -> String? {
        guard let root, let job = record(id), !busy.contains(id) else { return nil }
        sessions[id]?.stop()
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            try await JobWorktree.merge(job, into: root)
            close(id, as: .merged)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Throws the job's work away: its worktree and its branch.
    func discard(_ id: String) async {
        guard let root, let job = record(id), !busy.contains(id) else { return }
        sessions[id]?.stop()
        busy.insert(id)
        defer { busy.remove(id) }
        await JobWorktree.removeWorktree(job, repo: root, deleteBranch: true, force: true)
        close(id, as: .discarded)
    }

    /// Takes a finished job off the board's history.
    func forget(_ id: String) {
        records.removeAll { $0.id == id && $0.outcome != .open }
        save()
    }

    private func close(_ id: String, as outcome: JobRecord.Outcome) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].outcome = outcome
        records[index].closed = Date()
        sessions[id] = nil
        changes[id] = nil
        try? FileManager.default.removeItem(at: SemanticIndex.url(for: records[index].worktreeURL))
        save()
    }

    func stopAll() {
        for claude in sessions.values { claude.stop() }
        clock?.cancel()
        clock = nil
        ciWatch?.cancel()
        ciWatch = nil
        ciBaseline = nil
    }

    private func save() {
        guard let root else { return }
        // A long history isn't useful: keep every open job and the last 30 finished ones.
        let kept = open + Array(closed.prefix(30))
        try? JobStore.save(kept.sorted { $0.created < $1.created }, for: root)
    }

    /// A job's worktree starts with the project's search index, so only what the job changes
    /// is embedded again.
    private static func seedSearchIndex(from root: URL, to worktree: URL) {
        let source = SemanticIndex.url(for: root)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.copyItem(at: source, to: SemanticIndex.url(for: worktree))
    }
}
