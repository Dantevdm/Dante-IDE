import DanteKit
import Foundation
import Testing

@Suite struct AgentsTests {
    let installed = [
        OllamaModel(name: "llava:latest", size: 4_700_000_000),
        OllamaModel(name: "qwen3-vl:235b-cloud"),
        OllamaModel(name: "qwen2.5vl:32b", size: 21_000_000_000),
        OllamaModel(name: "llama3:latest", size: 4_700_000_000),
        OllamaModel(name: "qwen3:14b", size: 9_300_000_000),
        OllamaModel(name: "devstral:24b", size: 14_000_000_000),
        OllamaModel(name: "qwen3-embedding:0.6b", size: 640_000_000),
    ]

    @Test func routesEachJobToASuitableLocalModel() {
        #expect(ModelRouting.model(for: .draft, installed: installed) == "devstral:24b")
        #expect(ModelRouting.model(for: .summary, installed: installed) == "qwen3:14b")
        #expect(ModelRouting.model(for: .summary, installed: installed, chosen: "llama3:latest") == "llama3:latest")
        // A chosen model that isn't here, or is a cloud one, falls back.
        #expect(ModelRouting.model(for: .summary, installed: installed, chosen: "qwen3-vl:235b-cloud") == "qwen3:14b")
        #expect(ModelRouting.model(for: .triage, installed: [OllamaModel(name: "gpt-oss:120b-cloud")]) == nil)
    }

    @Test func parsesOllamaReplies() throws {
        let tags = #"{"models":[{"name":"qwen3:14b","size":9300000000,"details":{"family":"qwen3","parameter_size":"14.8B"}}]}"#
        #expect(try OllamaModel.parseList(Data(tags.utf8)) == [OllamaModel(name: "qwen3:14b", size: 9_300_000_000, family: "qwen3", parameterSize: "14.8B")])
        let chat = #"{"message":{"role":"assistant","content":"<think>hmm</think>\n\nFix the parser"},"prompt_eval_count":812,"eval_count":40,"total_duration":4100000000,"eval_duration":2000000000}"#
        let reply = try OllamaReply.parse(Data(chat.utf8))
        #expect(reply.text == "Fix the parser")
        #expect(reply.promptTokens == 812 && reply.outputTokens == 40)
        #expect(reply.seconds == 4.1 && reply.tokensPerSecond == 20)
    }

    @Test func serverListsToolsAndDelegates() async throws {
        let ledgerURL = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        let server = DelegateServer(project: "shop", ledger: AgentLedger(url: ledgerURL), models: { [] }) { kind, prompt in
            ("qwen3:14b", OllamaReply(text: "summary of \(prompt)", promptTokens: 100, outputTokens: 20, seconds: 1.5, tokensPerSecond: 30))
        }
        let initialize = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        #expect(initialize?.contains(#""protocolVersion":"2025-06-18""#) == true)
        #expect(await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let list = await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(list?.contains(#""name":"delegate""#) == true)

        let call = await server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delegate","arguments":{"kind":"summary","title":"Sum the log","prompt":"the log"}}}"#)
        #expect(call?.contains("summary of the log") == true)
        #expect(call?.contains(#""isError":false"#) == true)
        let jobs = AgentLedger(url: ledgerURL).jobs()
        #expect(jobs.count == 1)
        #expect(jobs.first?.model == "qwen3:14b" && jobs.first?.requestedBy == "claude" && jobs.first?.tokens == 120)

        let bad = await server.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delegate","arguments":{"kind":"nope"}}}"#)
        #expect(bad?.contains(#""isError":true"#) == true)
    }

    @Test func securityReportRunsTheScanAndIsLogged() async {
        let ledgerURL = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        var server = DelegateServer(project: "shop", ledger: AgentLedger(url: ledgerURL), models: { [] }) { _, _ in
            ("none", OllamaReply(text: "", promptTokens: 0, outputTokens: 0, seconds: 0, tokensPerSecond: 0))
        }
        server.offersLocal = false
        #expect(await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?.contains("security_report") == false)
        server.securityReport = { "Security: B (82/100) · 2 findings in 40 files · Dante" }
        let list = await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#) ?? ""
        #expect(list.contains(#""name":"security_report""#) && !list.contains(#""name":"delegate""#))
        let call = await server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"security_report","arguments":{}}}"#) ?? ""
        #expect(call.contains("82/100") && call.contains("Security page"))
        let job = AgentLedger(url: ledgerURL).jobs().first
        #expect(job?.kind == "audit" && job?.gist == "Security: B (82/100) · 2 findings in 40 files · Dante")
    }

    @Test func statsSumByModel() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let stats = AgentStats([
            AgentJob(date: base, kind: "summary", provider: .local, model: "qwen3:14b", project: "p", promptTokens: 100, outputTokens: 50, seconds: 2, requestedBy: "claude"),
            AgentJob(date: base, kind: "draft", provider: .local, model: "qwen3:14b", project: "p", promptTokens: 10, outputTokens: 10, seconds: 4, outcome: .failed),
            AgentJob(date: base, kind: "turn", provider: .claude, model: "opus", project: "p", promptTokens: 5000, outputTokens: 500, seconds: 30),
        ])
        #expect(stats.rows.first?.model == "qwen3:14b")
        #expect(stats.rows.first?.jobs == 2 && stats.rows.first?.successRate == 0.5 && stats.rows.first?.averageSeconds == 3)
        #expect(stats.tokensKeptLocal == 150)
        #expect(stats.delegatedByClaude == 1)
        #expect(abs(stats.delegationShare - 2.0 / 3.0) < 0.001)
    }
}

@Suite struct AgentDailyTests {
    @Test func countsJobsPerDayIncludingEmptyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = now.addingTimeInterval(-86_400)
        let jobs = [
            AgentJob(date: now, kind: "summary", provider: .local, model: "q", project: "p"),
            AgentJob(date: yesterday, kind: "turn", provider: .claude, model: "c", project: "p"),
            AgentJob(date: now.addingTimeInterval(-86_400 * 30), kind: "turn", provider: .claude, model: "c", project: "p"),
        ]
        let days = AgentStats.daily(jobs, days: 3, now: now, calendar: calendar)
        #expect(days.map(\.local) == [0, 0, 1])
        #expect(days.map(\.claude) == [0, 1, 0])
        #expect(AgentStats.agent(of: jobs[0]) == "Researcher")
        #expect(AgentStats.agent(of: jobs[1]) == "Claude")
    }
}
