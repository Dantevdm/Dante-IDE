import Foundation
import Testing
@testable import DanteKit

struct TaskFileTests {
    @Test func roundTripsThroughYAML() throws {
        let file = TaskFile(prefix: "DAN", tasks: [
            PlanTask(id: "DAN-1", title: "Plan board", phase: "build", state: .inProgress, spec: "specs/plan.md", claude: true),
            PlanTask(id: "DAN-2", title: "Tree-sitter", phase: "build"),
        ])
        let yaml = try file.encode()
        #expect(yaml.contains("state: in_progress"))
        #expect(!yaml.contains("note:"))
        #expect(try TaskFile.decode(yaml) == file)
    }

    @Test func prefixesComeFromTheProjectName() {
        #expect(TaskFile.prefix(forProjectNamed: "Dante IDE") == "DI")
        #expect(TaskFile.prefix(forProjectNamed: "ledger-api") == "LA")
        #expect(TaskFile.prefix(forProjectNamed: "dante") == "DAN")
        #expect(TaskFile.prefix(forProjectNamed: "---") == "TASK")
    }
}

@MainActor
struct TaskBoardTests {
    @Test func addsMovesAndPersists() throws {
        let folder = try TemporaryFolder()
        let board = TaskBoard(projectRoot: folder.url)
        let first = try board.add(title: "First", phase: "Build")
        let second = try board.add(title: "Second", phase: "build")
        #expect(first.id.hasSuffix("-1") && second.id.hasSuffix("-2"))

        try board.move(first.id, to: .done)
        #expect(board.count(in: "Build") == (1, 2))

        let reread = TaskBoard(projectRoot: folder.url)
        #expect(reread.tasks == board.tasks)
        #expect(reread.tasks(in: "build", state: .ready).map(\.title) == ["Second"])
    }

    @Test func aBrokenFileIsReportedAndNotOverwritten() throws {
        let folder = try TemporaryFolder()
        try folder.write(".dante/tasks.yaml", "tasks: [this is: not valid")
        let board = TaskBoard(projectRoot: folder.url)
        #expect(board.loadError != nil)
        #expect(throws: (any Error).self) { try board.add(title: "x", phase: "build") }
        #expect(try String(contentsOf: board.url, encoding: .utf8) == "tasks: [this is: not valid")
    }
}

struct PhaseDocTests {
    private let markdown = """
    # Build

    Turn the agreed design into working,
    reviewed code.

    ## Ready when
    - [x] Design phase done
    - [ ] Local environment boots

    ## Done when
    - [ ] API contract frozen

    ## Notes
    - [ ] not a checklist item
    """

    @Test func readsSummaryAndChecklists() {
        let doc = PhaseDoc.parse(markdown)
        #expect(doc.summary == "Turn the agreed design into working, reviewed code.")
        #expect(doc.readyWhen.map(\.text) == ["Design phase done", "Local environment boots"])
        #expect(doc.readyWhen.map(\.done) == [true, false])
        #expect(doc.doneWhen.map(\.text) == ["API contract frozen"])
    }

    @Test func togglesOneBoxInPlace() {
        let doc = PhaseDoc.parse(markdown)
        let toggled = PhaseDoc.parse(doc.toggling(doc.doneWhen[0]))
        #expect(toggled.doneWhen[0].done)
        #expect(PhaseDoc.parse(toggled.toggling(toggled.readyWhen[0])).readyWhen[0].done == false)
    }

    @Test func templateParses() {
        let doc = PhaseDoc.parse(PhaseDoc.template(for: "Build"))
        #expect(!doc.summary.isEmpty && !doc.readyWhen.isEmpty && !doc.doneWhen.isEmpty)
    }
}

struct SetCurrentPhaseTests {
    @Test func editsTheLineAndKeepsComments() {
        let yaml = "name: X  # the name\n\nlifecycle:\n  template: app@1\n  current: build\n\nother: 1\n"
        let next = Lifecycle.settingCurrent("Test", inProjectYAML: yaml)
        #expect(next == "name: X  # the name\n\nlifecycle:\n  template: app@1\n  current: test\n\nother: 1\n")
        #expect(Lifecycle.parse(projectYAML: next).currentIndex == 4)
    }

    @Test func addsTheKeyOrBlockWhenMissing() {
        #expect(Lifecycle.settingCurrent("design", inProjectYAML: "lifecycle:\n    template: app@1\n") == "lifecycle:\n    current: design\n    template: app@1\n")
        #expect(Lifecycle.settingCurrent("design", inProjectYAML: "name: X\n") == "name: X\n\nlifecycle:\n  current: design\n")
    }
}

@MainActor
struct WorkspacePlanTests {
    @Test func movingPhaseAndTogglingChecklistWriteFiles() throws {
        let folder = try TemporaryFolder()
        let workspace = Workspace(url: folder.url)
        #expect(!workspace.lifecycle.hasSpec)

        try workspace.setCurrentPhase("Design")
        #expect(workspace.lifecycle.currentIndex == 2)

        try workspace.createPhaseDoc("Design")
        let item = try #require(workspace.phaseDocs["design"]?.doneWhen.first)
        try workspace.toggle(item, inPhase: "Design")
        #expect(workspace.phaseDocs["design"]?.doneWhen.first?.done == true)
    }
}
