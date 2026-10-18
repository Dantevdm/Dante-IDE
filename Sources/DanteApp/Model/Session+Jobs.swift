import DanteKit
import Foundation

extension Session {
    /// Every conversation's waiting approvals and questions: the main one and each job's.
    var inbox: [JobInbox.Item] {
        var sources: [JobInbox.Source] = []
        if let claude { sources.append(.init(job: nil, title: "Main conversation", pending: claude.pendingApprovals)) }
        sources += jobs.open.compactMap { job in
            jobs.sessions[job.id].map { JobInbox.Source(job: job.id, title: job.title, pending: $0.pendingApprovals) }
        }
        return JobInbox.items(sources)
    }

    /// The first conversation with something waiting: the main one, then each job's in turn.
    var waitingConversation: (claude: ClaudeSession, job: JobRecord?)? {
        if let claude, !claude.pendingApprovals.isEmpty { return (claude, nil) }
        for job in jobs.open {
            if let claude = jobs.sessions[job.id], !claude.pendingApprovals.isEmpty { return (claude, job) }
        }
        return nil
    }

    /// The conversation an inbox item came from.
    func conversation(of item: JobInbox.Item) -> ClaudeSession? {
        item.job.map { jobs.sessions[$0] } ?? claude
    }

    /// Shows a job's conversation in the panel (nil for the main one), starting it again when
    /// Dante restarted since.
    func showJob(_ id: String?) {
        if let id { jobs.wake(id) }
        shownJob = id
        showsClaude = true
    }

    /// `reportsFailure` says why in an alert, for jobs that didn't come from the form.
    /// With a `type`, `brief` is what to do this time and the type's own brief follows it.
    func startJob(_ brief: String, engine: AgentEngine, awayMinutes: Int? = nil, type: JobType? = nil, reportsFailure: Bool = false) {
        let request = type.flatMap { type in workspace.map { type.request(brief, projectRoot: $0.url) } } ?? brief
        Task {
            if let job = await jobs.start(brief: request, engine: engine, awayMinutes: awayMinutes, type: type) {
                showJob(job.id)
            } else if reportsFailure {
                errorMessage = jobs.startFailure ?? jobs.unavailable ?? "The job couldn’t start."
                jobs.clearStartFailure()
            }
        }
    }

    func mergeJob(_ id: String) {
        Task {
            if let failure = await jobs.merge(id) {
                errorMessage = failure
                gitRevision += 1
                return
            }
            if shownJob == id { shownJob = nil }
            refreshBranch()
            gitRevision += 1
            workspace?.refreshFileIndex()
        }
    }

    func discardJob(_ id: String) {
        if shownJob == id { shownJob = nil }
        Task { await jobs.discard(id) }
    }
}
