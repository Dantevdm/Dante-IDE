import Foundation
import Testing
@testable import DanteKit

struct MiseTests {
    @Test func readsToolsWithInstalledState() {
        let json = """
        {"node": [{"version": "20.20.2", "requested_version": "20", "installed": false, "source": {"type": "mise.toml", "path": "/home/me/shop/mise.toml"}}],
         "go": [{"version": "1.26.1", "requested_version": "1.26", "installed": true}]}
        """
        let tools = Mise.tools(fromJSON: json)
        #expect(tools.map(\.name) == ["go", "node"])
        #expect(tools[1].requested == "20")
        #expect(tools[1].source == "/home/me/shop/mise.toml")
        #expect(Mise.Status(configs: []).missing.isEmpty)
        var status = Mise.Status(configs: ["mise.toml"])
        status.tools = tools
        #expect(status.missing.map(\.name) == ["node"])
    }

    @Test func readsTasksSkippingHiddenOnes() {
        let json = """
        [{"name": "test", "description": "Run the tests", "run": ["go test ./..."], "hide": false},
         {"name": "secret-setup", "hide": true, "run": "make"},
         {"name": "dev", "run": "npm run dev"}]
        """
        let tasks = Mise.tasks(fromJSON: json)
        #expect(tasks.map(\.name) == ["test", "dev"])
        #expect(tasks[1].run == ["npm run dev"])
    }

    @Test func untrustedConfigIsNoticed() {
        #expect(Mise.isUntrusted("mise ERROR Config files in /home/me/shop/mise.toml are not trusted."))
        #expect(!Mise.isUntrusted("mise WARN  missing: node@20"))
    }

    @Test func overlayWinsOverTheBaseEnvironment() {
        let merged = Mise.applying(["PATH": "/home/me/.mise/node/bin:/usr/bin", "SHOP_MODE": "dev"], to: ["PATH": "/usr/bin", "HOME": "/home/me"])
        #expect(merged["PATH"] == "/home/me/.mise/node/bin:/usr/bin")
        #expect(merged["SHOP_MODE"] == "dev")
        #expect(merged["HOME"] == "/home/me")
        #expect(Mise.environment(fromJSON: #"{"PATH": "/a", "N": 3}"#) == ["PATH": "/a"])
    }

    @Test func findsConfigFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Mise.configFiles(in: root).isEmpty)
        try "node 20\n".write(to: root.appending(path: ".tool-versions"), atomically: true, encoding: .utf8)
        try "[tools]\n".write(to: root.appending(path: "mise.toml"), atomically: true, encoding: .utf8)
        #expect(Mise.configFiles(in: root) == ["mise.toml", ".tool-versions"])
    }
}
