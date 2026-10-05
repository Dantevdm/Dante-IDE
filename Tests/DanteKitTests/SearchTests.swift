import Foundation
import Testing
@testable import DanteKit

struct FuzzyMatchTests {
    private let paths = [
        "Sources/DanteEditor/Editor/CodeEditorView.swift",
        "Sources/DanteApp/Views/Workspace/WorkspaceView.swift",
        "Sources/DanteKit/Project/Workspace.swift",
        "Sources/DanteApp/Views/Workspace/ExplorerView.swift",
        "README.md",
    ]

    @Test func requiresCharactersInOrder() {
        #expect(FuzzyMatch.match("cev", in: "CodeEditorView.swift") != nil)
        #expect(FuzzyMatch.match("vec", in: "CodeEditorView.swift") == nil)
    }

    @Test func prefersWordStartsInTheFileName() {
        #expect(FuzzyMatch.rank("cev", in: paths).first?.path == "Sources/DanteEditor/Editor/CodeEditorView.swift")
        #expect(FuzzyMatch.rank("wsv", in: paths).first?.path == "Sources/DanteApp/Views/Workspace/WorkspaceView.swift")
    }

    @Test func shorterPathWinsATie() {
        #expect(FuzzyMatch.rank("workspace", in: paths).first?.path == "Sources/DanteKit/Project/Workspace.swift")
    }

    @Test func matchesAcrossFolders() {
        let ranked = FuzzyMatch.rank("app/explorer", in: paths)
        #expect(ranked.first?.path == "Sources/DanteApp/Views/Workspace/ExplorerView.swift")
    }

    @Test func reportsMatchedOffsets() {
        #expect(FuzzyMatch.match("rd", in: "README.md")?.indices == [0, 3])
    }
}

struct FileIndexTests {
    @Test func listsFilesAndSkipsBuildOutput() throws {
        let folder = try TemporaryFolder()
        try folder.write("Sources/App.swift", "")
        try folder.write(".dante/project.yaml", "")
        try folder.write("node_modules/x/index.js", "")
        try folder.write(".build/debug/thing", "")
        try folder.write("build/Dante.app/Contents/Info.plist", "")
        #expect(FileIndex.scan(folder.url) == [".dante/project.yaml", "Sources/App.swift"])
    }
}
