@testable import DanteEditor
import DanteKit
import Foundation
import Testing

struct TreeSitterHighlighterTests {
    /// The colour each word ends up with: later tokens override earlier ones, as in the editor.
    private func kind(of word: String, in text: String, _ language: Language) throws -> TokenKind? {
        let highlighter = try #require(TreeSitterHighlighter.make(for: language))
        let target = (text as NSString).range(of: word)
        return highlighter.tokens(in: text).last { NSIntersectionRange($0.range, target) == target }?.kind
    }

    @Test(arguments: [Language.swift, .python, .javascript, .typescript, .go, .rust, .json])
    func grammarAndQueriesLoad(language: Language) {
        #expect(TreeSitterHighlighter.make(for: language) != nil)
    }

    @Test func otherLanguagesFallBackToRegex() {
        #expect(TreeSitterHighlighter.make(for: .yaml) == nil)
        #expect(Highlighters.make(for: .yaml) is RegexHighlighter)
        #expect(Highlighters.make(for: .swift) is TreeSitterHighlighter)
    }

    @Test func swift() throws {
        let source = """
        // Totals
        struct Ledger: Codable {
            func total(of items: [Int]) -> Int { items.reduce(0, +) + 42 }
            let name = "main"
        }
        """
        #expect(try kind(of: "struct", in: source, .swift) == .keyword)
        #expect(try kind(of: "Ledger", in: source, .swift) == .type)
        #expect(try kind(of: "Codable", in: source, .swift) == .type)
        #expect(try kind(of: "total", in: source, .swift) == .function)
        #expect(try kind(of: "42", in: source, .swift) == .number)
        #expect(try kind(of: "main", in: source, .swift) == .string)
        #expect(try kind(of: "// Totals", in: source, .swift) == .comment)
    }

    @Test func typescriptUsesJavaScriptQueriesToo() throws {
        let source = "export async function check(amount: Money): Promise<void> { return minor(500); }"
        #expect(try kind(of: "export", in: source, .typescript) == .keyword)
        #expect(try kind(of: "check", in: source, .typescript) == .function)
        #expect(try kind(of: "Money", in: source, .typescript) == .type)
        #expect(try kind(of: "500", in: source, .typescript) == .number)
    }

    @Test func pythonAndGo() throws {
        #expect(try kind(of: "def", in: "def handler(event):\n    return 'ok'  # done", .python) == .keyword)
        #expect(try kind(of: "# done", in: "def handler(event):\n    return 'ok'  # done", .python) == .comment)
        #expect(try kind(of: "func", in: "package main\nfunc main() { fmt.Println(\"hi\") }", .go) == .keyword)
        #expect(try kind(of: "\"hi\"", in: "package main\nfunc main() { fmt.Println(\"hi\") }", .go) == .string)
    }

    @Test func captureNames() {
        #expect(TreeSitterHighlighter.kind(forCapture: "keyword.function") == .keyword)
        #expect(TreeSitterHighlighter.kind(forCapture: "function.method.call") == .function)
        #expect(TreeSitterHighlighter.kind(forCapture: "string.special.key") == .string)
        #expect(TreeSitterHighlighter.kind(forCapture: "comment.documentation") == .comment)
        #expect(TreeSitterHighlighter.kind(forCapture: "constant.builtin") == .keyword)
        #expect(TreeSitterHighlighter.kind(forCapture: "variable.parameter") == nil)
        #expect(TreeSitterHighlighter.kind(forCapture: "punctuation.bracket") == nil)
    }
}
