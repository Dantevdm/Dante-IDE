import DanteKit
import Foundation
import Observation

/// The Changes panel and branch switcher for one window: status, branches, the commit
/// message being written, and whichever git command is running.
@MainActor
@Observable
final class GitModel {
    private(set) var status: GitStatus?
    private(set) var branches: [GitBranch] = []
    /// What's running: "Committing…", "Pushing…". nil when idle.
    private(set) var busy: String?
    var error: GitRepository.Failure?
    /// A short confirmation, such as "Pushed to origin/main".
    var notice: String?
    var message = ""
    var amend = false
    private(set) var writingMessage = false
    /// The file whose diff the editor area shows.
    var diff: DiffTarget?

    struct DiffTarget: Equatable {
        var change: GitStatus.Change
        var staged: Bool
    }

    private var root: URL?

    var isRepository: Bool { status != nil }
    var changeCount: Int { status?.changes.count ?? 0 }
    var canCommit: Bool {
        guard let status, busy == nil else { return false }
        let hasMessage = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasMessage && (!status.staged.isEmpty || !status.unstaged.isEmpty || amend) && status.conflicted.isEmpty
    }

    func load(_ root: URL?) async {
        self.root = root
        guard let root else { status = nil; branches = []; return }
        status = await GitRepository.status(in: root)
        // Keep the open diff on the side of the file that still has changes.
        if let target = diff {
            if let change = status?.changes.first(where: { $0.path == target.change.path }) {
                var updated = GitModel.DiffTarget(change: change, staged: target.staged)
                if target.staged, change.staged == nil { updated.staged = false }
                if !target.staged, change.unstaged == nil, change.staged != nil { updated.staged = true }
                if updated != target { diff = updated }
            } else {
                diff = nil
            }
        }
    }

    func loadBranches() async {
        guard let root else { return }
        branches = await GitRepository.branches(in: root)
    }

    // MARK: Changes

    func stage(_ changes: [GitStatus.Change]) async {
        await perform(nil) { try await GitRepository.stage(changes.map(\.path), in: $0) }
        if var target = diff, changes.contains(where: { $0.path == target.change.path }) { target.staged = true; diff = target }
    }

    func unstage(_ changes: [GitStatus.Change]) async {
        let fresh = status?.isNewRepository ?? false
        await perform(nil) { try await GitRepository.unstage(changes.map(\.path), in: $0, newRepository: fresh) }
        if var target = diff, changes.contains(where: { $0.path == target.change.path }) { target.staged = false; diff = target }
    }

    func discard(_ changes: [GitStatus.Change]) async {
        await perform(nil) { try await GitRepository.discard(changes, in: $0) }
    }

    /// Commits what's staged, or everything when nothing is.
    func commit(thenPush: Bool) async {
        guard let status, canCommit else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let everything = status.staged.isEmpty && !amend
        let committed = await perform("Committing…") { root in
            if everything { try await GitRepository.stageAll(in: root) }
            try await GitRepository.commit(message: text, amend: self.amend, in: root)
        }
        guard committed else { return }
        message = ""
        amend = false
        diff = nil
        notice = "Committed “\(text.components(separatedBy: "\n")[0])”"
        if thenPush { await push() }
    }

    // MARK: Remote

    func push() async {
        guard let status, let branch = status.branch else { return }
        let hasUpstream = status.upstream != nil
        if await perform("Pushing…", { try await GitRepository.push(branch: branch, hasUpstream: hasUpstream, in: $0) }) {
            notice = "Pushed \(branch)"
        }
    }

    func pull() async {
        if await perform("Pulling…", { try await GitRepository.pull(in: $0) }) { notice = "Up to date with \(status?.upstream ?? "the remote")" }
    }

    func fetch() async {
        _ = await perform("Fetching…") { try await GitRepository.fetch(in: $0) }
        await loadBranches()
    }

    /// Push when ahead, pull when behind: the one button beside the branch name.
    func sync() async {
        guard let status else { return }
        if status.behind > 0 { await pull() }
        if (self.status?.ahead ?? 0) > 0 || status.upstream == nil { await push() }
    }

    // MARK: Branches

    func checkout(_ branch: GitBranch) async {
        _ = await perform("Switching to \(branch.localName)…") { try await GitRepository.checkout(branch, in: $0) }
        await loadBranches()
    }

    func createBranch(_ name: String) async {
        _ = await perform("Creating \(name)…") { try await GitRepository.createBranch(name, in: $0) }
        await loadBranches()
    }

    // MARK: Claude

    func writeMessage(tasks: [String]) async {
        guard let root, let status else { return }
        writingMessage = true
        defer { writingMessage = false }
        // With nothing staged the commit takes everything, so describe everything.
        if status.staged.isEmpty, !status.unstaged.isEmpty {
            guard await perform(nil, { try await GitRepository.stageAll(in: $0) }) else { return }
        }
        async let diffText = GitRepository.stagedDiff(in: root)
        async let subjects = GitRepository.recentSubjects(in: root)
        let prompt = CommitMessage.prompt(diff: await diffText, recentSubjects: await subjects, tasks: tasks)
        do {
            message = CommitMessage.clean(try await ClaudeQuick.text(prompt, system: CommitMessage.system, in: root))
        } catch {
            self.error = GitRepository.Failure(message: error.localizedDescription)
        }
    }

    /// Runs a git command against the window's repository, then re-reads the status.
    @discardableResult
    private func perform(_ label: String?, _ work: @escaping (URL) async throws -> Void) async -> Bool {
        guard let root else { return false }
        if let label { busy = label }
        error = nil
        notice = nil
        defer { busy = nil }
        do {
            try await work(root)
            await load(root)
            return true
        } catch let failure as GitRepository.Failure {
            error = failure
        } catch {
            self.error = GitRepository.Failure(message: error.localizedDescription)
        }
        await load(root)
        return false
    }
}
