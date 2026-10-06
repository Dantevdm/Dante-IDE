import Foundation
import Testing
@testable import DanteKit

@Suite struct SymbolsTests {
    let url = URL(filePath: "/p/Cart.swift")

    @Test func readsNestedDocumentSymbols() {
        let json = JSONValue(line: """
        [{"name":"Cart","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":9,"character":1}},
          "selectionRange":{"start":{"line":0,"character":7},"end":{"line":0,"character":11}},
          "children":[{"name":"add(_:)","kind":6,"range":{"start":{"line":2,"character":4},"end":{"line":4,"character":5}},
                       "selectionRange":{"start":{"line":2,"character":9},"end":{"line":2,"character":12}}}]}]
        """)!
        let symbols = CodeSymbol.list(json, in: url)
        #expect(symbols.map(\.name) == ["Cart", "add(_:)"])
        #expect(symbols[0].kind == .type && symbols[1].kind == .method && symbols[1].container == "Cart")
        #expect(symbols[1].range.start == LSPPosition(line: 2, character: 9))
    }

    @Test func readsSymbolInformation() {
        let json = JSONValue(line: """
        [{"name":"total","kind":12,"containerName":"","location":{"uri":"file:///p/Totals.swift","range":{"start":{"line":3,"character":5},"end":{"line":3,"character":10}}}},
         {"name":"Shop","kind":2,"location":{"uri":"file:///p/Shop.swift"}}]
        """)!
        let symbols = CodeSymbol.list(json, in: nil)
        #expect(symbols.count == 2 && symbols[0].url.lastPathComponent == "Totals.swift" && symbols[0].container == nil)
        #expect(symbols[0].kind == .function && symbols[1].kind == .module)
    }

    @Test func scansDeclarationsWithoutAServer() {
        let swift = """
        public final class Cart {
            @MainActor func add(_ item: Item) {}
            private static func make() -> Cart {}
        }
        extension Cart: Sendable {}
        """
        let found = DeclarationScanner.symbols(in: swift, language: .swift, url: url)
        #expect(found.map(\.name) == ["Cart", "add", "make", "Cart"])
        #expect(found[1].range.start == LSPPosition(line: 1, character: 20))

        let ts = "export class Shop {}\nexport const total = (items) => 0\nasync function load() {}\nconst x = 1"
        #expect(DeclarationScanner.symbols(in: ts, language: .typescript, url: url).map(\.name) == ["Shop", "total", "load"])
        let python = "class Cart:\n    def add(self):\n        pass\nasync def main():"
        #expect(DeclarationScanner.symbols(in: python, language: .python, url: url).map(\.name) == ["Cart", "add", "main"])
        let markdown = "# Title\n```\n# not a heading\n```\n## Next ##"
        #expect(DeclarationScanner.symbols(in: markdown, language: .markdown, url: url).map(\.name) == ["Title", "Next"])
        #expect(DeclarationScanner.symbols(in: "create table if not exists orders (id int);", language: .sql, url: url).map(\.name) == ["orders"])
    }

    @Test func ranksByName() {
        let symbols = ["addItem", "removeItem", "Cart"].enumerated().map { index, name in
            CodeSymbol(name: name, kind: .function, url: url, range: LSPRange(start: LSPPosition(line: index, character: 0), end: LSPPosition(line: index, character: 1)))
        }
        #expect(SymbolSearch.rank("add", in: symbols).map(\.name) == ["addItem"])
        #expect(SymbolSearch.rank("", in: symbols).count == 3)
    }

    @Test func scansAProject() throws {
        let folder = try TemporaryFolder()
        try folder.write("Sources/Cart.swift", "struct Cart {}\nfunc total() {}")
        try folder.write("web/app.ts", "export class Shop {}")
        try folder.write("README.md", "# Not code")
        let symbols = DeclarationScanner.project(root: folder.url, files: ["Sources/Cart.swift", "web/app.ts", "README.md"])
        #expect(Set(symbols.map(\.name)) == ["Cart", "total", "Shop"])
    }
}
