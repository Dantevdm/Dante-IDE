import CoreGraphics
import Foundation
import Testing
@testable import DanteKit

@Suite struct HandsTests {
    @Test func keyCombosParse() throws {
        let save = try #require(Hands.KeyCombo.parse("cmd+s"))
        #expect(save.key == 1)
        #expect(save.flags.contains(.maskCommand))
        let newWindow = try #require(Hands.KeyCombo.parse("Cmd + Shift + N"))
        #expect(newWindow.key == 45)
        #expect(newWindow.flags.contains(.maskShift) && newWindow.flags.contains(.maskCommand))
        #expect(Hands.KeyCombo.parse("return")?.key == 36)
        #expect(Hands.KeyCombo.parse("f5")?.key == 96)
        #expect(Hands.KeyCombo.parse("cmd+-")?.key == 27)
        #expect(Hands.KeyCombo.parse("hyper+s") == nil)
        #expect(Hands.KeyCombo.parse("cmd+") == nil)
        #expect(Hands.KeyCombo.parse("") == nil)
    }

    @Test func folderSearchStaysInTheQuery() {
        #expect(Hands.folderQuery("Shop") == "kMDItemContentType == \"public.folder\" && kMDItemFSName == \"*Shop*\"cd")
        #expect(Hands.folderQuery("a\" || kMDItemFSName == \"*").components(separatedBy: "\"").count == 5)
        #expect(Hands.folderQuery("x\"y*'z\\") == "kMDItemContentType == \"public.folder\" && kMDItemFSName == \"*xyz*\"cd")
    }

    @Test func foldersNearestFirstOutsideLibraryAndHiddenOnes() {
        let home = "/home/me"
        let found = Hands.rankedFolders([
            "/home/me/Work/Clients/shop", "/home/me/shop", "/home/me/Library/Caches/shop", "/home/me/.cache/shop",
            "/home/me/Code/web/node_modules/shop", "/elsewhere/shop",
        ], home: home)
        #expect(found == ["/home/me/shop", "/home/me/Work/Clients/shop"])
    }

    @Test func handsNeverActOnDanteTerminalsOrSettings() {
        #expect(Hands.refusal(bundleID: "dev.dante.ide", name: "Dante") != nil)
        #expect(Hands.refusal(bundleID: "dev.dante.ide.diagramtest", name: "Dante Test") != nil)
        #expect(Hands.refusal(bundleID: "com.apple.Terminal", name: "Terminal") != nil)
        #expect(Hands.refusal(bundleID: "com.apple.systempreferences", name: "System Settings") != nil)
        #expect(Hands.refusal(bundleID: "com.apple.Notes", name: "Notes") == nil)
        #expect(DelegateServer.appRefusal("Terminal") != nil)
        #expect(DelegateServer.appRefusal("iTerm.app") != nil)
        #expect(DelegateServer.appRefusal("Safari") == nil)
    }

    @Test func toolsAreNamedAndDescribed() {
        #expect(Hands.Tool.of(mcpName: "mcp__dante__type_text") == .typeText)
        #expect(Hands.Tool.of(mcpName: "mcp__dante__open_file") == nil)
        #expect(Hands.Tool.of(mcpName: "type_text") == nil)
        #expect(Hands.Tool.typeText.controls && Hands.Tool.click.controls && Hands.Tool.screenshot.controls)
        #expect(!Hands.Tool.openApp.controls && !Hands.Tool.findFolders.controls)
        #expect(Hands.Tool.typeText.describe(["text": "hello"], done: false) == "Type “hello”")
        #expect(Hands.Tool.click.describe(["x": 10, "y": 20, "double": true], done: true) == "Double-clicked at 10, 20")
        #expect(ClaudeSession.attentionLabel("mcp__dante__press_keys", input: ["keys": "cmd+s"]) == "Press cmd+s")
    }

    @Test func jobsNeverGetHands() {
        let verdict = JobGuard.verdict(toolName: "mcp__dante__open_app", input: ["app": "Notes"], worktree: URL(filePath: "/tmp/w"),
                                       away: false, hasNote: false)
        guard case .refuse? = verdict else { Issue.record("not refused"); return }
    }

    @Test func serverListsHandsOnlyWhenOn() async {
        var server = DelegateServer(project: "shop", ledger: nil, models: { [] }) { _, _ in ("m", OllamaReply(text: "", promptTokens: 0, outputTokens: 0, seconds: 0, tokensPerSecond: 0)) }
        #expect(!server.tools.contains { $0["name"]?.string == "type_text" })
        let off = await server.call("type_text", arguments: ["text": "x"])
        #expect(off["isError"]?.bool == true)
        server.hands = true
        let names = server.tools.compactMap { $0["name"]?.string }
        #expect(Set(Hands.Tool.allCases.map(\.rawValue)).isSubset(of: Set(names)))
        #expect(server.tools.first { $0["name"]?.string == "click" }?["inputSchema"]?["properties"]?["why"] == nil)
        #expect(server.instructions.contains("Hands"))
    }

    @Test func theKillSwitchStopsEveryStep() async throws {
        let flag = FileManager.default.temporaryDirectory.appending(path: "hands-\(UUID().uuidString)/stopped")
        defer { try? FileManager.default.removeItem(at: flag.deletingLastPathComponent()) }
        var server = DelegateServer(project: "shop", ledger: nil, models: { [] }) { _, _ in ("m", OllamaReply(text: "", promptTokens: 0, outputTokens: 0, seconds: 0, tokensPerSecond: 0)) }
        server.hands = true
        #expect(!Hands.isStopped(flag: flag))
        Hands.stop(flag: flag)
        #expect(Hands.isStopped(flag: flag))
        for tool in Hands.Tool.allCases {
            let result = await server.callHands(tool, arguments: ["app": "Notes", "text": "x", "keys": "a", "x": 1, "y": 1, "name": "a", "path": "~"], stopFlag: flag)
            #expect(result["isError"]?.bool == true)
            #expect(result["content"]?.array?.first?["text"]?.string == Hands.stoppedMessage)
        }
        #expect(await Hands.type("hello", flag: flag) == false)
        Hands.allow(flag: flag)
        #expect(!Hands.isStopped(flag: flag))
    }
}
