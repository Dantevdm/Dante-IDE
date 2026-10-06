import Foundation
import Testing
@testable import DanteKit

@Suite struct GitStatusTests {
    @Test func parsesBranchAndChanges() {
        let output = "## main...origin/main [ahead 2, behind 1]\0M  staged.swift\0 M edited.swift\0MM both.swift\0R  new.swift\0old.swift\0?? notes/new file.md\0UU clash.swift\0"
        let status = GitStatus.parse(output)
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2 && status.behind == 1)
        #expect(status.staged.map(\.path) == ["staged.swift", "both.swift", "new.swift"])
        #expect(status.unstaged.map(\.path) == ["edited.swift", "both.swift", "notes/new file.md"])
        #expect(status.conflicted.map(\.path) == ["clash.swift"])
        #expect(status.changes.first { $0.path == "new.swift" }?.oldPath == "old.swift")
        #expect(status.changes.first { $0.path == "notes/new file.md" }?.isUntracked == true)
    }

    @Test func parsesNewAndDetachedRepositories() {
        let fresh = GitStatus.parse("## No commits yet on main\0?? a.txt\0")
        #expect(fresh.isNewRepository && fresh.branch == "main" && fresh.upstream == nil)
        let detached = GitStatus.parse("## HEAD (no branch)\0")
        #expect(detached.branch == nil)
        let local = GitStatus.parse("## feature/x\0")
        #expect(local.branch == "feature/x" && local.upstream == nil && local.ahead == 0)
    }
}

@Suite struct GitBranchTests {
    @Test func hidesRemotesThatALocalBranchTracks() {
        let s = "\u{1F}"
        let output = [
            "refs/heads/main\(s)*\(s)origin/main\(s)1700000000\(s)Fix it",
            "refs/heads/spike\(s) \(s)\(s)1700000100\(s)Try a thing",
            "refs/remotes/origin/HEAD\(s) \(s)\(s)1700000000\(s)Fix it",
            "refs/remotes/origin/main\(s) \(s)\(s)1700000000\(s)Fix it",
            "refs/remotes/origin/feature/login\(s) \(s)\(s)1700000200\(s)Login",
        ].joined(separator: "\n")
        let branches = GitBranch.parse(output)
        #expect(branches.map(\.name) == ["main", "spike", "origin/feature/login"])
        #expect(branches[0].isCurrent && branches[0].upstream == "origin/main")
        #expect(branches[2].isRemote && branches[2].localName == "feature/login")
    }

    @Test func validatesNames() {
        #expect(GitBranch.isValidName("feature/login-v2"))
        for bad in ["", "-x", "a..b", "a b", "a~1", "x.lock", "trail/", "a:b", "@"] {
            #expect(!GitBranch.isValidName(bad), "\(bad)")
        }
    }
}

@Suite struct UnifiedDiffTests {
    @Test func numbersLinesInHunks() {
        let diff = UnifiedDiff.parse("""
        diff --git a/a.txt b/a.txt
        index 1..2 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@ heading
         one
        -two
        +TWO
         three
        \\ No newline at end of file
        @@ -10,2 +10,3 @@
         ten
        +ten and a half
         eleven
        """)
        #expect(diff.hunks.count == 2)
        #expect(diff.added == 2 && diff.removed == 1)
        let first = diff.hunks[0].lines
        #expect(first.map(\.kind) == [.context, .removed, .added, .context])
        #expect(first[1].oldNumber == 2 && first[1].newNumber == nil)
        #expect(first[2].newNumber == 2 && first[3].oldNumber == 3 && first[3].newNumber == 3)
        #expect(diff.hunks[1].lines[1].newNumber == 11)
    }

    @Test func showsANewFileAsAdded() {
        let diff = UnifiedDiff.added("a\nb\n")
        #expect(diff.added == 2 && diff.hunks[0].lines.last?.newNumber == 2)
    }
}

@Suite struct GitRepositoryTests {
    private func repository() async throws -> TemporaryFolder {
        let folder = try TemporaryFolder()
        for command in [["git", "init", "-q", "-b", "main"], ["git", "config", "user.name", "t"], ["git", "config", "user.email", "t@example.com"], ["git", "config", "commit.gpgsign", "false"]] {
            _ = await Shell.run(command, in: folder.url)
        }
        return folder
    }

    @Test func stagesCommitsAndBranches() async throws {
        let folder = try await repository()
        try folder.write("a.txt", "one\n")
        var status = try #require(await GitRepository.status(in: folder.url))
        #expect(status.isNewRepository && status.unstaged.map(\.path) == ["a.txt"])

        try await GitRepository.stage(["a.txt"], in: folder.url)
        try await GitRepository.unstage(["a.txt"], in: folder.url, newRepository: true)
        status = try #require(await GitRepository.status(in: folder.url))
        #expect(status.staged.isEmpty)

        try await GitRepository.stageAll(in: folder.url)
        try await GitRepository.commit(message: "First", in: folder.url)
        try folder.write("a.txt", "one\ntwo\n")
        status = try #require(await GitRepository.status(in: folder.url))
        #expect(!status.isNewRepository && status.unstaged.first?.unstaged == .modified)

        let diff = await GitRepository.diff(of: status.unstaged[0], staged: false, in: folder.url)
        #expect(diff.added == 1 && diff.hunks[0].lines.last?.text == "two")

        try await GitRepository.stage(["a.txt"], in: folder.url)
        #expect(await GitRepository.stagedDiff(in: folder.url).contains("+two"))
        try await GitRepository.unstage(["a.txt"], in: folder.url, newRepository: false)
        try await GitRepository.discard(status.unstaged, in: folder.url)
        #expect(try String(contentsOf: folder.url.appending(path: "a.txt"), encoding: .utf8) == "one\n")

        try await GitRepository.createBranch("feature/x", in: folder.url)
        let branches = await GitRepository.branches(in: folder.url)
        #expect(Set(branches.map(\.name)) == ["main", "feature/x"])
        #expect(branches.first { $0.isCurrent }?.name == "feature/x")
        try await GitRepository.checkout(branches.first { $0.name == "main" }!, in: folder.url)
        #expect(Git.currentBranch(in: folder.url) == "main")
        #expect(await GitRepository.recentSubjects(in: folder.url) == ["First"])
    }

    @Test func pushWithoutARemoteSaysSo() async throws {
        let folder = try await repository()
        await #expect(throws: GitRepository.Failure.self) {
            try await GitRepository.push(branch: "main", hasUpstream: false, in: folder.url)
        }
    }
}

@Suite struct CommitMessageTests {
    @Test func cleansTheAnswer() {
        #expect(CommitMessage.clean("Here's a commit message:\n```\nFix the login race\n\nIt raced.\n```") == "Fix the login race\n\nIt raced.")
        #expect(CommitMessage.clean("\"Add tabs\"") == "Add tabs")
        #expect(CommitMessage.clean("  Add tabs\n") == "Add tabs")
    }

    @Test func promptCarriesStyleAndTasks() {
        let prompt = CommitMessage.prompt(diff: "+x", recentSubjects: ["Add a thing"], tasks: ["DI-1 Build it"])
        #expect(prompt.contains("- Add a thing") && prompt.contains("- DI-1 Build it") && prompt.hasSuffix("+x"))
    }
}
