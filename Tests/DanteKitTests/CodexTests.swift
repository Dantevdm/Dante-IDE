@testable import DanteKit
import Foundation
import Testing

@Suite struct CodexTests {
    @Test func readsCodexEvents() throws {
        let output = """
        {"type":"thread.started","thread_id":"t1"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I’ll check NOTES.md.\\n"}}
        {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'rg -n startup NOTES.md'","status":"in_progress"}}
        {"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'rg -n startup NOTES.md'","exit_code":0}}
        {"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Startup is 40% faster."}}
        {"type":"turn.completed","usage":{"input_tokens":29353,"cached_input_tokens":24576,"output_tokens":77}}
        """
        let reply = try CodexReply.parse(output, seconds: 12)
        #expect(reply == CodexReply(text: "Startup is 40% faster.", commands: ["rg -n startup NOTES.md"],
                                    inputTokens: 29353, cachedTokens: 24576, outputTokens: 77, seconds: 12))
    }

    @Test func explainsAFailedTurn() {
        let output = #"""
        {"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-x' model is not supported when using Codex with a ChatGPT account.\"}}"}
        {"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"The 'gpt-x' model is not supported when using Codex with a ChatGPT account.\"}}"}}
        """#
        #expect(throws: Codex.Failure(message: "The 'gpt-x' model is not supported when using Codex with a ChatGPT account.")) {
            try CodexReply.parse(output)
        }
    }

    @Test func runsReadOnlyWithoutTheUsersConfig() {
        let arguments = Codex.arguments(project: "/home/me/shop", model: "gpt-5-codex")
        #expect(arguments.first == "exec" && arguments.last == "-")
        #expect(arguments.contains("--ignore-user-config") && arguments.contains("--ephemeral"))
        let sandbox = arguments.firstIndex(of: "--sandbox").map { arguments[$0 + 1] }
        #expect(sandbox == "read-only")
        #expect(arguments.firstIndex(of: "-C").map { arguments[$0 + 1] } == "/home/me/shop")
        #expect(arguments.firstIndex(of: "-m").map { arguments[$0 + 1] } == "gpt-5-codex")
        #expect(!Codex.arguments(project: "/home/me/shop", model: "").contains("-m"))
    }

    @Test func findsCodexInsideTheChatGPTApp() {
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        #expect(Codex.locate(environment: [:], home: URL(filePath: "/home/me"), isExecutable: { $0 == bundled }) == bundled)
        #expect(Codex.locate(environment: ["DANTE_CODEX": "/opt/codex"], home: URL(filePath: "/home/me"), isExecutable: { _ in true }) == "/opt/codex")
        #expect(Codex.locate(environment: [:], home: URL(filePath: "/home/me"), isExecutable: { _ in false }) == nil)
    }

    @Test func serverAsksCodexAndRecordsIt() async {
        let ledgerURL = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        var server = DelegateServer(project: "shop", ledger: AgentLedger(url: ledgerURL), models: { [] }) { _, _ in ("q", OllamaReply(text: "")) }
        server.offersLocal = false
        server.askCodex = { prompt in CodexReply(text: "Agreed: \(prompt)", commands: ["rg x"], inputTokens: 900, outputTokens: 40, seconds: 30) }
        let list = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) ?? ""
        #expect(list.contains(#""name":"ask_codex""#))
        let call = await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_codex","arguments":{"prompt":"is the cache safe?","title":"Cache review"}}}"#) ?? ""
        #expect(call.contains("Agreed: is the cache safe?") && call.contains("looked with 1 command"))
        let jobs = AgentLedger(url: ledgerURL).jobs()
        #expect(jobs.map(\.provider) == [.codex] && jobs.first?.title == "Cache review")
        #expect(AgentStats.agent(of: jobs[0]) == "Codex")
        let tool = ToolActivity(id: "c", name: "mcp__dante__ask_codex", input: ["prompt": "x", "title": "Cache review"], status: .running)
        #expect(tool.verb == "Asking Codex" && OrbSatellite.running(in: [tool]).first?.kind == .codex)
    }
}
