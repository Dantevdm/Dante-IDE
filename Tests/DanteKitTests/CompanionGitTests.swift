import DanteKit
import Foundation
import Testing

struct CompanionGitTests {
    @Test func makesTheDevicesViewFromTheStatus() {
        var status = GitStatus()
        status.branch = "main"
        status.upstream = "origin/main"
        status.ahead = 1
        status.behind = 2
        status.changes = [
            .init(path: "Sources/App.swift", staged: .modified),
            .init(path: "notes.md", unstaged: .untracked),
            .init(path: "Package.swift", unstaged: .conflicted),
        ]
        let branches = [GitBranch(name: "origin/HEAD", isRemote: true), GitBranch(name: "origin/main", isRemote: true),
                        GitBranch(name: "feature", subject: "Try it"), GitBranch(name: "main", isCurrent: true)]
        let commits = [CompanionGit.Commit(hash: "abc1234", subject: "Newest"), CompanionGit.Commit(hash: "def5678", subject: "Older")]
        let git = CompanionGit.make(status: status, branches: branches, commits: commits, operation: nil, message: "Draft",
                                    warning: nil, notice: "Pushed main", failure: GitRepository.Failure(message: "fatal: could not read Username for 'https://example.com': terminal prompts disabled"))
        #expect(git.syncSummary == "1 to push · 2 to pull")
        #expect(git.staged.map(\.path) == ["Sources/App.swift"])
        #expect(git.unstaged.map(\.path) == ["notes.md"])
        #expect(git.unstaged.first?.isUntracked == true)
        #expect(git.conflicted.map(\.path) == ["Package.swift"])
        #expect(!git.canCommit)
        #expect(git.branches.map(\.name) == ["main", "feature", "origin/main"])
        #expect(git.commits.map(\.unpushed) == [true, false])
        #expect(git.needsPassword)
        #expect(git.message == "Draft")
    }

    @Test func aFolderWithoutGitSaysSo() {
        let git = CompanionGit.make(status: nil, branches: [], commits: [], operation: nil, message: "", warning: nil, notice: nil, failure: nil)
        #expect(!git.isRepository)
    }

    @Test func readsTheLogAndCutsLongDiffs() {
        let commits = CompanionGit.parseCommits("abc1234\u{1F}Add the shop\u{1F}1700000000\n\nbad line\n")
        #expect(commits.count == 1)
        #expect(commits.first?.subject == "Add the shop")
        #expect(commits.first?.date == Date(timeIntervalSince1970: 1_700_000_000))

        let text = "diff --git a/big.txt b/big.txt\n--- /dev/null\n+++ b/big.txt\n@@ -0,0 +1,2000 @@\n" + (0..<2_000).map { "+line \($0)" }.joined(separator: "\n")
        let unified = UnifiedDiff.parse(text)
        let diff = CompanionGit.diff(unified, path: "big.txt", staged: false)
        #expect(diff.truncated)
        #expect(diff.lines.count == CompanionGit.diffLimit)
        #expect(diff.lines.first?.kind == .hunk)
        #expect(diff.added == CompanionGit.diffLimit - 1)
    }

    @Test func messagesRoundTrip() throws {
        let message = ClientMessage.git(id: "1", project: "shop", action: .commit(message: "Fix the cart", push: true))
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: data) == message)
        #expect(message.id == "1")
    }
}
