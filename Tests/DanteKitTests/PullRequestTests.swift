import Foundation
import Testing
@testable import DanteKit

@Suite struct PullRequestTests {
    @Test func branchNamesComeFromTheTask() {
        let task = PlanTask(id: "DI-44", title: "Finish a task with a commit and PR drafted by Claude, task moves to review", phase: "release")
        let name = TaskBranch.name(for: task)
        #expect(name == "di-44-finish-a-task-with-a-commit-and-pr-drafted")
        #expect(name.count <= 48 && GitBranch.isValidName(name))
        #expect(TaskBranch.name(for: PlanTask(id: "X-1", title: "Löwe & Co: café!", phase: "build")) == "x-1-löwe-co-café")
    }

    @Test func readsClaudesDraft() {
        let draft = PullRequestDraft.parse("""
            Here's the pull request:
            ## Title: "Add a Settings window"

            Adds ⌘, with four tabs.

            ## Testing
            Ran the app.
            """)
        #expect(draft.title == "Add a Settings window")
        #expect(draft.body.hasPrefix("Adds ⌘, with four tabs.") && draft.body.hasSuffix("Ran the app."))
        #expect(PullRequestDraft.parse("").title.isEmpty)
    }

    @Test func findsThePullRequestAddressInGhOutput() {
        let output = "Creating pull request for feature into main in someone/repo\n\nhttps://github.com/someone/repo/pull/12\n"
        #expect(GitHub.pullRequestURL(in: output)?.absoluteString == "https://github.com/someone/repo/pull/12")
        #expect(GitHub.pullRequestURL(in: "no pull request here https://github.com/someone/repo") == nil)
    }

    @Test func listsTheBranchsCommitsAndDefaultBranch() async throws {
        let folder = try TemporaryFolder()
        for command in [["git", "init", "-q", "-b", "main"], ["git", "config", "user.name", "t"], ["git", "config", "user.email", "t@example.com"], ["git", "config", "commit.gpgsign", "false"]] {
            _ = await Shell.run(command, in: folder.url)
        }
        try folder.write("a.txt", "one")
        _ = await Shell.run(["git", "add", "-A"], in: folder.url)
        _ = await Shell.run(["git", "commit", "-q", "-m", "First"], in: folder.url)
        _ = await Shell.run(["git", "checkout", "-q", "-b", "di-1-work"], in: folder.url)
        try folder.write("a.txt", "two")
        _ = await Shell.run(["git", "commit", "-q", "-am", "Second"], in: folder.url)

        let branches = await GitRepository.branches(in: folder.url)
        #expect(await GitHub.defaultBranch(in: folder.url, branches: branches) == "main")
        #expect(await GitHub.commits(since: "main", in: folder.url) == ["Second"])
        let diff = await GitHub.branchDiff(since: "main", in: folder.url)
        #expect(diff.contains("-one") && diff.contains("+two"))
        #expect(await !GitHub.hasGitHubRemote(in: folder.url))
    }
}
