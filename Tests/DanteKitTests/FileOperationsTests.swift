import Foundation
import Testing
@testable import DanteKit

@Suite struct FileOperationsTests {
    @Test func checksNames() throws {
        let folder = try TemporaryFolder()
        try folder.write("taken.txt", "")
        #expect(FileOperations.problem(with: "", in: folder.url, allowsSubfolders: true) != nil)
        #expect(FileOperations.problem(with: "taken.txt", in: folder.url, allowsSubfolders: true) != nil)
        #expect(FileOperations.problem(with: "a/b.swift", in: folder.url, allowsSubfolders: false) != nil)
        #expect(FileOperations.problem(with: "a/../b", in: folder.url, allowsSubfolders: true) != nil)
        #expect(FileOperations.problem(with: "a/b.swift", in: folder.url, allowsSubfolders: true) == nil)
        // Renaming a file to its own name, or a change of case, is fine.
        let taken = folder.url.appending(path: "taken.txt")
        #expect(FileOperations.problem(with: "Taken.txt", in: folder.url, allowsSubfolders: false, current: taken) == nil)
    }

    @Test func createsRenamesDuplicatesAndMoves() throws {
        let folder = try TemporaryFolder()
        let file = try FileOperations.createFile(named: "views/Login.swift", in: folder.url)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let renamed = try FileOperations.rename(file, to: "SignIn.swift")
        #expect(renamed.lastPathComponent == "SignIn.swift" && !FileManager.default.fileExists(atPath: file.path))
        let recased = try FileOperations.rename(renamed, to: "signin.swift")
        #expect(try FileManager.default.contentsOfDirectory(atPath: recased.deletingLastPathComponent().path) == ["signin.swift"])

        let copy = try FileOperations.duplicate(recased)
        #expect(copy.lastPathComponent == "signin copy.swift")
        #expect(try FileOperations.duplicate(recased).lastPathComponent == "signin copy 2.swift")

        let other = try FileOperations.createFolder(named: "other", in: folder.url)
        let moved = try FileOperations.move(copy, into: other)
        #expect(moved.deletingLastPathComponent().lastPathComponent == "other")
        #expect(throws: FileOperations.Failure.self) { try FileOperations.move(other, into: other) }
        #expect(throws: FileOperations.Failure.self) { try FileOperations.rename(moved, to: "x/y") }
    }

    @Test func duplicateNamesWithoutExtensions() {
        let taken: Set<String> = ["Makefile copy"]
        #expect(FileOperations.duplicateName(for: URL(filePath: "/p/Makefile")) { taken.contains($0) } == "Makefile copy 2")
    }

    @Test func relocatesPathsInsideAMovedFolder() {
        let from = URL(filePath: "/p/src"), to = URL(filePath: "/p/lib")
        #expect(FileOperations.relocated(URL(filePath: "/p/src/a/b.swift"), from: from, to: to)?.path == "/p/lib/a/b.swift")
        #expect(FileOperations.relocated(URL(filePath: "/p/src"), from: from, to: to)?.path == "/p/lib")
        #expect(FileOperations.relocated(URL(filePath: "/p/srcx/a"), from: from, to: to) == nil)
    }

    @MainActor @Test func openTabsFollowARename() throws {
        let folder = try TemporaryFolder()
        try folder.write("src/a.swift", "let a = 1")
        let workspace = Workspace(url: folder.url)
        let document = try workspace.open(folder.url.appending(path: "src/a.swift"))
        document.text = "let a = 2"
        let newFolder = try FileOperations.rename(folder.url.appending(path: "src"), to: "lib")
        let moved = workspace.itemMoved(from: folder.url.appending(path: "src"), to: newFolder)
        #expect(moved.count == 1 && document.url.path.hasSuffix("/lib/a.swift") && document.isDirty)
        try document.save()
        #expect(try String(contentsOf: newFolder.appending(path: "a.swift"), encoding: .utf8) == "let a = 2")
    }
}
