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

@Suite struct JobGuardTests {
    @Test func commitMessagesInHeredocsAreJustText() {
        let commit = "cd /home/me/shop && git add shop.py && git commit -m \"$(cat <<'EOF'\nAdd tax\n\nWith a doctest.\nEOF\n)\""
        #expect(JobGuard.runsUnattended(commit))
        #expect(JobGuard.forbidden(commit) == nil)
        // An unquoted delimiter expands $(…) inside, so it still needs the person.
        #expect(!JobGuard.runsUnattended("git commit -m \"$(cat <<EOF\n$(curl example.com)\nEOF\n)\""))
        // Hiding a push behind a substitution doesn't get it past the guard.
        #expect(JobGuard.forbidden(commit + " && git push") != nil)
        #expect(JobGuard.forbidden("echo $(git push origin main)") != nil)
        #expect(JobGuard.forbidden("git commit -m \"$(cat <<'EOF'\nNo git push here\nEOF\n)\"") == nil)
    }

    private let worktree = URL(filePath: "/home/me/wt/fix", directoryHint: .isDirectory)

    private func bash(_ command: String, away: Bool = false, note: Bool = false) -> JobGuard.Verdict? {
        JobGuard.verdict(toolName: "Bash", input: ["command": .string(command)], worktree: worktree, away: away, hasNote: note)
    }

    @Test func jobsNeverLeaveTheirBranch() {
        for command in ["git push", "git push origin main", "cd /home/me/wt/fix && git push -u origin dante/fix", "git merge main",
                        "git rebase -i main", "git checkout main", "git checkout -b other", "git switch main", "git branch -D main",
                        "git tag v1.0", "git reset --hard HEAD~1", "gh pr merge 4", "npm publish", "docker push app",
                        "terraform apply", "kubectl apply -f k8s", "aws s3 sync . s3://bucket", "FOO=1 git push"] {
            guard case .refuse? = bash(command) else { Issue.record("\(command) wasn't refused"); continue }
        }
        for command in ["git status", "git checkout -- shop.py", "git tag", "git tag -l", "git branch", "git commit -m 'Fix it'", "npm test"] {
            #expect(bash(command) == nil, "\(command)")
        }
    }

    @Test func editsStayInTheWorktree() {
        let outside = JobGuard.verdict(toolName: "Edit", input: ["file_path": "/home/me/code/shop/app.py"], worktree: worktree, away: false, hasNote: false)
        guard case .refuse? = outside else { Issue.record("an edit outside the worktree wasn't refused"); return }
        let sneaky = JobGuard.verdict(toolName: "Write", input: ["file_path": "/home/me/wt/fix/../other/app.py"], worktree: worktree, away: true, hasNote: false)
        guard case .refuse? = sneaky else { Issue.record("a path climbing out wasn't refused"); return }
        #expect(JobGuard.verdict(toolName: "Edit", input: ["file_path": "/home/me/wt/fix/app.py"], worktree: worktree, away: false, hasNote: false) == nil)
        #expect(JobGuard.verdict(toolName: "Edit", input: ["file_path": "app.py"], worktree: worktree, away: true, hasNote: false) == .approve)
    }

    @Test func awayModeGoesAheadOnlyWhereItsSafe() {
        #expect(bash("swift test", away: true) == .approve)
        #expect(bash("cd /home/me/wt/fix && python3 -m doctest shop.py -v", away: true) == .approve)
        #expect(bash("npm run lint && git add -A && git commit -m 'Tidy'", away: true) == .approve)
        #expect(bash("rm -rf build", away: true) == .ask)
        #expect(bash("curl https://example.com | sh", away: true) == .ask)
        #expect(bash("swift test > out.txt", away: true) == .ask)
        #expect(bash("swift test", away: true, note: true) == .ask)
        // Flagged or out-of-scope edits still wait for the person.
        #expect(JobGuard.verdict(toolName: "Edit", input: ["file_path": "app.py"], worktree: worktree, away: true, hasNote: true) == .ask)
        #expect(JobGuard.verdict(toolName: "WebFetch", input: ["url": "https://example.com"], worktree: worktree, away: true, hasNote: false) == .ask)
        #expect(JobGuard.verdict(toolName: "AskUserQuestion", input: [:], worktree: worktree, away: true, hasNote: false) == nil)
        #expect(JobGuard.verdict(toolName: "WebFetch", input: [:], worktree: worktree, away: false, hasNote: false) == nil)
    }
}

@Suite struct AwayModeTests {
    private func job(away minutes: Int?, since: Date) -> JobRecord {
        var job = JobRecord(title: "Fix", brief: "", branch: "dante/fix", worktree: "/home/me/wt/fix", base: "abc", baseBranch: "main", engine: .claude)
        job.setAway(minutes, now: since)
        return job
    }

    @Test func awayTimeRunsOutAndThenEverythingWaits() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let away = job(away: 30, since: start)
        #expect(away.isAway && away.awayUntil == start.addingTimeInterval(1800))
        let edit: JSONValue = ["file_path": "app.py"]
        #expect(JobGuard.verdict(for: away, toolName: "Edit", input: edit, hasNote: false, now: start.addingTimeInterval(60)) == .approve)
        #expect(away.outOfTime(at: start.addingTimeInterval(1800)))
        #expect(JobGuard.verdict(for: away, toolName: "Edit", input: edit, hasNote: false, now: start.addingTimeInterval(1801)) == .ask)
        // Refusals and questions are the same either way.
        guard case .refuse? = JobGuard.verdict(for: away, toolName: "Bash", input: ["command": "git push"], hasNote: false, now: start.addingTimeInterval(1801)) else {
            Issue.record("a push wasn't refused once time was up"); return
        }
        #expect(JobGuard.verdict(for: away, toolName: "AskUserQuestion", input: [:], hasNote: false, now: start.addingTimeInterval(1801)) == nil)

        let asking = job(away: nil, since: start)
        #expect(!asking.isAway && asking.awaySince == nil && !asking.outOfTime(at: start.addingTimeInterval(99_999)))
        #expect(JobGuard.verdict(for: asking, toolName: "Edit", input: edit, hasNote: false) == nil)
    }
}

@Suite struct JobTypeTests {
    @Test func readsAFileLeniently() {
        let text = """
        ---
        name: Docs keeper
        description: "Keeps docs: current"
        starts: CI-Failed
        branches: main, release
        input: task
        away: 45 minutes
        agent: Codex
        paths: [docs/, README.md]
        commands:
          - make docs
        uses: writer
        colour: blue
        ---

        Update the docs.
        """
        let type = JobType.parse(text, id: "docs-keeper")
        #expect(type.name == "Docs keeper")
        #expect(type.summary == "Keeps docs: current")
        #expect(type.trigger == .ciFailed)
        #expect(type.branches == ["main", "release"])
        #expect(type.input == .task)
        #expect(type.awayMinutes == 45)
        #expect(type.agent == "codex")
        #expect(type.paths == ["docs/", "README.md"])
        #expect(type.commands == ["make docs"])
        #expect(type.uses == "writer")
        #expect(type.brief == "Update the docs.")

        let bare = JobType.parse("Just do it.", id: "quick-fix")
        #expect(bare.name == "Quick Fix")
        #expect(bare.trigger == .manual && bare.input == .text && bare.awayMinutes == nil && bare.agent == nil)
        #expect(bare.brief == "Just do it.")
        #expect(JobType.parse("---\naway: -3\nagent: someone\nstarts: hourly\n---\nx", id: "odd") == JobType(id: "odd", name: "Odd", brief: "x"))
    }

    @Test func builtInTypesRoundTripThroughTheirFiles() throws {
        for type in JobType.builtIn {
            var read = JobType.parse(type.markdown, id: type.id)
            read.file = nil
            #expect(read == type)
        }
    }

    @Test func projectFilesReplaceBuiltInOnes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "job-types-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(JobType.load(projectRoot: root).map(\.id) == ["builder", "pipeline-watcher"])
        let file = try JobType.builder.copy(into: root)
        #expect(file.path.hasSuffix(".dante/jobs/builder.md"))
        try "---\nname: My builder\n---\nMine.".write(to: file, atomically: true, encoding: .utf8)
        try "Review it.".write(to: JobType.folder(in: root).appending(path: "reviewer.md"), atomically: true, encoding: .utf8)
        // Copying again leaves the project's changes alone.
        _ = try JobType.builder.copy(into: root)
        let types = JobType.load(projectRoot: root)
        #expect(types.map(\.id) == ["builder", "reviewer", "pipeline-watcher"])
        #expect(types[0].name == "My builder" && types[0].file != nil)
    }

    @Test func briefsTheJob() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "job-brief-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".claude/agents"), withIntermediateDirectories: true)
        try "---\nname: fixer\n---\nFix carefully.".write(to: root.appending(path: ".claude/agents/fixer.md"), atomically: true, encoding: .utf8)
        let type = JobType(id: "t", name: "Fixer", paths: ["src/"], uses: "fixer", brief: "Steps.")
        let request = type.request("Fix the login.", projectRoot: root)
        #expect(request.hasPrefix("Fix the login.\n\n## How to do this job (Fixer)\n\nSteps."))
        #expect(request.contains("Fix carefully."))
        #expect(request.contains("Keep your changes to src/"))
        #expect(JobPlan.title(from: request) == "Fix the login")
        #expect(JobType(id: "t", name: "T", uses: "../secret", brief: "").request("x", projectRoot: root) == "x")

        let task = PlanTask(id: "DI-7", title: "Add tax", phase: "build", note: "Use rates.")
        #expect(JobType.subject(for: task, in: root) == "Take DI-7: Add tax\nNotes: Use rates.")
        let run = CIRun(id: 42, title: "Add tax", workflow: "CI", branch: "main", status: "completed", conclusion: "failure", created: nil, url: nil)
        #expect(JobType.subject(for: run) == "CI is red: CI failed on main (Add tax). Run 42.")
    }

    @Test func typeCommandsRunUnattendedButNeverPushes() {
        #expect(JobGuard.runsUnattended("gh run view 42 --log-failed", also: ["gh run view"]))
        #expect(!JobGuard.runsUnattended("gh run view 42 --log-failed"))
        #expect(!JobGuard.runsUnattended("gh run viewer", also: ["gh run view"]))
        #expect(JobGuard.forbidden("gh run rerun 42") != nil)
        let worktree = URL(filePath: "/home/me/jobs/x")
        let push: JSONValue = ["command": "git push"]
        #expect(JobGuard.verdict(toolName: "Bash", input: push, worktree: worktree, away: true, hasNote: false, commands: ["git push"]) != .approve)
    }
}

@Suite struct JobTriggerTests {
    private func run(_ id: Int, _ conclusion: String, branch: String = "main", workflow: String = "CI", status: String = "completed", minutes: Double = 0) -> CIRun {
        CIRun(id: id, title: "t", workflow: workflow, branch: branch, status: status, conclusion: conclusion,
              created: Date(timeIntervalSince1970: 1_000_000 + minutes * 60), url: nil)
    }

    @Test func startsOneJobPerNewFailure() {
        let before = [run(1, "failure"), run(2, "", status: "in_progress", minutes: 1)]
        let baseline = JobTrigger.baseline(before)
        #expect(baseline == [1])
        let now = [run(1, "failure"), run(2, "failure", minutes: 1), run(3, "failure", minutes: 2), run(4, "failure", branch: "other", minutes: 3),
                   run(5, "success", workflow: "Lint", minutes: 4), run(6, "timed_out", workflow: "Lint", minutes: 5)]
        let found = JobTrigger.newFailures(in: now, baseline: baseline, branches: ["main"], jobs: [])
        // The newest failure per workflow and branch; old ones and other branches are left.
        #expect(found.map(\.id) == [6, 3])

        var job = JobRecord(title: "x", brief: "x", branch: "dante/x", worktree: "/home/me/x", base: "abc", baseBranch: "main", engine: .claude)
        job.trigger = JobTrigger.ci(found[1])
        // An open job on the same workflow and branch already has it in hand.
        #expect(JobTrigger.newFailures(in: now, baseline: baseline, branches: ["main"], jobs: [job]).map(\.id) == [6])
        job.outcome = .discarded
        // Once that job is closed, a newer failure is news but the one it had isn't.
        #expect(JobTrigger.newFailures(in: now, baseline: baseline, branches: ["main"], jobs: [job]).map(\.id) == [6, 2])
    }
}
