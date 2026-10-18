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
        Task { await refreshChanges() }
    }

    // MARK: Starting and running

    /// Makes the worktree and starts the agent on the brief.
    @discardableResult
    func start(brief: String, engine: AgentEngine) async -> JobRecord? {
        guard let root, unavailable == nil, starting == nil else { return nil }
        let title = JobPlan.title(from: brief)
        starting = title
        defer { starting = nil }
        do {
            let job = try await JobWorktree.create(title: title, brief: brief, engine: engine, repo: root)
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
