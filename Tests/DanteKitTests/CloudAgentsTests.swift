@testable import DanteKit
import Foundation
import Testing

@Suite struct CloudAgentsTests {
    let questions: [(name: String, question: JevQuestion)] = [
        ("route", .choice(instructions: "Which team owns this?", options: ["billing": "Payments and invoices", "auth": "Sign-in"])),
        ("urgency", .score(instructions: "How urgent?", levels: ["none", "low", "medium", "high", "critical"])),
        ("escalate", .yesNo(instructions: "Does a person need to look?")),
    ]

    @Test func buildsJevRequests() throws {
        let body = try #require(JSONValue(line: String(decoding: Jev.body(state: "card declined twice", questions: questions), as: UTF8.self)))
        #expect(body["model"]?.string == "jev-latest")
        #expect(body["state"]?.string == "card declined twice")
        #expect(body["questions"]?["route"]?["type"]?.string == "choice")
        #expect(body["questions"]?["route"]?["criteria"]?["billing"]?.string == "Payments and invoices")
        #expect(body["questions"]?["urgency"]?["criteria"]?.array?.count == 5)
        #expect(body["questions"]?["escalate"]?["type"]?.string == "noul")
    }

    @Test func readsJevAnswers() throws {
        let response = #"{"model":"jev-1","answers":{"route":{"type":"choice","choice":"billing","confidence":0.99,"probabilities":{"billing":0.99,"auth":0.01}},"urgency":{"type":"score","score":3.0,"probabilities":{"0":0.0,"3":1.0}},"escalate":{"type":"noul","noul":0.94}},"usage":{"input_tokens":62,"cost_usd":0.000026,"credits_remaining_usd":4.99}}"#
        let decision = try JevDecision.parse(Data(response.utf8))
        #expect(decision.answers["route"] == .choice("billing", confidence: 0.99))
        #expect(decision.answers["urgency"] == .score(3))
        #expect(decision.answers["escalate"] == .yesNo(0.94))
        #expect(decision.inputTokens == 62 && decision.costUSD == 0.000026 && decision.creditsRemainingUSD == 4.99)
        #expect(decision.summary(questions) == "route: billing (99% sure)\nurgency: high (3.0 on 0–4)\nescalate: yes (94% yes)")
        #expect(throws: Jev.Failure.self) { try JevDecision.parse(Data(#"{"error":{"message":"bad key"}}"#.utf8)) }
        #expect(Jev.explain(status: 404, body: Data(#"{"status":"error","code":404,"message":"Application not found"}"#.utf8)) == "Jev’s service isn’t answering right now: Application not found")
        #expect(Jev.explain(status: 402, body: Data(#"{"error":"insufficient_credits"}"#.utf8)) == "The Jev account is out of credit: insufficient_credits")
    }

    @Test func readsQuestionsAsClaudeSendsThem() {
        #expect(JevQuestion.parse(["type": "yes_no", "instructions": "Risky?"]) == .yesNo(instructions: "Risky?"))
        #expect(JevQuestion.parse(["type": "choice", "instructions": "Area?", "options": ["ui", "api"]])
            == .choice(instructions: "Area?", options: ["ui": "ui", "api": "api"]))
        // Too few options or levels, no instructions, or an unknown type: refused.
        #expect(JevQuestion.parse(["type": "choice", "instructions": "Area?", "options": ["ui"]]) == nil)
        #expect(JevQuestion.parse(["type": "score", "instructions": "How bad?", "levels": ["only"]]) == nil)
        #expect(JevQuestion.parse(["type": "yes_no"]) == nil)
        #expect(JevQuestion.parse(["type": "box", "instructions": "Where?"]) == nil)
    }

    @Test func readsGrokModelsAndReplies() throws {
        let models = #"{"object":"list","data":[{"id":"grok-3-mini"},{"id":"grok-imagine-image"},{"id":"grok-4.6"},{"id":"grok-4.6-fast"},{"id":"grok-4.5"},{"id":"grok-2-vision"}]}"#
        let ids = Grok.parseModels(Data(models.utf8))
        #expect(ids == ["grok-4.6", "grok-4.6-fast", "grok-4.5", "grok-3-mini"])
        #expect(Grok.model(chosen: "grok-4.5", available: ids) == "grok-4.5")
        #expect(Grok.model(chosen: "grok-1", available: ids) == "grok-4.6")
        #expect(Grok.model(chosen: nil, available: []) == nil)

        let chat = #"{"id":"x","model":"grok-4.6","choices":[{"index":0,"message":{"role":"assistant","content":"Looks right, but check the nil case."},"finish_reason":"stop"}],"usage":{"prompt_tokens":420,"completion_tokens":12,"total_tokens":432}}"#
        let reply = try GrokReply.parse(Data(chat.utf8), seconds: 2)
        #expect(reply == GrokReply(text: "Looks right, but check the nil case.", model: "grok-4.6", promptTokens: 420, outputTokens: 12, seconds: 2))
        #expect(throws: Grok.Failure.self) { try GrokReply.parse(Data(#"{"error":"Incorrect API key provided"}"#.utf8)) }
    }

    @Test func serverOffersCloudToolsOnlyWithKeys() async throws {
        let ledgerURL = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        var server = DelegateServer(project: "shop", ledger: AgentLedger(url: ledgerURL), models: { [] }) { _, _ in
            ("q", OllamaReply(text: ""))
        }
        var list = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) ?? ""
        #expect(list.contains(#""name":"delegate""#) && !list.contains(#""name":"decide""#) && !list.contains(#""name":"ask_grok""#))

        server.offersLocal = false
        server.decide = { state, questions in
            #expect(state.string == "rm -rf build")
            #expect(questions.map(\.name) == ["risk"])
            return JevDecision(model: "jev-1", answers: ["risk": .yesNo(0.12)], inputTokens: 30, costUSD: 0.00001)
        }
        server.askGrok = { _, prompt in GrokReply(text: "Second view on \(prompt)", model: "grok-4.6", promptTokens: 50, outputTokens: 8, seconds: 1) }
        list = await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#) ?? ""
        #expect(!list.contains(#""name":"delegate""#) && list.contains(#""name":"decide""#) && list.contains(#""name":"ask_grok""#))

        let decided = await server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"decide","arguments":{"material":"rm -rf build","title":"Risk","questions":[{"name":"risk","type":"yes_no","instructions":"Could this lose work?"}]}}}"#) ?? ""
        #expect(decided.contains("risk: no (12% yes)") && decided.contains(#""isError":false"#))
        let asked = await server.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ask_grok","arguments":{"prompt":"the plan"}}}"#) ?? ""
        #expect(asked.contains("Second view on the plan"))
        let bad = await server.handle(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"decide","arguments":{"material":"x","questions":[]}}}"#) ?? ""
        #expect(bad.contains(#""isError":true"#))

        let jobs = AgentLedger(url: ledgerURL).jobs()
        #expect(jobs.map(\.provider) == [.jev, .grok])
        #expect(jobs.first?.costUSD == 0.00001 && jobs.first?.title == "Risk")
        let stats = AgentStats(jobs)
        #expect(stats.cloudJobs == 2 && stats.localJobs == 0 && stats.costUSD == 0.00001)
        #expect(AgentStats.agent(of: jobs[1]) == "Grok")
    }

    @Test func keysGoInAPrivateConfigFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = MCPConfigFile.json(command: "/Apps/Dante.app/bin/dante", environment: ["JEV_API_KEY": "jv_test_123"])
        #expect(JSONValue(line: json)?["mcpServers"]?["dante"]?["env"]?["JEV_API_KEY"]?.string == "jv_test_123")
        #expect(JSONValue(line: MCPConfigFile.json(command: "dante", environment: [:]))?["mcpServers"]?["dante"]?["env"] == nil)

        let file = try MCPConfigFile.write(json, in: folder, pid: 99_999)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let kept = try MCPConfigFile.write(json, in: folder, pid: 1)
        MCPConfigFile.removeStale(in: folder) { $0 == 1 }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))

        let arguments = ClaudeSession.arguments(systemPrompt: "p", rules: ClaudeRules(), resume: nil, delegate: "dante", mcpConfig: file.path)
        #expect(arguments.suffix(2) == ["--mcp-config", file.path])
        #expect(!arguments.joined(separator: " ").contains("jv_test_123"))
    }

    @Test func briefsClaudeOnlyAboutToolsItHas() {
        #expect(ClaudeBrief.delegation(local: false, jev: false, grok: false, security: false) == nil)
        #expect(ClaudeBrief.delegation(local: false, jev: false, grok: false)?.contains("`security_report`") == true)
        let cloud = ClaudeBrief.delegation(local: false, jev: true, grok: true) ?? ""
        #expect(cloud.contains("`decide`") && cloud.contains("`ask_grok`") && !cloud.contains("`delegate`"))
    }

    @Test func toolRowsNameTheAgent() {
        let root = URL(filePath: "/home/me/shop")
        let running = ToolActivity(id: "a", name: "mcp__dante__delegate", input: ["kind": "summary", "title": "Sum NOTES.md", "prompt": "x"], status: .running)
        #expect(running.verb == "Handing to Reader" && running.target(in: root) == "Sum NOTES.md")
        var done = running
        done.status = .done
        #expect(done.verb == "Handed to Reader")
        let grok = ToolActivity(id: "b", name: "mcp__dante__ask_grok", input: ["prompt": "Is this plan sound?"], status: .running)
        #expect(grok.verb == "Asking Grok" && grok.target(in: root) == "Is this plan sound?")
    }

        @Test func cloudAgentsCircleTheOrb() {
        let tools = [
            ToolActivity(id: "a", name: "mcp__dante__ask_grok", input: ["prompt": "x"], status: .running),
            ToolActivity(id: "b", name: "mcp__dante__decide", input: [:], status: .running),
        ]
        #expect(OrbSatellite.running(in: tools).map(\.kind) == [.cloud(.grok), .cloud(.jev)])
    }
}
