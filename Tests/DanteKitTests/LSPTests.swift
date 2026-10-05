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
    }
}
