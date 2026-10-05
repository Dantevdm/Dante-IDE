import DanteEditor
import DanteKit
import Foundation
import Testing

struct HighlighterTests {
    private func kinds(_ text: String, _ language: Language) -> [(String, TokenKind)] {
        let ns = text as NSString
        return Highlighters.make(for: language).tokens(in: text).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func kind(of word: String, in text: String, _ language: Language) -> TokenKind? {
        kinds(text, language).first { $0.0 == word }?.1
    }

    @Test func typescriptBasics() {
        let source = #"export async function checkDailyLimit(amount: Money) { return minor(500_000); }"#
        #expect(kind(of: "export", in: source, .typescript) == .keyword)
        #expect(kind(of: "checkDailyLimit", in: source, .typescript) == .function)
        #expect(kind(of: "Money", in: source, .typescript) == .type)
        #expect(kind(of: "500_000", in: source, .typescript) == .number)
    }

    @Test func commentMarkersInsideStringsStayStrings() {
        let tokens = kinds(#"let url = "https://example.com"; // real comment"#, .typescript)
        #expect(tokens.contains { $0.0 == #""https://example.com""# && $0.1 == .string })
        #expect(tokens.contains { $0.0 == "// real comment" && $0.1 == .comment })
    }

    @Test func keywordsInsideCommentsAreNotKeywords() {
        let tokens = kinds("/* return if */ return", .swift)
        #expect(tokens.filter { $0.1 == .keyword }.count == 1)
        #expect(tokens.first?.1 == .comment)
    }

    @Test func swiftMultilineString() {
        let source = "let s = \"\"\"\nhello // not a comment\n\"\"\""
        let tokens = kinds(source, .swift)
        #expect(tokens.contains { $0.1 == .string && $0.0.contains("not a comment") })
        #expect(!tokens.contains { $0.1 == .comment })
    }

    @Test func identifierContainingKeywordIsNotAKeyword() {
        #expect(kind(of: "format", in: "let format = 1", .swift) == nil)
        #expect(kinds("let format = 1", .swift).filter { $0.1 == .keyword }.map(\.0) == ["let"])
    }

    @Test func yamlKeysAndComments() {
        let tokens = kinds("lifecycle:\n  current: build # here\n", .yaml)
        #expect(tokens.contains { $0.0 == "lifecycle" && $0.1 == .function })
        #expect(tokens.contains { $0.0 == "current" && $0.1 == .function })
        #expect(tokens.contains { $0.0 == "# here" && $0.1 == .comment })
    }

    @Test func pythonHashComment() {
        #expect(kinds("x = 1  # note", .python).contains { $0.0 == "# note" && $0.1 == .comment })
    }

    @Test func unterminatedBlockCommentRunsToEnd() {
        let tokens = kinds("a /* open\nstill open", .typescript)
        #expect(tokens.last?.1 == .comment)
        #expect(tokens.last?.0.hasSuffix("still open") == true)
    }

    @Test func tokensDoNotOverlap() {
        let source = #"const s = `tpl ${x}`; function f(A) { return 0x1F + 2.5e3 } // done"#
        let ranges = Highlighters.make(for: .javascript).tokens(in: source).map(\.range)
        for (lhs, rhs) in zip(ranges, ranges.dropFirst()) {
            #expect(NSMaxRange(lhs) <= rhs.location)
        }
    }
}
