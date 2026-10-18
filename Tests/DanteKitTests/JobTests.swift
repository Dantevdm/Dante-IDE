import Foundation
import Testing
@testable import DanteKit

@Suite struct JobPlanTests {
    @Test func titlesComeFromTheFirstSentence() {
        #expect(JobPlan.title(from: "Fix the login redirect. It loops when the token expires.") == "Fix the login redirect")
        #expect(JobPlan.title(from: "Add dark mode to settings\nUse the theme tokens") == "Add dark mode to settings")
        #expect(JobPlan.title(from: "   ") == "Job")
        let long = JobPlan.title(from: "Rewrite the whole synchronisation layer so that deletions never cross unless the file was unchanged")
        #expect(long.hasSuffix("…") && long.count <= 61 && !long.contains("unchang"))
    }

    @Test func slugsAreSafeForBranches() {
        #expect(JobPlan.slug("Fix the login redirect") == "fix-the-login-redirect")
        #expect(JobPlan.slug("Café: über “quotes” & more words here") == "cafe-uber-quotes-more-words")
        #expect(JobPlan.slug("!!!") == "job")
    }

    @Test func branchesAreNumberedWhenTaken() {
        #expect(JobPlan.branch(for: "fix", taken: []) == "dante/fix")
        #expect(JobPlan.branch(for: "fix", taken: ["dante/fix", "dante/fix-2"]) == "dante/fix-3")
    }

    @Test func worktreesLiveOutsideTheRepo() {
        let base = URL(filePath: "/home/me/Library/Application Support/Dante/worktrees")
        let folder = JobPlan.folder(for: URL(filePath: "/home/me/code/shop"), in: base)
        #expect(folder.path.hasPrefix(base.path) && folder.lastPathComponent.hasPrefix("shop-"))
        #expect(JobPlan.worktree(branch: "dante/fix-2", in: folder).lastPathComponent == "fix-2")
        // Two projects with the same name get different folders.
        #expect(JobPlan.folder(for: URL(filePath: "/home/me/other/shop"), in: base) != folder)
    }

    @Test func commandsLoseTheirTripIntoTheWorktree() {
        let worktree = "/home/me/Library/Application Support/Dante/worktrees/shop-1/fix"
        #expect(JobPlan.shortened("cd \"\(worktree)\" && python3 -m doctest shop.py", worktree: worktree) == "python3 -m doctest shop.py")
        #expect(JobPlan.shortened("cd '\(worktree)' && ls", worktree: worktree) == "ls")
        #expect(JobPlan.shortened("cd /elsewhere && ls", worktree: worktree) == "cd /elsewhere && ls")
    }

    @Test func aReplysGistSkipsItsLabels() {
        #expect(AgentJob.gist(of: "**Summary of changes:**\n- Added `discount(cart, percent)` to shop.py. It rounds.") == "Added discount(cart, percent) to shop.py.")
    }

    @Test func theBriefKeepsTheJobInItsWorktree() {
        let job = JobRecord(title: "Fix it", brief: "Fix it", branch: "dante/fix-it", worktree: "/home/me/wt/fix-it",
                            base: "0123456789abcdef", baseBranch: "main", engine: .claude)
        let brief = JobPlan.brief(for: job, project: "shop")
        #expect(brief.contains("/home/me/wt/fix-it") && brief.contains("dante/fix-it") && brief.contains("main at 01234567"))
        #expect(brief.contains("Don't push"))
    }
}

@Suite struct JobPhaseTests {
    private func tool(_ name: String, change: Bool = false) -> ToolActivity {
        ToolActivity(id: UUID().uuidString, name: name, input: .object([:]), status: .awaitingApproval(requestID: "r"),
                     change: change ? ProposedChange(url: URL(filePath: "/home/me/a.swift"), displayPath: "a.swift", isNewFile: false, lines: [], applies: true) : nil)
    }

    @Test func phasesFollowTheConversation() {
        #expect(JobPhase.of(outcome: .open, live: true, working: true, failure: nil, pending: [], replied: false) == .working)
        #expect(JobPhase.of(outcome: .open, live: true, working: true, failure: nil, pending: [tool("Edit"), tool("Bash")], replied: false) == .waiting(2))
        #expect(JobPhase.of(outcome: .open, live: true, working: true, failure: nil, pending: [tool("AskUserQuestion")], replied: false) == .asking)
        #expect(JobPhase.of(outcome: .open, live: true, working: false, failure: nil, pending: [], replied: true) == .ready)
        #expect(JobPhase.of(outcome: .open, live: false, working: false, failure: nil, pending: [], replied: true) == .paused)
        #expect(JobPhase.of(outcome: .open, live: true, working: false, failure: "No", pending: [], replied: false) == .failed("No"))
        #expect(JobPhase.of(outcome: .merged, live: true, working: true, failure: nil, pending: [], replied: true) == .merged)
        #expect(JobPhase.ready.needsYou && !JobPhase.working.needsYou && JobPhase.asking.isActive && !JobPhase.paused.isActive)
    }

    @Test func theInboxGathersEveryConversation() {
        let edit = tool("Edit", change: true), question = tool("AskUserQuestion"), bash = tool("Bash")
        let items = JobInbox.items([
            .init(job: nil, title: "Main conversation", pending: [bash]),
            .init(job: "a1", title: "Fix it", pending: [edit, question]),
            .init(job: "b2", title: "Idle", pending: []),
        ])
        #expect(items.map(\.from) == ["Main conversation", "Fix it", "Fix it"])
        #expect(items[1].isEdit && items[2].isQuestion && items[0].job == nil)
        #expect(Set(items.map(\.id)).count == 3)
    }
}

@Suite struct JobChangesTests {
    @Test func readsShortstat() {
        let stat = JobChanges.shortstat(" 3 files changed, 10 insertions(+), 2 deletions(-)")
        #expect(stat.files == 3 && stat.insertions == 10 && stat.deletions == 2)
        let one = JobChanges.shortstat(" 1 file changed, 1 deletion(-)")
        #expect(one.files == 1 && one.insertions == 0 && one.deletions == 1)
        #expect(JobChanges.shortstat("").files == 0)
    }

    @Test func readsStatusAndSummarises() {
        let status = JobChanges.status(" M a.swift\n?? new.swift\n?? other.swift\n")
        #expect(status.untracked == 2 && status.dirty)
        #expect(!JobChanges.status("").dirty)
        #expect(JobChanges().summary == "No changes yet")
        #expect(JobChanges(files: 2, insertions: 5, deletions: 1, untracked: 1, commits: 1, uncommitted: true).summary
                == "3 files · +5 −1 · 1 commit · not committed")
    }

    @Test func recordsRoundTrip() throws {
        let folder = try TemporaryFolder()
        let root = URL(filePath: "/home/me/code/shop")
        let job = JobRecord(title: "Fix it", brief: "Fix it please", branch: "dante/fix-it", worktree: "/home/me/wt/fix-it",
                            base: "abc", baseBranch: nil, engine: .codex, conversationID: "c1")
        try JobStore.save([job], for: root, in: folder.url)
        let loaded = JobStore.load(for: root, in: folder.url)
        #expect(loaded.count == 1 && loaded[0].id == job.id && loaded[0].engine == .codex && loaded[0].conversationID == "c1")
        #expect(abs(loaded[0].created.timeIntervalSince(job.created)) < 1)
        #expect(JobStore.load(for: URL(filePath: "/home/me/code/other"), in: folder.url).isEmpty)
    }
}

@Suite(.serialized) struct JobWorktreeTests {
    private func repo() async throws -> TemporaryFolder {
        let folder = try TemporaryFolder()
        for command in [["git", "init", "-q", "-b", "main"], ["git", "config", "user.name", "t"], ["git", "config", "user.email", "t@example.com"], ["git", "config", "commit.gpgsign", "false"]] {
            _ = await Shell.run(command, in: folder.url)
        }
        try folder.write("app.txt", "one\ntwo\n")
        _ = await Shell.run(["git", "add", "-A"], in: folder.url)
        _ = await Shell.run(["git", "commit", "-q", "-m", "Start"], in: folder.url)
        return folder
    }

    @Test func aJobWorksInItsOwnWorktreeAndMergesBack() async throws {
        let repo = try await repo()
        let jobs = try TemporaryFolder()
        let job = try await JobWorktree.create(title: "Add three", brief: "Add a third line", engine: .claude, repo: repo.url, folder: jobs.url)
        #expect(job.branch == "dante/add-three" && job.baseBranch == "main")
        #expect(FileManager.default.fileExists(atPath: job.worktreeURL.appending(path: "app.txt").path))

        // The job edits its copy; the main checkout is untouched.
        try Data("one\ntwo\nthree\n".utf8).write(to: job.worktreeURL.appending(path: "app.txt"))
        try Data("new\n".utf8).write(to: job.worktreeURL.appending(path: "notes.txt"))
        let changes = await JobWorktree.changes(of: job)
        #expect(changes.files == 1 && changes.insertions == 1 && changes.untracked == 1 && changes.uncommitted && changes.commits == 0)
        #expect(try String(contentsOf: repo.url.appending(path: "app.txt"), encoding: .utf8) == "one\ntwo\n")

        // A second job with the same title gets its own branch.
        let second = try await JobWorktree.create(title: "Add three", brief: "", engine: .claude, repo: repo.url, folder: jobs.url)
        #expect(second.branch == "dante/add-three-2")
        await JobWorktree.removeWorktree(second, repo: repo.url, deleteBranch: true, force: true)

        try await JobWorktree.merge(job, into: repo.url)
        #expect(try String(contentsOf: repo.url.appending(path: "app.txt"), encoding: .utf8) == "one\ntwo\nthree\n")
        #expect(FileManager.default.fileExists(atPath: repo.url.appending(path: "notes.txt").path))
        #expect(!FileManager.default.fileExists(atPath: job.worktree))
        let branches = await Shell.run(["git", "branch", "--list", "dante/*"], in: repo.url)
        #expect(branches.stdout.isEmpty)
    }

    @Test func discardingRemovesTheWorkAndTheBranch() async throws {
        let repo = try await repo()
        let jobs = try TemporaryFolder()
        let job = try await JobWorktree.create(title: "Try a thing", brief: "", engine: .claude, repo: repo.url, folder: jobs.url)
        try Data("changed\n".utf8).write(to: job.worktreeURL.appending(path: "app.txt"))
        await JobWorktree.removeWorktree(job, repo: repo.url, deleteBranch: true, force: true)
        #expect(!FileManager.default.fileExists(atPath: job.worktree))
        let branches = await Shell.run(["git", "branch", "--list", "dante/*"], in: repo.url)
        #expect(branches.stdout.isEmpty)
    }

    @Test func aRepoWithoutCommitsCantStartAJob() async throws {
        let folder = try TemporaryFolder()
        _ = await Shell.run(["git", "init", "-q"], in: folder.url)
        await #expect(throws: JobWorktree.Failure.self) {
            try await JobWorktree.create(title: "x", brief: "", engine: .claude, repo: folder.url, folder: folder.url.appending(path: "jobs"))
        }
    }
}
