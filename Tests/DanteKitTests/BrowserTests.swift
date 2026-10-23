import Foundation
import Testing
@testable import DanteKit

@Suite struct BrowserTests {
    @Test func visitsOnlyTheAppHereAndListedHosts() {
        let hosts = BrowserHosts(extra: ["staging.shop.dev"])
        for allowed in ["http://localhost:3000/orders", "http://127.0.0.1:8080", "http://[::1]:5173/", "https://shop.localhost/",
                        "http://api.shop.test/v1", "https://staging.shop.dev/login", "https://eu.staging.shop.dev/", "about:blank"] {
            #expect(hosts.allows(URL(string: allowed)!), "\(allowed)")
        }
        for refused in ["https://example.com", "https://shop.dev", "https://staging.shop.dev.evil.com/", "file:///etc/passwd",
                        "ftp://localhost/", "https://localhost.evil.com/", "javascript:alert(1)"] {
            #expect(!hosts.allows(URL(string: refused)!), "\(refused)")
        }
        #expect(BrowserHosts().refusal(URL(string: "https://example.com")!).contains("browser: hosts:"))
    }

    @Test func readsHostsFromProjectYAML() {
        let hosts = BrowserHosts.parse("""
        name: shop
        browser:
          hosts: [staging.shop.dev, "https://preview.shop.dev/app", " Admin.Shop.Dev. "]
        """)
        #expect(hosts.extra == ["staging.shop.dev", "preview.shop.dev", "admin.shop.dev"])
        #expect(BrowserHosts.parse("name: shop").extra.isEmpty)
        #expect(BrowserHosts.parse(": not yaml [").extra.isEmpty)
    }

    @Test func typedAddressesBecomeURLs() {
        #expect(BrowserHosts.url(from: "localhost:3000/orders")?.absoluteString == "http://localhost:3000/orders")
        #expect(BrowserHosts.url(from: "3000")?.absoluteString == "http://localhost:3000")
        #expect(BrowserHosts.url(from: ":5173/x")?.absoluteString == "http://localhost:5173/x")
        #expect(BrowserHosts.url(from: " https://shop.test ")?.absoluteString == "https://shop.test")
        #expect(BrowserHosts.url(from: "  ") == nil)
    }

    @Test func reportReadsAsTextForTheAgent() {
        let report = BrowserReport(url: "http://localhost:3000/", title: "Shop", text: "Orders\nNo orders yet",
                                   controls: [.init(ref: 1, role: "textbox", label: "Email", value: "a@b.test"),
                                              .init(ref: 2, role: "link", label: "Help", href: "/help"),
                                              .init(ref: 3, role: "button", label: "Pay", disabled: true)],
                                   errors: ["console.error: Boom"], requests: ["GET /api/orders → 500"], width: 1280, height: 800)
        let text = report.rendered(status: 200)
        #expect(text.hasPrefix("Shop — http://localhost:3000/\nViewport 1280×800."))
        #expect(text.contains("[1] textbox “Email” = “a@b.test”"))
        #expect(text.contains("[2] link “Help” → /help"))
        #expect(text.contains("[3] button “Pay” (disabled)"))
        #expect(text.contains("Page errors:\n- console.error: Boom"))
        #expect(text.contains("Failed requests:\n- GET /api/orders → 500"))
        #expect(!text.contains("No page errors"))

        let clean = BrowserReport(url: "http://localhost/missing", title: "", text: String(repeating: "a", count: BrowserReport.textLimit + 10), controls: [])
        let cleanText = clean.rendered(status: 404)
        #expect(cleanText.hasPrefix("(no title) — http://localhost/missing (HTTP 404)"))
        #expect(cleanText.contains("…(more on the page)"))
        #expect(cleanText.hasSuffix("No page errors or failed requests."))
    }

    @Test func reportDecodesWhatThePageScriptSends() throws {
        let json = #"{"url":"http://localhost/","title":"T","text":"Hi","controls":[{"ref":1,"role":"button","label":"Go"}],"errors":[],"requests":[],"width":390,"height":844}"#
        let report = try JSONDecoder().decode(BrowserReport.self, from: Data(json.utf8))
        #expect(report.controls == [.init(ref: 1, role: "button", label: "Go")])
        #expect(report.width == 390)
    }

    @Test func typingIsQuotedForTheScript() {
        let script = BrowserScripts.type(4, text: #"O'Brien "quoted" </script>"#, submit: true)
        #expect(script.contains(#"const text = "O'Brien \"quoted\" <\/script>";"#))
        #expect(script.contains("data-dante-ref=\"4\""))
        #expect(script.contains("if (true)"))
        #expect(BrowserScripts.click(7).contains("data-dante-ref=\"7\""))
    }

    @Test func toolsAreNamedApprovedAndDescribed() {
        #expect(BrowserTools.Tool.of(mcpName: "mcp__dante__browser_open") == .open)
        #expect(BrowserTools.Tool.of(mcpName: "mcp__other__browser_open") == nil)
        #expect(BrowserTools.Tool.open.describe(["url": "localhost:3000"], done: true) == "Opened localhost:3000 in its browser")
        #expect(BrowserTools.Tool.resize.describe(["width": 390], done: false) == "Resizing its browser to 390 wide")
        // Jobs may use it: the guard leaves it to the auto-approval.
        #expect(JobGuard.verdict(toolName: "mcp__dante__browser_click", input: ["ref": 1], worktree: URL(filePath: "/tmp/w"),
                                 away: false, hasNote: false) == nil)
    }

    @Test func serverListsTheBrowserOnlyWhenOn() async {
        var server = DelegateServer(project: "shop", ledger: nil, models: { [] }) { _, _ in ("m", OllamaReply(text: "", promptTokens: 0, outputTokens: 0, seconds: 0, tokensPerSecond: 0)) }
        #expect(!server.tools.contains { $0["name"]?.string == "browser_open" })
        let off = await server.call("browser_open", arguments: ["url": "3000"])
        #expect(off["isError"]?.bool == true)
        server.browser = BrowserTools(hosts: BrowserHosts(), shots: FileManager.default.temporaryDirectory)
        let names = server.tools.compactMap { $0["name"]?.string }
        #expect(Set(BrowserTools.Tool.allCases.map(\.rawValue)).isSubset(of: Set(names)))
        #expect(server.tools.first { $0["name"]?.string == "browser_open" }?["inputSchema"]?["properties"]?["why"] == nil)
        #expect(server.instructions.contains("browser of your own"))
        let live = DelegateServer.live(project: "shop", root: "/tmp", environment: [BrowserTools.environment: "1", DelegateEnvironment.local: "0"])
        #expect(live.browser != nil)
        #expect(DelegateServer.live(project: "shop", root: "/tmp", environment: [DelegateEnvironment.local: "0"]).browser == nil)
    }

    @Test func oldScreenshotsAreTidied() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appending(path: "old.png"), new = folder.appending(path: "new.png"), other = folder.appending(path: "notes.txt")
        for file in [old, new, other] { try Data([1]).write(to: file) }
        let lastMonth = Date().addingTimeInterval(-30 * 24 * 3600)
        for file in [old, other] { try FileManager.default.setAttributes([.modificationDate: lastMonth], ofItemAtPath: file.path) }
        AgentBrowser.tidy(folder)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func verifierIsABuiltInJobType() {
        let verifier = JobType.verifier
        #expect(JobType.builtIn.contains(verifier))
        #expect(verifier.brief.contains("browser_resize"))
        #expect(verifier.brief.contains("[blocker|issue|nit]"))
        #expect(JobGuard.runsUnattended("npm run dev", also: verifier.commands))
        #expect(JobGuard.forbidden("git push") != nil)
    }
}

struct BrowserContentRuleTests {
    @Test func sendingIsBlockedOutsideTheAllowedHosts() throws {
        let json = BrowserHosts(extra: ["staging.shop.dev"]).contentRules
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let first = try #require(rules.first)
        #expect((first["action"] as? [String: String])?["type"] == "block")
        #expect(((first["trigger"] as? [String: Any])?["resource-type"] as? [String])?.contains("fetch") == true)
        #expect(((first["trigger"] as? [String: Any])?["resource-type"] as? [String])?.contains("image") == false)
        let filters = rules.dropFirst().compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        #expect(filters.contains("^[a-z]+://staging\\.shop\\.dev[:/?#]"))
        #expect(filters.contains("^[a-z]+://[^/:?#]*\\.localhost[:/?#]"))
        // WebKit's url-filter has no alternation.
        #expect(!filters.contains { $0.contains("|") })
    }
}
