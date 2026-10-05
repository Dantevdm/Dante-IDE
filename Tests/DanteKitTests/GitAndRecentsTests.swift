import DanteKit
import Foundation
import Testing

struct GitTests {
    @Test func readsBranchFromHead() throws {
        let folder = try TemporaryFolder()
        try folder.write(".git/HEAD", "ref: refs/heads/feat/transfer-limits\n")
        #expect(Git.currentBranch(in: folder.url) == "feat/transfer-limits")
    }

    @Test func detachedHeadShowsShortHash() throws {
        let folder = try TemporaryFolder()
        try folder.write(".git/HEAD", "4f2a1c9e0b7d\n")
        #expect(Git.currentBranch(in: folder.url) == "4f2a1c9")
    }

    @Test func notARepository() throws {
        let folder = try TemporaryFolder()
        #expect(Git.currentBranch(in: folder.url) == nil)
    }

    @Test func cloneFolderNames() {
        #expect(Git.cloneFolderName(for: "https://github.com/Dantevdm/Dante-IDE.git") == "Dante-IDE")
        #expect(Git.cloneFolderName(for: "git@github.com:owner/repo.git") == "repo")
        #expect(Git.cloneFolderName(for: "https://example.com/a/b/") == "b")
        #expect(Git.cloneFolderName(for: "   ") == nil)
    }
}

@MainActor
struct RecentProjectsTests {
    @Test func mostRecentFirstWithoutDuplicates() throws {
        let defaults = try #require(UserDefaults(suiteName: "dante-tests-\(UUID().uuidString)"))
        let recents = RecentProjects(defaults: defaults)
        recents.note(URL(filePath: "/tmp/a"))
        recents.note(URL(filePath: "/tmp/b"))
        recents.note(URL(filePath: "/tmp/a"))
        #expect(recents.items.map(\.name) == ["a", "b"])

        // Persists across instances.
        #expect(RecentProjects(defaults: defaults).items.map(\.name) == ["a", "b"])
    }

    @Test func keepsAtMostTheLimit() throws {
        let defaults = try #require(UserDefaults(suiteName: "dante-tests-\(UUID().uuidString)"))
        let recents = RecentProjects(defaults: defaults)
        for index in 0..<(RecentProjects.limit + 3) {
            recents.note(URL(filePath: "/tmp/p\(index)"))
        }
        #expect(recents.items.count == RecentProjects.limit)
        #expect(recents.items.first?.name == "p\(RecentProjects.limit + 2)")
    }

    @Test func themesCycle() {
        #expect(ThemeID.dark.next == .light)
        #expect(ThemeID.paper.next == .dark)
    }
}

struct GitGutterTests {
    let base = "one\ntwo\nthree\nfour\n"

    @Test func addedModifiedAndDeleted() {
        #expect(GitGutter.changes(base: base, current: base).isEmpty)
        #expect(GitGutter.changes(base: base, current: "one\ntwo\nnew\nthree\nfour\n") == [2: .added])
        #expect(GitGutter.changes(base: base, current: "one\nTWO\nthree\nfour\n") == [1: .modified])
        #expect(GitGutter.changes(base: base, current: "one\nthree\nfour\n") == [1: .deleted])
    }

    @Test func replacingWithMoreLinesIsModifiedThenAdded() {
        #expect(GitGutter.changes(base: base, current: "one\nA\nB\nthree\nfour\n") == [1: .modified, 2: .added])
    }

    @Test func deletingTheEndMarksTheLastLine() {
        #expect(GitGutter.changes(base: base, current: "one\ntwo\n") == [1: .deleted])
    }

    @Test func headTextOfACommittedFile() async throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("a.txt", "  indented\n")
        _ = await Shell.run(["git", "init", "-q"], in: folder.url)
        _ = await Shell.run(["git", "add", "."], in: folder.url)
        _ = await Shell.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "x"], in: folder.url)
        #expect(await GitGutter.headText(of: file, in: folder.url) == "  indented\n")
        let untracked = try folder.write("b.txt", "new\n")
        #expect(await GitGutter.headText(of: untracked, in: folder.url) == nil)
    }
}
