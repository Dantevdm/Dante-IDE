import DanteKit
import Foundation
import Observation

/// Finishing a task: commit what's there, push it on a branch named for the task, open a
/// pull request with `gh`, and move the task to review. Claude drafts the commit message and
/// the pull request; everything stays editable until it runs.
@MainActor
@Observable
final class FinishTaskModel {
    let root: URL
    let task: PlanTask

    var isLoading = true
    private(set) var currentBranch = ""
    private(set) var defaultBranch = "main"
    private(set) var hasUpstream = false
    /// On the default branch a new branch is made for the task; otherwise the current one is used.
    private(set) var createsBranch = false
    var branchName = ""
    private(set) var hasChanges = false
    private(set) var branchCommits: [String] = []

    var commitMessage = ""
    var pullTitle = ""
    var pullBody = ""
    var opensPullRequest = false
    var isDraft = false
    /// Why a pull request can't be opened here, if it can't.
    private(set) var pullRequestUnavailable: String?

    private(set) var draftingCommit = false
    private(set) var draftingPull = false
    private(set) var step: String?
    private(set) var error: String?
    private(set) var pullRequestURL: URL?
    private(set) var finished = false
    /// Set once pushed, so a retry after a failed pull request doesn't push again.
    private(set) var pushed = false

    init(root: URL, task: PlanTask) {
        self.root = root
        self.task = task
    }

    var canRun: Bool {
        !isLoading && step == nil && !finished
            && (!hasChanges || !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!createsBranch || GitBranch.isValidName(branchName))
            && (!opensPullRequest || !pullTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            && (hasChanges || !branchCommits.isEmpty || pushed)
    }

    var runLabel: String {
        var parts: [String] = []
        if hasChanges { parts.append("Commit") }
        parts.append("Push")
        if opensPullRequest { parts.append("Open PR") }
        return parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    func prepare() async {
        isLoading = true
        defer { isLoading = false }
        guard let status = await GitRepository.status(in: root) else {
            error = "This folder isn’t a git repository."
            return
        }
        let branches = await GitRepository.branches(in: root)
        currentBranch = status.branch ?? ""
        hasUpstream = status.upstream != nil
        hasChanges = !status.changes.isEmpty
        defaultBranch = await GitHub.defaultBranch(in: root, branches: branches)
        createsBranch = currentBranch.isEmpty || currentBranch == defaultBranch
        branchName = createsBranch ? TaskBranch.name(for: task) : currentBranch
        branchCommits = createsBranch ? [] : await GitHub.commits(since: defaultBranch, in: root)

        if !GitHub.isAvailable {
            pullRequestUnavailable = "Install the GitHub CLI (gh) and sign in to open pull requests from Dante."
        } else if await !GitHub.hasGitHubRemote(in: root) {
            pullRequestUnavailable = "This repository has no GitHub remote."
        }
        opensPullRequest = pullRequestUnavailable == nil

        async let commit: Void = hasChanges ? draftCommitMessage() : ()
        async let pull: Void = opensPullRequest ? draftPullRequest() : ()
        _ = await (commit, pull)
    }

    func draftCommitMessage() async {
        draftingCommit = true
        defer { draftingCommit = false }
        async let diff = GitRepository.workingDiff(in: root)
        async let subjects = GitRepository.recentSubjects(in: root)
        let prompt = CommitMessage.prompt(diff: await diff, recentSubjects: await subjects, tasks: [], finishing: "\(task.id): \(task.title)")
        do {
            commitMessage = CommitMessage.clean(try await ClaudeQuick.text(prompt, system: CommitMessage.system, in: root))
        } catch {
            if commitMessage.isEmpty { commitMessage = task.title }
            self.error = error.localizedDescription
        }
    }

    func draftPullRequest() async {
        draftingPull = true
        defer { draftingPull = false }
        async let branchDiff = createsBranch ? "" : GitHub.branchDiff(since: defaultBranch, in: root)
        async let working = hasChanges ? GitRepository.workingDiff(in: root) : ""
        let diff = [await branchDiff, await working].filter { !$0.isEmpty }.joined(separator: "\n\nNot yet committed:\n")
        do {
            let answer = try await ClaudeQuick.text(PullRequestDraft.prompt(task: task, diff: diff, commits: branchCommits),
                                                    system: PullRequestDraft.system, in: root)
            let draft = PullRequestDraft.parse(answer)
            pullTitle = draft.title.isEmpty ? task.title : draft.title
            pullBody = draft.body
        } catch {
            if pullTitle.isEmpty { pullTitle = task.title }
            self.error = error.localizedDescription
        }
    }

    /// Runs every step in order, stopping at the first failure; running again picks up from
    /// there. The task moves to review first so that change lands in the commit; it moves
    /// back if the commit fails.
    func run(tasks: TaskBoard) async {
        error = nil
        let previousState = task.state
        do {
            if createsBranch {
                step = "Creating \(branchName)…"
                try await GitRepository.createBranch(branchName, in: root)
                hasUpstream = false
                createsBranch = false
            }
            if hasChanges {
                step = "Committing…"
                try? tasks.move(task.id, to: .review)
                do {
                    try await GitRepository.stageAll(in: root)
                    try await GitRepository.commit(message: commitMessage.trimmingCharacters(in: .whitespacesAndNewlines), in: root)
                } catch {
                    try? tasks.move(task.id, to: previousState)
                    throw error
                }
                hasChanges = false
                branchCommits.insert(commitMessage.components(separatedBy: "\n").first ?? "", at: 0)
            }
            if !pushed {
                step = "Pushing \(branchName)…"
                try await GitRepository.push(branch: branchName, hasUpstream: hasUpstream, in: root)
                hasUpstream = true
                pushed = true
            }
            if opensPullRequest {
                step = "Opening the pull request…"
                pullRequestURL = try await GitHub.createPullRequest(
                    title: pullTitle.trimmingCharacters(in: .whitespaces), body: pullBody,
                    base: defaultBranch, head: branchName, draft: isDraft, in: root)
            }
            try? tasks.move(task.id, to: .review)
            finished = true
        } catch {
            self.error = error.localizedDescription
        }
        step = nil
    }
}
