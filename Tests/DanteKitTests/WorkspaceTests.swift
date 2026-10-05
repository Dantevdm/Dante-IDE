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

        try document.save()
        #expect(!document.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "# Hello")
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
