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
