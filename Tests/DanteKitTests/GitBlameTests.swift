import Foundation
import Testing
@testable import DanteKit

@Suite struct GitBlameTests {
    let first = String(repeating: "a", count: 40)
    let zero = String(repeating: "0", count: 40)

    @Test func readsPorcelainOutput() {
        let output = """
        \(first) 1 1 2
        author Someone
        author-mail <someone@example.com>
        author-time 1767225600
        author-tz +0000
        summary Add the order type
        filename Sources/Order.swift
        \tstruct Order {
        \(first) 2 2
        \t    var id: Int
        \(zero) 3 3 1
        author Not Committed Yet
        author-time 1767312000
        summary Version of Sources/Order.swift from Sources/Order.swift
        filename Sources/Order.swift
        \t    var total: Int

        """
        let blame = GitBlame.parse(output)
        #expect(blame.lines.count == 3)
        #expect(blame.commit(atLine: 1)?.author == "Someone" && blame.commit(atLine: 1)?.summary == "Add the order type")
        #expect(blame.commit(atLine: 2)?.shortHash == "aaaaaaa")
        #expect(blame.commit(atLine: 1)?.date == Date(timeIntervalSince1970: 1767225600))
        #expect(blame.commit(atLine: 3)?.isUncommitted == true && blame.commit(atLine: 1)?.isUncommitted == false)
        #expect(blame.commit(atLine: 4) == nil && blame.commit(atLine: 0) == nil)
    }

    @Test func blamesUnsavedText() async throws {
        let folder = try TemporaryFolder()
        try folder.write("a.txt", "one\ntwo\n")
        let git: [String] = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com"]
        _ = await Shell.run(["git", "init", "-q"], in: folder.url)
        _ = await Shell.run(["git", "add", "."], in: folder.url)
        _ = await Shell.run(git + ["commit", "-q", "-m", "Start"], in: folder.url)
        let blame = try #require(await GitBlame.load(file: folder.url.appending(path: "a.txt"), text: "zero\none\ntwo\n", root: folder.url))
        #expect(blame.commit(atLine: 1)?.isUncommitted == true)
        #expect(blame.commit(atLine: 2)?.summary == "Start" && blame.commit(atLine: 3)?.author == "Test")
    }

    @Test func quotesShellArguments() {
        #expect(Shell.quote("Sources/App/main.swift") == "Sources/App/main.swift")
        #expect(Shell.quote("My File.swift") == "'My File.swift'")
        #expect(Shell.quote("it's") == "'it'\\''s'")
        #expect(Shell.quote("") == "''")
    }
}
