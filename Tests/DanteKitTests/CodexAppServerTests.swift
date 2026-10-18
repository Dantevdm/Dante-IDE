@testable import DanteKit
import Foundation
import Testing

@Suite struct CodexAppServerTests {
    private func events(_ incoming: [CodexIncoming]) -> [ClaudeEvent] {
        incoming.compactMap { if case .event(let event) = $0 { event } else { nil } }
    }

    @Test func streamsAgentMessages() {
        var translator = CodexTranslator()
        let started = translator.translate(#"{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_1","text":"","phase":"final_answer"},"threadId":"t","turnId":"u","startedAtMs":1}}"#)
        #expect(events(started) == [.messageStarted(messageID: "msg_1"), .blockStarted(isText: true)])
        #expect(events(translator.translate(#"{"method":"item/agentMessage/delta","params":{"delta":"Added","itemId":"msg_1","threadId":"t","turnId":"u"}}"#)) == [.textDelta("Added")])
        let done = translator.translate(#"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_1","text":"Added `- eggs`."},"threadId":"t","turnId":"u"}}"#)
        #expect(events(done) == [.assistant(messageID: "msg_1", blocks: [.text("Added `- eggs`.")])])
    }

    @Test func commandsAskForApprovalAsBash() throws {
        var translator = CodexTranslator()
        let started = translator.translate(#"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"exec-1","command":"/bin/zsh -lc 'cat LIST.md'","cwd":"/home/me/shop","status":"inProgress","commandActions":[]},"threadId":"t","turnId":"u"}}"#)
        #expect(events(started) == [.assistant(messageID: "exec-1", blocks: [.toolUse(id: "exec-1", name: "Bash", input: ["command": "cat LIST.md"])])])
        let request = translator.translate(#"{"method":"item/commandExecution/requestApproval","id":7,"params":{"kind":"command","threadId":"t","turnId":"u","itemId":"exec-1","startedAtMs":1,"command":"/bin/zsh -lc 'cat LIST.md'","cwd":"/home/me/shop"}}"#)
        #expect(events(request) == [.permissionRequest(.init(requestID: "codex-7", toolName: "Bash", input: ["command": "cat LIST.md"], toolUseID: "exec-1"))])
        #expect(translator.reply(to: "codex-7", accept: true) == ["id": 7, "result": ["decision": "accept"]])
        #expect(translator.reply(to: "codex-7", accept: true) == nil)
        let finished = translator.translate(#"{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"exec-1","command":"cat LIST.md","status":"completed","exitCode":1,"aggregatedOutput":"no such file"},"threadId":"t","turnId":"u"}}"#)
        #expect(events(finished) == [.toolResults([.init(toolUseID: "exec-1", isError: true, text: "no such file")])])
    }

    @Test func patchesBecomeReviewableEdits() throws {
        var translator = CodexTranslator()
        let item = #"{"method":"item/started","params":{"item":{"type":"fileChange","id":"patch-1","status":"inProgress","changes":[{"path":"/home/me/shop/LIST.md","kind":{"type":"update","move_path":null},"diff":"@@ -1,2 +1,3 @@\n Shopping list\n-- milk\n+- oat milk\n+- eggs\n"},{"path":"/home/me/shop/NEW.md","kind":{"type":"add"},"diff":"hello\n"}]},"threadId":"t","turnId":"u"}}"#
        guard case .event(.assistant(_, let blocks, _)) = translator.translate(item).first, case .toolUse(_, let name, let input) = blocks.first else {
            Issue.record("expected a tool use")
            return
        }
        #expect(name == CodexTranslator.patchTool && input["file_path"] == "/home/me/shop/LIST.md")
        let request = translator.translate(#"{"method":"item/fileChange/requestApproval","id":3,"params":{"itemId":"patch-1","startedAtMs":1,"threadId":"t","turnId":"u"}}"#)
        #expect(events(request) == [.permissionRequest(.init(requestID: "codex-3", toolName: CodexTranslator.patchTool, input: input, toolUseID: "patch-1"))])
        #expect(translator.reply(to: "codex-3", accept: false) == ["id": 3, "result": ["decision": "decline"]])

        let change = try #require(ProposedChange.make(toolName: name, input: input, root: URL(filePath: "/home/me/shop")))
        #expect(change.displayPath == "LIST.md and 1 more" && change.added == 3 && change.removed == 1)
        #expect(change.lines.first == DiffLine(kind: .file, text: "LIST.md"))
        #expect(change.lines.contains(DiffLine(kind: .removed, text: "- milk", oldNumber: 2)))
        #expect(change.lines.contains(DiffLine(kind: .added, text: "- eggs", newNumber: 3)))
        #expect(change.lines.contains(DiffLine(kind: .file, text: "NEW.md (new)")))
        #expect(ApprovalPolicy.approves(name, input: input, level: .edits, allow: [], hasRuleNote: false))
        #expect(ApprovalPolicy.rules(for: name, input: input) == ["Edit"])
    }

    @Test func patchesRespectNeverRulesOnEveryFile() {
        let rules = ClaudeRules(never: ["secrets/"])
        let input = CodexTranslator.patchInput([["path": "/home/me/shop/a.md", "kind": ["type": "update"], "diff": ""],
                                                ["path": "/home/me/shop/secrets/key.txt", "kind": ["type": "update"], "diff": ""]])
        guard case .blocked = rules.verdict(toolName: CodexTranslator.patchTool, input: input, root: URL(filePath: "/home/me/shop")) else {
            Issue.record("a patch touching a never path should be blocked")
            return
        }
    }

    @Test func usageLimitsAndTurnResults() {
        var translator = CodexTranslator()
        let usageLine = #"{"method":"thread/tokenUsage/updated","params":{"threadId":"t","turnId":"u","tokenUsage":{"total":{"totalTokens":35477,"inputTokens":35355,"cachedInputTokens":29696,"outputTokens":122,"reasoningOutputTokens":0},"last":{"totalTokens":17814,"inputTokens":17773,"cachedInputTokens":17408,"outputTokens":41,"reasoningOutputTokens":0},"modelContextWindow":475000}}}"#
        #expect(events(translator.translate(usageLine)) == [.assistant(messageID: "usage-1", blocks: [], usage: TokenUsage(input: 365, output: 41, cacheRead: 17408))])
        #expect(CodexTranslator.contextWindow(usageLine) == 475_000)
        let limits = translator.translate(#"{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1792349764},"secondary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1792936564},"planType":"plus"}}}"#)
        #expect(limits == [.limits(CodexLimits(primary: .init(usedPercent: 12, minutes: 300, resetsAt: Date(timeIntervalSince1970: 1792349764)),
                                               secondary: .init(usedPercent: 3, minutes: 10080, resetsAt: Date(timeIntervalSince1970: 1792936564)), plan: "plus"))])
        let failed = translator.translate(#"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","items":[],"status":"failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"The 'gpt-x' model is not supported.\"}}"},"durationMs":4143}}}"#)
        #expect(events(failed) == [.result(.init(isError: true, text: "The 'gpt-x' model is not supported.", durationMS: 4143))])
        #expect(translator.translate(#"{"method":"turn/started","params":{"threadId":"t","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#) == [.turnStarted("turn-9")])
        #expect(translator.translate(#"{"id":4,"result":{"turn":{"id":"turn-9"}}}"#) == [.response(id: 4, result: ["turn": ["id": "turn-9"]], error: nil)])
    }

    @Test func questionsAndUnknownRequests() {
        var translator = CodexTranslator()
        let asked = translator.translate(#"{"method":"item/tool/requestUserInput","id":11,"params":{"isBlocking":true,"itemId":"q-1","threadId":"t","turnId":"u","questions":[{"id":"db","header":"Database","question":"Which database?","options":[{"label":"Postgres","description":"Matches prod"},{"label":"SQLite","description":"Simpler"}]}]}}"#)
        guard case .event(.permissionRequest(let request)) = asked.first else {
            Issue.record("expected a question")
            return
        }
        #expect(request.toolName == "AskUserQuestion" && ClarifyingQuestion.parse(request.input).first?.options.map(\.label) == ["Postgres", "SQLite"])
        #expect(translator.reply(to: "codex-11", accept: true, answers: ["Which database?": "Postgres"]) == ["id": 11, "result": ["answers": ["db": ["answers": ["Postgres"]]]]])
        let unknown = translator.translate(#"{"method":"account/chatgptAuthTokens/refresh","id":12,"params":{}}"#)
        guard case .reply(let reply) = unknown.first else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reply["id"] == 12 && reply["error"]?["code"] == -32601)
    }

    @Test func readsTheModelList() {
        let result: JSONValue = ["data": [
            ["id": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol", "description": "Workhorse", "isDefault": true, "hidden": false,
             "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "high"]]],
            ["id": "secret-model", "hidden": true],
            ["id": "gpt-6-astra", "displayName": "GPT-6-Astra", "description": "Frontier", "isDefault": false],
        ]]
        #expect(CodexModel.parse(result) == [CodexModel(id: "gpt-6.1-sol", name: "GPT-6.1-Sol", summary: "Workhorse", isDefault: true, efforts: ["low", "high"]),
                                             CodexModel(id: "gpt-6-astra", name: "GPT-6-Astra", summary: "Frontier")])
    }

    @Test func requestsCarryTheProjectAndModel() {
        let thread = CodexRequest.thread(id: 3, resume: nil, cwd: "/home/me/shop", model: "gpt-6.1-sol", instructions: "Pair mode",
                                         mcp: CodexRequest.mcpServer(command: "/home/me/dante", environment: ["DANTE_REQUESTER": "codex"]))
        #expect(thread["method"] == "thread/start" && thread["params"]?["approvalPolicy"] == "untrusted" && thread["params"]?["sandbox"] == "workspace-write")
        #expect(thread["params"]?["config"]?["mcp_servers"]?["dante"]?["args"] == ["mcp"])
        #expect(CodexRequest.thread(id: 3, resume: "t1", cwd: "/x", model: nil, instructions: "", mcp: nil)["method"] == "thread/resume")
        let turn = CodexRequest.turn(id: 4, thread: "t1", text: "Hi", images: ["/home/me/shot.png"], model: nil, effort: "high")
        #expect(turn["params"]?["input"] == [["type": "localImage", "path": "/home/me/shot.png"], ["type": "text", "text": "Hi"]])
        #expect(turn["params"]?["effort"] == "high" && turn["params"]?["model"] == nil)
    }

    @Test func readOnlyCommandsGoAhead() {
        for command in ["rg -n startup NOTES.md", "pwd && rg --files -g 'LIST.md'", "sed -n '1,40p' main.go", "git log --oneline -5 | head -3",
                        "find . -name '*.swift'", "cat a.txt 2>/dev/null", "ls -la"] {
            #expect(ApprovalPolicy.readsOnly(command), "\(command)")
        }
        for command in ["sed -i '' s/a/b/ x", "find . -delete", "rm -rf build", "git commit -m x", "cat a > b", "echo $(whoami)",
                        "printf 'x' >> LIST.md", "git push", "awk '{print}' x"] {
            #expect(!ApprovalPolicy.readsOnly(command), "\(command)")
        }
        #expect(ApprovalPolicy.approves("Bash", input: ["command": "rg TODO"], level: .ask, allow: [], hasRuleNote: false))
        #expect(!ApprovalPolicy.approves("Bash", input: ["command": "make"], level: .ask, allow: [], hasRuleNote: false))
    }

    @Test func claudeAnswersCodexReadOnly() throws {
        let output = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":8300,"result":"Looks right; the cache key misses the locale.","total_cost_usd":0.04,"usage":{"input_tokens":12,"cache_read_input_tokens":9000,"cache_creation_input_tokens":800,"output_tokens":95}}"#
        #expect(try ClaudeReply.parse(output) == ClaudeReply(text: "Looks right; the cache key misses the locale.", inputTokens: 9812, outputTokens: 95, seconds: 8.3, costUSD: 0.04))
        #expect(throws: ClaudeOpinion.Failure(message: "Not logged in")) {
            try ClaudeReply.parse(#"{"type":"result","is_error":true,"result":"Not logged in"}"#)
        }
        let arguments = ClaudeOpinion.arguments(model: "opus")
        #expect(arguments.contains("Read,Grep,Glob") && arguments.contains("dontAsk") && arguments.suffix(2) == ["--model", "opus"])
    }

    @Test func serverOffersClaudeToCodex() async {
        let ledgerURL = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        var server = DelegateServer(project: "shop", ledger: AgentLedger(url: ledgerURL), models: { [] }) { _, _ in ("q", OllamaReply(text: "")) }
        server.offersLocal = false
        server.requester = "codex"
        server.askClaude = { prompt in ClaudeReply(text: "Agreed: \(prompt)", inputTokens: 500, outputTokens: 20, seconds: 9) }
        let list = await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) ?? ""
        #expect(list.contains(#""name":"ask_claude""#) && !list.contains("ask_codex"))
        let call = await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_claude","arguments":{"prompt":"is it safe?","title":"Safety"}}}"#) ?? ""
        #expect(call.contains("Agreed: is it safe?"))
        let job = AgentLedger(url: ledgerURL).jobs().first
        #expect(job?.provider == .claude && job?.requestedBy == "codex" && job?.title == "Safety")
        let tool = ToolActivity(id: "c", name: "mcp__dante__ask_claude", input: ["prompt": "x"], status: .running)
        #expect(tool.verb == "Asking Claude" && OrbSatellite.running(in: [tool]).first?.kind == .claude)
    }

    @Test @MainActor func codexTurnsFillTheSameTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Shopping list\n".write(to: root.appending(path: "LIST.md"), atomically: true, encoding: .utf8)
        let session = ClaudeSession(root: root, executable: nil, systemPrompt: { "" })
        session.engine = .codex
        let path = root.appending(path: "LIST.md").path
        session.receiveCodex(#"{"method":"item/started","params":{"item":{"type":"fileChange","id":"p1","status":"inProgress","changes":[{"path":"\#(path)","kind":{"type":"update"},"diff":"@@ -1 +1,2 @@\n Shopping list\n+- eggs\n"}]},"threadId":"t","turnId":"u"}}"#)
        session.receiveCodex(#"{"method":"item/fileChange/requestApproval","id":2,"params":{"itemId":"p1","startedAtMs":1,"threadId":"t","turnId":"u"}}"#)
        let waiting = try #require(session.pendingApprovals.first)
        #expect(waiting.name == CodexTranslator.patchTool && waiting.change?.added == 1 && waiting.verb == "Edit")
        session.receiveCodex(#"{"method":"thread/tokenUsage/updated","params":{"threadId":"t","turnId":"u","tokenUsage":{"total":{"inputTokens":1,"cachedInputTokens":0,"outputTokens":1,"totalTokens":2,"reasoningOutputTokens":0},"last":{"inputTokens":900,"cachedInputTokens":100,"outputTokens":20,"totalTokens":920,"reasoningOutputTokens":0},"modelContextWindow":475000}}}"#)
        #expect(session.context?.context == 920 && session.contextWindow == 475_000)
    }

    @Test func handoverSummarisesTheConversation() {
        let items = [
            TranscriptItem(id: "1", content: .user("Add a cache", attachments: [])),
            TranscriptItem(id: "2", content: .assistant("Added an LRU cache to Store.swift.")),
            TranscriptItem(id: "3", content: .tool(ToolActivity(id: "e", name: "Edit", input: ["file_path": "/home/me/Store.swift"], status: .done))),
            TranscriptItem(id: "4", content: .notice("Undid", isError: false)),
        ]
        let text = ClaudeSession.handover(items, from: .claude) ?? ""
        #expect(text.contains("from Claude") && text.contains("User: Add a cache") && text.contains("Claude: Added an LRU cache"))
        #expect(text.contains("(Claude edited Store.swift)") && !text.contains("Undid"))
        #expect(text.range(of: "User: Add a cache")!.lowerBound < text.range(of: "Claude: Added")!.lowerBound)
        #expect(ClaudeSession.handover([], from: .codex) == nil)
    }
}
