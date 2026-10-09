import Foundation
import Testing
@testable import DanteKit

@Suite struct ExplorerSelectionTests {
    let rows = ["a", "b", "b/c.txt", "d.txt", "e.txt"].map { URL(filePath: "/home/me/p/\($0)") }

    @Test func followsFindersClickRules() {
        var selection = ExplorerSelection()
        selection.click(rows[1], .plain, visible: rows)
        selection.click(rows[3], .toggle, visible: rows)
        #expect(selection.items == [rows[1], rows[3]] && selection.anchor == rows[3])
        selection.click(rows[1], .toggle, visible: rows)
        #expect(selection.items == [rows[3]])
        selection.click(rows[0], .range, visible: rows)
        #expect(selection.items == Array(rows[0...3]))
        // Without an anchor in view, a range click is a plain one.
        selection.click(URL(filePath: "/elsewhere"), .plain, visible: rows)
        selection.click(rows[4], .range, visible: rows)
        #expect(selection.items == [rows[4]])
    }

    @Test func actsOnceOnAFolderAndItsContents() {
        var selection = ExplorerSelection()
        selection.select([rows[1], rows[2], rows[3]])
        #expect(selection.topLevel == [rows[1], rows[3]])
        selection.update { $0 != rows[3] }
        #expect(selection.items == [rows[1], rows[2]] && selection.anchor == rows[2])
    }

    @Test func resolvesFileReferenceURLs() throws {
        let folder = try TemporaryFolder()
        try folder.write("note.txt", "x")
        let url = folder.url.appending(path: "note.txt")
        let reference = try #require((url as NSURL).fileReferenceURL())
        #expect(reference.path != url.path || reference.absoluteString.contains(".file/id="))
        #expect(FileOperations.resolved(reference).lastPathComponent == "note.txt")
        #expect(FileOperations.resolved(url).lastPathComponent == "note.txt")
    }
}
