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

struct BranchReviewTests {
    @Test func readsFindingsWithSeverityAndPlace() {
        let answer = """
        Here's what I found:
        - [blocker] internal/api/orders.go:42 — the query builds SQL from user input; use a parameter.
        - [Issue] `web/src/app.ts:7-9` - the error is swallowed.
        * [nit] naming is inconsistent between handlers
        - [praise] nice
        """
        let findings = BranchReview.parse(answer)
        #expect(findings.map(\.severity) == [.blocker, .issue, .nit])
        #expect(findings[0].file == "internal/api/orders.go" && findings[0].line == 42)
        #expect(findings[0].text.hasPrefix("the query builds SQL"))
        #expect(findings[1].file == "web/src/app.ts" && findings[1].line == 7)
        #expect(findings[2].file == nil && findings[2].text == "naming is inconsistent between handlers")
        #expect(BranchReview.parse("No findings.").isEmpty)
    }

    @Test func cutsLongDiffs() {
        let prompt = BranchReview.prompt(task: nil, diff: String(repeating: "x", count: 50), commits: ["Add orders"], limit: 10)
        #expect(prompt.contains("xxxxxxxxxx\n[diff cut at 10 characters]"))
        #expect(prompt.contains("- Add orders"))
    }
}

struct TaskConversationsTests {
    @Test func remembersAConversationPerTaskAndProject() {
        let defaults = UserDefaults(suiteName: "TaskConversationsTests")!
        defaults.removePersistentDomain(forName: "TaskConversationsTests")
        let root = URL(filePath: "/home/me/shop")
        TaskConversations.set("abc", for: "SH-1", in: root, defaults: defaults)
        #expect(TaskConversations.conversation(for: "SH-1", in: root, defaults: defaults) == "abc")
        #expect(TaskConversations.conversation(for: "SH-1", in: URL(filePath: "/home/me/other"), defaults: defaults) == nil)
        TaskConversations.set(nil, for: "SH-1", in: root, defaults: defaults)
        #expect(TaskConversations.conversation(for: "SH-1", in: root, defaults: defaults) == nil)
    }
}

struct SecretScanTests {
    @Test func findsKeysInAddedLinesWithTheirLines() {
        let diff = """
        diff --git a/config.go b/config.go
        --- a/config.go
        +++ b/config.go
        @@ -10,3 +10,5 @@ package config
         var region = "eu-west-1"
        -var key = ""
        +var key = "AKIAABCDEFGHIJKLMNOP"
        +var dsn = "postgres://app:hunter22@db:5432/app"
         var debug = false
        +var token = os.Getenv("TOKEN")
        """
        let found = SecretScan.findings(inDiff: diff)
        #expect(found.map(\.line) == [11, 12])
        #expect(found.first?.kind == "An AWS access key")
        #expect(found.first?.file == "config.go")
        #expect(SecretScan.warning(found)?.contains("config.go:11 and 1 more") == true)
    }

    @Test func placeholdersAndRemovedLinesAreFine() {
        let diff = """
        +++ b/.env.example
        @@ -0,0 +1,2 @@
        +PASSWORD="changeme"
        +DATABASE_URL=postgres://user:password@localhost/db
        -API_KEY="AKIAABCDEFGHIJKLMNOP"
        """
        #expect(SecretScan.findings(inDiff: diff).isEmpty)
    }

    @Test func commitDraftSplitsWarningsAndRefusals() {
        let warned = CommitMessage.read("WARNING: config.go adds an AWS key\nAdd the config loader\n\nReads settings from the environment.")
        #expect(warned.message == "Add the config loader\n\nReads settings from the environment.")
        #expect(warned.warning == "config.go adds an AWS key")
        let refused = CommitMessage.read("I notice this diff contains what looks like a real API key in config.go. You should remove it before committing.")
        #expect(refused.message.isEmpty)
        #expect(refused.warning?.hasPrefix("I notice") == true)
        #expect(CommitMessage.read("Fix the login redirect").warning == nil)
    }
}
