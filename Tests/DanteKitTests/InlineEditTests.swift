import Foundation
import Testing
@testable import DanteKit

@Suite struct InlineEditTests {
    @Test func widensSelectionsToWholeLines() {
        let text = "one\n  two three\nfour\n" as NSString
        // Part of line 2 becomes all of it, newline included.
        #expect(text.substring(with: InlineEdit.lineRange(for: NSRange(location: 6, length: 3), in: text)) == "  two three\n")
        // A selection ending at the start of a line doesn't take that line.
        #expect(text.substring(with: InlineEdit.lineRange(for: NSRange(location: 0, length: 4), in: text)) == "one\n")
        #expect(InlineEdit.lineRange(for: NSRange(location: 5, length: 0), in: text) == NSRange(location: 5, length: 0))
    }

    @Test func promptsWithTheSelectionOrTheCursor() {
        let text = "let a = 1\nlet b = 2\n" as NSString
        let replacing = InlineEdit.prompt(instruction: "rename b to c", path: "x.swift", language: .swift, text: text, range: NSRange(location: 10, length: 10))
        #expect(replacing.contains("<selection>\nlet b = 2\n</selection>") && replacing.contains("rename b to c"))
        let inserting = InlineEdit.prompt(instruction: "add c", path: "x.swift", language: .swift, text: text, range: NSRange(location: 10, length: 0))
        #expect(inserting.contains("let a = 1\n<cursor/>let b = 2"))
        let refining = InlineEdit.prompt(instruction: "shorter", path: "x.swift", language: .swift, text: text, range: NSRange(location: 10, length: 10), previous: "let c = 2\n")
        #expect(refining.contains("previous attempt") && refining.hasSuffix("Reply with the code that replaces the selection."))
    }

    @Test func cleansTheAnswer() {
        #expect(InlineEdit.clean("```swift\nlet c = 2\n```\n", replacing: "let b = 2\n") == "let c = 2\n")
        #expect(InlineEdit.clean("Here's the code:\n    return x", replacing: "    return y") == "    return x")
        #expect(InlineEdit.clean("\n\nfoo()\n\n", replacing: "") == "foo()")
    }
}
