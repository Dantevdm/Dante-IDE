import Foundation
import Testing
@testable import DanteKit

@Suite struct ProjectReplaceTests {
    @Test func replacesEveryMatchOrOnlyChosenOnes() {
        let text = "let total = 1\nprint(total)\nlet subtotal = total\n"
        let query = ProjectSearch.Query(text: "total", wholeWord: true)
        let all = ProjectReplace.apply(query, replacement: "sum", to: text)
        #expect(all.text == "let sum = 1\nprint(sum)\nlet subtotal = sum\n" && all.count == 3)

        // Ids are the ones search gives its matches.
        let ids = ProjectSearch.matches(in: text, expression: query.expression!).map(\.id)
        #expect(ids == ["0:4", "1:6", "2:15"])
        let one = ProjectReplace.apply(query, replacement: "sum", to: text) { $0 == "1:6" }
        #expect(one.text == "let total = 1\nprint(sum)\nlet subtotal = total\n" && one.count == 1)
        #expect(ProjectReplace.apply(query, replacement: "sum", to: text) { _ in false }.count == 0)
    }

    @Test func plainQueriesTakeTheReplacementLiterally() {
        let query = ProjectSearch.Query(text: "price")
        #expect(ProjectReplace.apply(query, replacement: "$1 cost\\n", to: "price: 3").text == "$1 cost\\n: 3")
    }

    @Test func regexQueriesUseGroups() {
        let query = ProjectSearch.Query(text: #"(\w+)\.count"#, isRegex: true)
        let result = ProjectReplace.apply(query, replacement: "len($1)", to: "a.count + items.count")
        #expect(result.text == "len(a) + len(items)" && result.count == 2)
        #expect(ProjectReplace.preview(of: "items.count", query: query, replacement: "len($1)") == "len(items)")
    }

    @Test func searchesUnsavedTextOfOpenFiles() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.swift", "let old = 1")
        let query = ProjectSearch.Query(text: "fresh")
        let onDisk = await ProjectSearch.run(query, root: folder.url, paths: ["a.swift"])
        let open = await ProjectSearch.run(query, root: folder.url, paths: ["a.swift"], overrides: ["a.swift": "let fresh = 1"])
        #expect(onDisk.matchCount == 0 && open.matchCount == 1)
        #expect(open.files.first?.matches.first?.matched == "fresh")
    }
}
