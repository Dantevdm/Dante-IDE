@testable import DanteKit
import Foundation
import Testing

@MainActor
struct WorkspaceTests {
    @Test func listsFoldersFirstAndHidesIgnored() throws {
        let folder = try TemporaryFolder()
        try folder.write("b.swift", "")
        try folder.write("A.md", "")
        try folder.write("file10.txt", "")
        try folder.write("file2.txt", "")
        try folder.makeDirectory("src")
        try folder.makeDirectory("node_modules")
        try folder.makeDirectory(".git")

        let names = try FileTree.listing(of: folder.url).map(\.url.lastPathComponent)
        #expect(names == ["src", "A.md", "b.swift", "file2.txt", "file10.txt"])
    }

    @Test func expandingLoadsChildrenOnce() throws {
        let folder = try TemporaryFolder()
        try folder.write("src/main.swift", "")
        let workspace = Workspace(url: folder.url)
        let src = try #require(workspace.root.children?.first)
        #expect(src.children == nil)
        src.toggle()
        #expect(src.isExpanded)
        #expect(src.children?.map(\.name) == ["main.swift"])
    }

    @Test func reopeningAFileReusesItsTab() throws {
        let folder = try TemporaryFolder()
        let a = try folder.write("a.ts", "let a = 1")
        let b = try folder.write("b.ts", "let b = 2")
        let workspace = Workspace(url: folder.url)

        let first = try workspace.open(a)
        try workspace.open(b)
        let again = try workspace.open(a)

        #expect(workspace.documents.count == 2)
        #expect(first.id == again.id)
        #expect(workspace.activeDocumentID == first.id)
    }

    @Test func closingActivatesNeighbour() throws {
        let folder = try TemporaryFolder()
        let workspace = Workspace(url: folder.url)
        let docs = try ["a", "b", "c"].map { try workspace.open(try folder.write("\($0).txt", $0)) }

        workspace.activeDocumentID = docs[1].id
        workspace.close(docs[1])
        #expect(workspace.activeDocumentID == docs[2].id)

        workspace.close(docs[2])
        #expect(workspace.activeDocumentID == docs[0].id)

        workspace.close(docs[0])
        #expect(workspace.activeDocumentID == nil)
    }

    @Test func editingMarksDirtyAndSavingWrites() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("notes.md", "# Hi")
        let document = try EditorDocument(url: file)
        #expect(!document.isDirty)

        document.text = "# Hello"
        #expect(document.isDirty)
        // Undoing back to the saved text isn't a change.
        document.text = "# Hi"
        #expect(!document.isDirty)
        document.text = "# Hello"

        try document.save()
        #expect(!document.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "# Hello")
        document.text = "# Hi"
        #expect(document.isDirty)
    }

    @Test func refusesBinaryFiles() throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "image.bin")
        try Data([0xFF, 0xFE, 0x00, 0xC3, 0x28]).write(to: file)
        #expect(throws: DocumentError.self) { try EditorDocument(url: file) }
    }

    @Test func detectsLanguages() {
        #expect(Language(url: URL(filePath: "/a/App.swift")) == .swift)
        #expect(Language(url: URL(filePath: "/a/index.tsx")) == .typescript)
        #expect(Language(url: URL(filePath: "/a/Dockerfile")) == .dockerfile)
        #expect(Language(url: URL(filePath: "/a/compose.yml")) == .yaml)
        #expect(Language(url: URL(filePath: "/a/LICENSE")) == .plain)
    }
}

@MainActor
struct FileChangedTests {
    @Test func reloadsCleanDocumentsAndKeepsDirtyOnes() throws {
        let folder = try TemporaryFolder()
        let clean = try folder.write("clean.txt", "old")
        let dirty = try folder.write("dirty.txt", "old")
        let workspace = Workspace(url: folder.url)
        let cleanDocument = try workspace.open(clean)
        let dirtyDocument = try workspace.open(dirty)
        dirtyDocument.text = "my edit"

        try "new".write(to: clean, atomically: true, encoding: .utf8)
        try "new".write(to: dirty, atomically: true, encoding: .utf8)
        #expect(workspace.fileChanged(at: clean))
        #expect(!workspace.fileChanged(at: dirty))
        #expect(cleanDocument.text == "new" && !cleanDocument.isDirty)
        #expect(dirtyDocument.text == "my edit")
    }

    @Test func newFilesAppearInLoadedFolders() throws {
        let folder = try TemporaryFolder()
        let workspace = Workspace(url: folder.url)
        let file = try folder.write("added.swift", "")
        workspace.fileChanged(at: file)
        #expect(workspace.root.children?.map(\.name) == ["added.swift"])
    }
}

@MainActor
struct ExternalChangeTests {
    @Test func reloadsTabsRefreshesFoldersAndSpotsBranchMoves() throws {
        let folder = try TemporaryFolder()
        let open = try folder.write("a.txt", "one")
        let workspace = Workspace(url: folder.url)
        let document = try workspace.open(open)

        try "two".write(to: open, atomically: true, encoding: .utf8)
        let added = try folder.write("b.txt", "")
        let changes = workspace.applyExternalChanges([open, added, folder.url.appending(path: ".git/HEAD")])

        #expect(document.text == "two")
        #expect(workspace.root.children?.map(\.name) == ["a.txt", "b.txt"])
        #expect(changes.gitHeadChanged)
        #expect(changes.conflicts.isEmpty)
    }

    @Test func reportsConflictsInsteadOfOverwritingEdits() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("a.txt", "one")
        let workspace = Workspace(url: folder.url)
        let document = try workspace.open(file)
        document.text = "mine"
        try "theirs".write(to: file, atomically: true, encoding: .utf8)
        #expect(workspace.applyExternalChanges([file]).conflicts == [file])
        #expect(document.text == "mine")
    }

    @Test func mapsSymlinkResolvedPathsBackToTheProject() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("a.txt", "one")
        let workspace = Workspace(url: folder.url)
        let document = try workspace.open(file)
        try "two".write(to: file, atomically: true, encoding: .utf8)
        // FSEvents reports /private/var/... for files under /var/...
        workspace.applyExternalChanges([file.resolvingSymlinksInPath()])
        #expect(document.text == "two")
    }

    @Test func ignoresBuildFolders() throws {
        let folder = try TemporaryFolder()
        let workspace = Workspace(url: folder.url)
        let changes = workspace.applyExternalChanges([folder.url.appending(path: ".build/x.o")])
        #expect(changes == .init())
    }
}

@MainActor @Suite struct SplitEditorTests {
    @Test func panesSwapFocusAndFollowClosingTabs() throws {
        let folder = try TemporaryFolder()
        try folder.write("a.swift", "a")
        try folder.write("b.swift", "b")
        try folder.write("c.swift", "c")
        let workspace = Workspace(url: folder.url)
        let a = try workspace.open(folder.url.appending(path: "a.swift"))
        workspace.splitEditor()
        #expect(workspace.panes?.left === a && workspace.panes?.right === a)

        // A tab opens in the focused (right) pane.
        let b = try workspace.open(folder.url.appending(path: "b.swift"))
        #expect(workspace.panes?.left === a && workspace.panes?.right === b && workspace.activeDocument === b)

        workspace.focusPane(right: false)
        #expect(workspace.activeDocument === a && workspace.panes?.right === b)
        let c = try workspace.open(folder.url.appending(path: "c.swift"))
        #expect(workspace.panes?.left === c && workspace.panes?.right === b)

        // Closing the other pane's file leaves one pane.
        workspace.close(b)
        #expect(workspace.split == nil && workspace.activeDocument === c)

        // Closing the focused pane's file hands focus to the other.
        workspace.splitEditor()
        _ = try workspace.open(folder.url.appending(path: "a.swift"))
        workspace.close(a)
        #expect(workspace.split == nil && workspace.activeDocument === c)
    }
}
