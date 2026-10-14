@testable import DanteKit
import Foundation
import Testing

struct LSPURIMapTests {
    let map = LSPURIMap(localPath: "/home/me/Library/Application Support/Dante/Remote/devbox/ab12/shop", remotePath: "/srv/shop")
    let mirror = "file:///home/me/Library/Application%20Support/Dante/Remote/devbox/ab12/shop"

    @Test func mapsURIsAndRootPathButNotText() {
        let initialize: JSONValue = .object([
            "rootUri": .string(mirror),
            "rootPath": .string("/home/me/Library/Application Support/Dante/Remote/devbox/ab12/shop"),
            "workspaceFolders": .array([.object(["uri": .string(mirror), "name": .string("shop")])]),
            "textDocument": .object(["uri": .string(mirror + "/api/main.go"), "text": .string(mirror + "/api/main.go")]),
        ])
        let sent = map.toHost(initialize)
        #expect(sent["rootUri"]?.string == "file:///srv/shop")
        #expect(sent["rootPath"]?.string == "/srv/shop")
        #expect(sent["workspaceFolders"]?.array?.first?["uri"]?.string == "file:///srv/shop")
        #expect(sent["textDocument"]?["uri"]?.string == "file:///srv/shop/api/main.go")
        #expect(sent["textDocument"]?["text"]?.string == mirror + "/api/main.go")
        #expect(map.toMirror(sent) == initialize)
    }

    @Test func mapsWorkspaceEditKeysAndLeavesOtherFilesAlone() {
        let edit: JSONValue = .object([
            "changes": .object(["file:///srv/shop/a.go": .array([]), "file:///usr/lib/go/src/fmt/print.go": .array([])]),
            "targetUri": .string("file:///srv/shopping/x.go"),
        ])
        let received = map.toMirror(edit)
        #expect(received["changes"]?[mirror + "/a.go"] != nil)
        #expect(received["changes"]?["file:///usr/lib/go/src/fmt/print.go"] != nil)
        #expect(received["targetUri"]?.string == "file:///srv/shopping/x.go")
    }

    @Test func readsTheHostProbe() {
        let script = LanguageServer.hostProbeScript()
        #expect(!script.contains("xcrun"))
        #expect(script.contains("elif p=$(command -v basedpyright-langserver"))
        let output = "gopls\t/home/me/go/bin/gopls\nPyright\t/usr/bin/pylsp\nnoise\nTypeScript\t/opt/node/bin/typescript-language-server --stdio\n"
        #expect(LanguageServer.hostCommands(fromProbe: output) == [
            "gopls": ["/home/me/go/bin/gopls"],
            "Pyright": ["/usr/bin/pylsp"],
            "TypeScript": ["/opt/node/bin/typescript-language-server", "--stdio"],
        ])
    }

    @Test func probeRunsInAShell() async {
        let output = await Shell.run(["sh", "-c", LanguageServer.hostProbeScript()], in: FileManager.default.temporaryDirectory)
        #expect(output.succeeded)
        for (_, command) in LanguageServer.hostCommands(fromProbe: output.stdout) {
            #expect(FileManager.default.isExecutableFile(atPath: command[0]))
        }
    }
}
