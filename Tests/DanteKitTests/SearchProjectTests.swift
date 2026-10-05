import Foundation
import Testing
@testable import DanteKit

struct ProjectSearchTests {
    private func find(_ text: String, _ query: ProjectSearch.Query) -> [ProjectSearch.Match] {
        ProjectSearch.matches(in: text, expression: query.expression!)
    }

    @Test func linesColumnsAndPreview() {
        let matches = find("let a = 1\n    let total = count\nprint(total)\n", .init(text: "total"))
        #expect(matches.map(\.line) == [1, 2])
        #expect(matches[0].column == 8)
        #expect(matches[0].preview == "let total = count")
        #expect((matches[0].preview as NSString).substring(with: matches[0].previewRange) == "total")
    }

    @Test func options() {
        let text = "Total total totally"
        #expect(find(text, .init(text: "total")).count == 3)
        #expect(find(text, .init(text: "total", caseSensitive: true)).count == 2)
        #expect(find(text, .init(text: "total", wholeWord: true)).count == 2)
        #expect(find(text, .init(text: "tot.l", isRegex: true)).count == 3)
        // Not a regex: the dot is literal.
        #expect(find(text, .init(text: "tot.l")).isEmpty)
        #expect(ProjectSearch.Query(text: "(", isRegex: true).expression == nil)
        #expect(ProjectSearch.Query(text: "").expression == nil)
    }

    @Test func longLinesAreCutAroundTheMatch() {
        let line = String(repeating: "x", count: 300) + "needle" + String(repeating: "y", count: 300)
        let match = find(line, .init(text: "needle"))[0]
        #expect(match.preview.hasPrefix("…"))
        #expect(match.preview.hasSuffix("…"))
        #expect((match.preview as NSString).substring(with: match.previewRange) == "needle")
    }

    @Test func runSkipsBinaryFiles() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.txt", "find me\n")
        try Data([0x66, 0x69, 0x6E, 0x64, 0x00, 0x20, 0x6D, 0x65]).write(to: folder.url.appending(path: "b.bin"))
        let result = await ProjectSearch.run(.init(text: "find"), root: folder.url, paths: ["a.txt", "b.bin", "missing.txt"])
        #expect(result.files.map(\.path) == ["a.txt"])
        #expect(result.matchCount == 1)
    }
}
