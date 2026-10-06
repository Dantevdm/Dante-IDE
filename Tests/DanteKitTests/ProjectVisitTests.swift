import Foundation
import Testing
@testable import DanteKit

@MainActor @Suite struct ProjectVisitTests {
    @Test func remembersVisitsPerProject() {
        let name = "dante-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let visit = ProjectVisit(date: Date(timeIntervalSince1970: 1_000), head: "abc", branch: "main", taskStates: ["X-1": .review])
        visit.save(for: URL(filePath: "/p/one"), defaults: defaults)
        #expect(ProjectVisit.load(for: URL(filePath: "/p/one"), defaults: defaults) == visit)
        #expect(ProjectVisit.load(for: URL(filePath: "/p/two"), defaults: defaults) == nil)
    }

    @Test func listsTasksThatMovedOrAreNew() {
        let tasks = [
            PlanTask(id: "X-1", title: "Same", phase: "build", state: .ready),
            PlanTask(id: "X-2", title: "Moved", phase: "build", state: .done),
            PlanTask(id: "X-3", title: "New", phase: "build", state: .ready),
        ]
        let moves = SinceLastVisit.taskMoves(from: ["X-1": .ready, "X-2": .review, "X-9": .done], to: tasks)
        #expect(moves.map(\.id) == ["X-2", "X-3"])
        #expect(moves[0].from == .review && moves[0].to == .done && moves[1].from == nil)
    }

    @Test func readsGitOutput() {
        #expect(SinceLastVisit.parseShortStat(" 3 files changed, 10 insertions(+), 2 deletions(-)") == (3, 10, 2))
        #expect(SinceLastVisit.parseShortStat(" 1 file changed, 1 deletion(-)") == (1, 0, 1))
        let commits = SinceLastVisit.parseLog("aaa\u{1F}Add x\u{1F}Someone\u{1F}2026-01-02T03:04:05Z\nbad line")
        #expect(commits.count == 1 && commits[0].subject == "Add x" && commits[0].date != nil)
    }

    @Test func comparesTheRepositoryWithTheLastVisit() async throws {
        let folder = try TemporaryFolder()
        for command in [["git", "init", "-q", "-b", "main"], ["git", "config", "user.name", "t"], ["git", "config", "user.email", "t@example.com"], ["git", "config", "commit.gpgsign", "false"]] {
            _ = await Shell.run(command, in: folder.url)
        }
        try folder.write("a.txt", "one\n")
        _ = await Shell.run(["git", "add", "-A"], in: folder.url)
        _ = await Shell.run(["git", "commit", "-q", "-m", "First"], in: folder.url)
        let visit = ProjectVisit.now(root: folder.url, tasks: [PlanTask(id: "X-1", title: "T", phase: "build")])
        #expect(visit.head == (await Shell.run(["git", "rev-parse", "HEAD"], in: folder.url)).stdout && visit.branch == "main")
        // Packed refs are read too.
        _ = await Shell.run(["git", "pack-refs", "--all"], in: folder.url)
        #expect(Git.headCommit(in: folder.url) == visit.head)

        try folder.write("a.txt", "one\ntwo\n")
        _ = await Shell.run(["git", "commit", "-q", "-am", "Second"], in: folder.url)
        let since = await SinceLastVisit.load(since: visit, root: folder.url, tasks: [PlanTask(id: "X-1", title: "T", phase: "build", state: .done)])
        #expect(since.commits.map(\.subject) == ["Second"])
        #expect(since.filesChanged == 1 && since.insertions == 1)
        #expect(since.taskMoves.first?.to == .done && !since.isEmpty)
    }
}
