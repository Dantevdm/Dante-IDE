import Foundation
import Testing
@testable import DanteKit

struct LSPFramingTests {
    @Test func roundTripsAcrossChunks() {
        let first = LSPFraming.encode(["jsonrpc": "2.0", "id": 1, "result": "héllo"])
        let second = LSPFraming.encode(["jsonrpc": "2.0", "method": "x"])
        let all = first + second
        var decoder = LSPFraming.Decoder()
        var messages: [JSONValue] = []
        // Feed it a few bytes at a time, splitting headers and multi-byte characters.
        var index = all.startIndex
        while index < all.endIndex {
            let end = all.index(index, offsetBy: 7, limitedBy: all.endIndex) ?? all.endIndex
            messages += decoder.append(all[index..<end])
            index = end
        }
        #expect(messages.count == 2)
        #expect(messages[0]["result"]?.string == "héllo")
        #expect(messages[1]["method"]?.string == "x")
    }

    @Test func lengthCountsBytesNotCharacters() {
        let data = LSPFraming.encode(["a": "é"])
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("Content-Length: 10\r\n\r\n"))
    }

    @Test func extraHeadersAreIgnored() {
        var decoder = LSPFraming.Decoder()
        let body = #"{"id":3}"#
        let messages = decoder.append(Data("Content-Type: application/vscode-jsonrpc\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        #expect(messages.first?["id"]?.int == 3)
    }
}

struct LSPPositionTests {
    let text = "let a = 1\nlet 😀 = 2\n\nend" as NSString

    @Test func offsetsAndPositionsAgree() {
        for offset in 0...text.length {
            let position = LSPPosition(offset: offset, in: text)
            #expect(position.offset(in: text) == offset)
        }
        let index = LineIndex(text)
        for offset in 0...text.length {
            #expect(index.offset(of: LSPPosition(offset: offset, in: text)) == offset)
        }
        #expect(index.offset(of: LSPPosition(line: 0, character: 99)) == 9)
        #expect(index.offset(of: LSPPosition(line: 40, character: 0)) == text.length)
        #expect(LSPPosition(offset: 10, in: text) == LSPPosition(line: 1, character: 0))
        // The emoji is two UTF-16 units, as LSP counts by default.
        #expect(LSPPosition(line: 1, character: 6).offset(in: text) == 16)
    }

    @Test func outOfRangePositionsClamp() {
        #expect(LSPPosition(line: 0, character: 99).offset(in: text) == 9)
        #expect(LSPPosition(line: 40, character: 0).offset(in: text) == text.length)
    }

    @Test func definitionResultsInEveryShape() {
        let range: JSONValue = ["start": ["line": 2, "character": 4], "end": ["line": 2, "character": 9]]
        let location: JSONValue = ["uri": "file:///p/a.swift", "range": range]
        let link: JSONValue = ["targetUri": "file:///p/b.swift", "targetRange": range, "targetSelectionRange": range]
        #expect(LSPLocation.list(location).map(\.url.path) == ["/p/a.swift"])
        #expect(LSPLocation.list([location, link]).map(\.url.lastPathComponent) == ["a.swift", "b.swift"])
        #expect(LSPLocation.list(.null).isEmpty)
        #expect(LSPLocation.list(location).first?.range.start == LSPPosition(line: 2, character: 4))
    }

    @Test func diagnosticsParse() {
        let json: JSONValue = ["range": ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 5]],
                               "severity": 2, "message": "unused", "source": "swiftc"]
        let diagnostic = LSPDiagnostic(json)
        #expect(diagnostic?.severity == .warning)
        #expect(diagnostic?.range.nsRange(in: "let a = 1") == NSRange(location: 4, length: 1))
    }

    @Test func hoverContentsInEveryShape() {
        #expect(LSPClient.hoverText("plain") == "plain")
        #expect(LSPClient.hoverText(["kind": "markdown", "value": "**bold**"]) == "**bold**")
        #expect(LSPClient.hoverText(["language": "swift", "value": "let a: Int"]) == "```swift\nlet a: Int\n```")
        #expect(LSPClient.hoverText(["first", ["language": "go", "value": "func f()"]]) == "first\n\n```go\nfunc f()\n```")
        #expect(LSPClient.hoverText(.null) == nil)
        #expect(LSPClient.hoverText(["kind": "markdown", "value": "  "]) == nil)
    }

    @Test func serversByLanguage() {
        #expect(LanguageServer.for(.swift)?.name == "SourceKit-LSP")
        #expect(LanguageServer.for(.typescript) == LanguageServer.for(.javascript))
        #expect(LanguageServer.for(.markdown) == nil)
    }
}

@MainActor
struct LSPClientTests {
    nonisolated static let hasSourceKit = LanguageServer.for(.swift)?.resolve(environment: Shell.environment()) != nil

    @Test(.enabled(if: hasSourceKit), .timeLimit(.minutes(1)))
    func sourceKitReportsATypeError() async throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "main.swift")
        let text = "let count: Int = \"three\"\nprint(count)\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let client = try LSPClient(server: LanguageServer.for(.swift)!, root: folder.url, environment: Shell.environment())
        defer { client.stop() }
        await client.open(file, language: .swift, text: text)
        #expect(client.state == .ready)
        for _ in 0..<200 where client.diagnostics(for: file).isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        let error = try #require(client.diagnostics(for: file).first)
        #expect(error.severity == .error)
        #expect(error.range.start.line == 0)

        let locations = await client.definition(of: LSPPosition(line: 1, character: 8), in: file)
        #expect(locations.first?.range.start.line == 0)

        let hover = await client.hover(at: LSPPosition(line: 1, character: 8), in: file)
        #expect(hover?.contains("count") == true)
    }
}

@MainActor
struct ClaudeContextDiagnosticsTests {
    @Test func problemsInTheOpenFileReachClaude() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("main.swift", "let a: String = 1\n")
        let workspace = Workspace(url: folder.url)
        try workspace.open(file)
        let range = LSPRange(start: LSPPosition(line: 0, character: 16), end: LSPPosition(line: 0, character: 17))
        let diagnostics = [
            LSPDiagnostic(range: range, severity: .error, message: "cannot convert value"),
            LSPDiagnostic(range: range, severity: .hint, message: "just a hint"),
        ]
        let context = try #require(ClaudeBrief.context(workspace: workspace, line: 1, diagnostics: diagnostics))
        #expect(context.contains("line 1, error: cannot convert value"))
        #expect(!context.contains("just a hint"))
        #expect(ClaudeBrief.context(workspace: workspace, line: 1)?.contains("language server") == false)
    }
}

@Suite struct LSPEditTests {
    @Test func readsCompletionLists() {
        let json: JSONValue = [
            "isIncomplete": true,
            "items": [
                ["label": "count", "kind": 10, "detail": "Int", "sortText": "b"],
                ["label": "append(_:)", "kind": 2, "insertTextFormat": 2,
                 "textEdit": ["range": ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 6]], "newText": "append(${1:element})"]],
            ],
        ]
        let list = LSPCompletionItem.list(json)
        #expect(list.isIncomplete && list.items.count == 2)
        #expect(list.items[0].kind == .property && list.items[0].detail == "Int" && list.items[0].insertText == "count")
        #expect(list.items[1].isSnippet && list.items[1].replaceRange?.start.character == 4)
    }

    @Test func expandsSnippets() {
        let call = Snippet.expand("append(${1:element}, at: ${2:index})$0")
        #expect(call.text == "append(element, at: index)")
        #expect(call.selection == NSRange(location: 7, length: 7))
        #expect(Snippet.expand("if ${1:cond} {\n\t$0\n}").text == "if cond {\n\t\n}")
        #expect(Snippet.expand("${1|let,var|} x").text == "let x")
        #expect(Snippet.expand("cost: \\$5").text == "cost: $5")
        #expect(Snippet.expand("plain").selection == nil)
    }

    @Test func appliesEditsFromTheEnd() {
        let text = "let a = 1\nlet b = a + a\n"
        func edit(_ line: Int, _ from: Int, _ to: Int, _ new: String) -> LSPTextEdit {
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: line, character: from), end: LSPPosition(line: line, character: to)), newText: new)
        }
        let renamed = LSPTextEdit.apply([edit(0, 4, 5, "total"), edit(1, 8, 9, "total"), edit(1, 12, 13, "total")], to: text)
        #expect(renamed == "let total = 1\nlet b = total + total\n")
        let inserted = LSPTextEdit.apply([edit(0, 0, 0, "// x\n")], to: text)
        #expect(inserted.hasPrefix("// x\nlet a"))
        // A repeated edit is made once, not twice ("totaltal").
        let repeated = LSPTextEdit.apply([edit(0, 4, 5, "total"), edit(0, 4, 5, "total")], to: text)
        #expect(repeated.hasPrefix("let total = 1\n"))
    }

    @Test func addsReferencesTheRenameLeftOut() {
        func location(_ path: String, _ line: Int, _ from: Int, _ to: Int) -> LSPLocation {
            LSPLocation(url: URL(filePath: path), range: LSPRange(start: LSPPosition(line: line, character: from), end: LSPPosition(line: line, character: to)))
        }
        let main = URL(filePath: "/p/main.swift"), cart = URL(filePath: "/p/Cart.swift")
        var edit = LSPWorkspaceEdit(changes: [main: [LSPTextEdit(range: location("/p/main.swift", 1, 9, 13).range, newText: "Product")]])
        let files = [cart: "struct Item {}\nvar items: [Item] = []\nlet other = 1\n"]
        // Index references come back as empty ranges; one points at text that isn't the name.
        edit.include([location("/p/main.swift", 1, 9, 13), location("/p/Cart.swift", 0, 7, 7), location("/p/Cart.swift", 1, 12, 12),
                      location("/p/Cart.swift", 2, 4, 4), location("/p/Other.swift", 0, 0, 4)],
                     renaming: "Item", to: "Product") { files[$0] }
        #expect(edit.changes[main]?.count == 1)
        #expect(LSPTextEdit.apply(edit.changes[cart] ?? [], to: files[cart]!) == "struct Product {}\nvar items: [Product] = []\nlet other = 1\n")
        #expect(edit.changes[URL(filePath: "/p/Other.swift")] == nil)
    }

    @Test func readsWorkspaceEditsInBothForms() {
        let range: JSONValue = ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]]
        let changes = LSPWorkspaceEdit(["changes": ["file:///p/a.swift": [["range": range, "newText": "x"]]]])
        #expect(changes.changes[URL(filePath: "/p/a.swift")]?.first?.newText == "x")
        let documents = LSPWorkspaceEdit(["documentChanges": [
            ["textDocument": ["uri": "file:///p/b.swift", "version": 3], "edits": [["range": range, "newText": "y"], ["range": range, "newText": "z"]]],
            ["kind": "create", "uri": "file:///p/new.swift"],
        ]])
        #expect(documents.editCount == 2 && documents.changes.keys.map(\.lastPathComponent) == ["b.swift"])
    }

    @Test func capabilitiesCanBeTrueOrOptions() {
        #expect(LSPClient.supports(.bool(true)) && LSPClient.supports(["prepareProvider": true]))
        #expect(!LSPClient.supports(.bool(false)) && !LSPClient.supports(nil) && !LSPClient.supports(.null))
    }
}
