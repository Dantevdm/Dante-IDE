@testable import DanteKit
import Foundation
import Testing

struct TaskSpecPathTests {
    @Test func findsSpecsInDanteOrTheRepo() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dante-spec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: ".dante/specs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "docs/plans"), withIntermediateDirectories: true)
        try "a".write(to: root.appending(path: ".dante/specs/limits.md"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appending(path: "docs/plans/remote.md"), atomically: true, encoding: .utf8)

        var task = PlanTask(id: "T-1", title: "t", phase: "build", state: .ready)
        task.spec = "specs/limits.md"
        #expect(task.specPath(in: root) == ".dante/specs/limits.md")
        task.spec = "docs/plans/remote.md"
        #expect(task.specPath(in: root) == "docs/plans/remote.md")
        #expect(task.specURL(in: root)?.lastPathComponent == "remote.md")
        task.spec = "nowhere.md"
        #expect(task.specURL(in: root) == nil && task.specPath(in: root) == ".dante/nowhere.md")
    }
}
