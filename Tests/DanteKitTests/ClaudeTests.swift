import Foundation
import Testing
@testable import DanteKit

struct ClaudeProtocolTests {
    @Test func parsesInitAndResult() {
        #expect(ClaudeEvent(line: #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus-5-5","tools":[]}"#)
            == .started(sessionID: "s1", model: "claude-opus-5-5"))
        let result = ClaudeEvent(line: #"{"type":"result","subtype":"success","is_error":false,"result":"Done","total_cost_usd":0.25,"duration_ms":1200}"#)
        #expect(result == .result(.init(isError: false, text: "Done", costUSD: 0.25, durationMS: 1200)))
    }

    @Test func parsesStreamingText() {
        #expect(ClaudeEvent(line: #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}},"parent_tool_use_id":null}"#)
            == .messageStarted(messageID: "m1"))
        #expect(ClaudeEvent(line: #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}"#)
            == .blockStarted(isText: true))
        #expect(ClaudeEvent(line: #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}},"parent_tool_use_id":null}"#)
            == .textDelta("Hi"))
    }

    @Test func parsesToolUseAndResults() {
        let assistant = ClaudeEvent(line: #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a.swift"}}]},"parent_tool_use_id":null}"#)
        #expect(assistant == .assistant(messageID: "m1", blocks: [.toolUse(id: "t1", name: "Read", input: ["file_path": "/a.swift"])]))

        let results = ClaudeEvent(line: #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"nope"}]}]},"parent_tool_use_id":null}"#)
        #expect(results == .toolResults([.init(toolUseID: "t1", isError: true, text: "nope")]))
    }

    @Test func ignoresSubagentMessagesButNotTheirPermissionRequests() {
        #expect(ClaudeEvent(line: #"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"x"}]},"parent_tool_use_id":"task1"}"#) == .ignored)
        let request = ClaudeEvent(line: #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"t9"}}"#)
        #expect(request == .permissionRequest(.init(requestID: "r1", toolName: "Bash", input: ["command": "ls"], toolUseID: "t9")))
    }

    @Test func ignoresGarbage() {
        #expect(ClaudeEvent(line: "not json") == .ignored)
        #expect(ClaudeEvent(line: #"{"type":"rate_limit_event"}"#) == .ignored)
    }

    @Test func encodesPermissionResponses() {
        let allow = ClaudeInput.allow(requestID: "r1", input: ["command": "ls"]).jsonLine
        #expect(allow == #"{"response":{"request_id":"r1","response":{"behavior":"allow","updatedInput":{"command":"ls"}},"subtype":"success"},"type":"control_response"}"#)
        let user = ClaudeInput.userMessage("hi").jsonLine
        #expect(user == #"{"message":{"content":"hi","role":"user"},"parent_tool_use_id":null,"type":"user"}"#)
    }

    @Test func environmentDropsNestedSessionMarkers() {
        let environment = ClaudeSession.environment(["CLAUDECODE": "1", "PATH": "/usr/bin", "HOME": "/h"])
        #expect(environment["CLAUDECODE"] == nil)
        #expect(environment["HOME"] == "/h")
        #expect(environment["PATH"]?.hasPrefix("/usr/bin:") == true)
        #expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    }
}

struct LineDiffTests {
    @Test func marksChangesWithLineNumbers() {
        let diff = LineDiff.lines(old: "a\nb\nc\n", new: "a\nB\nc\n")
        #expect(diff.map(\.kind) == [.context, .removed, .added, .context])
        #expect(diff[1].oldNumber == 2 && diff[2].newNumber == 2)
    }

    @Test func foldsLongUnchangedRuns() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "\n2\n", with: "\ntwo\n").replacingOccurrences(of: "\n19\n", with: "\nnineteen\n")
        let diff = LineDiff.lines(old: old, new: new, context: 2)
        #expect(diff.filter { $0.kind == .gap }.count == 1)
        #expect(diff.count { $0.kind == .context } == 6) // 1 above line 2, 2 below; 2 above line 19, 1 below
    }

    @Test func identicalTextsHaveNoDiff() {
        #expect(LineDiff.lines(old: "same\n", new: "same\n").isEmpty)
    }
}

@MainActor
struct ProposedChangeTests {
    @Test func editReplacesTheFirstMatch() throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "a.txt")
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        let change = try #require(ProposedChange.make(
            toolName: "Edit",
            input: ["file_path": .string(file.path), "old_string": "two", "new_string": "2"],
            root: folder.url
        ))
        #expect(change.displayPath == "a.txt")
        #expect(change.applies && !change.isNewFile)
        #expect(change.added == 1 && change.removed == 1)
    }

    @Test func editThatNoLongerMatchesIsFlagged() throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "a.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        let change = ProposedChange.make(toolName: "Edit", input: ["file_path": .string(file.path), "old_string": "zzz", "new_string": "y"], root: folder.url)
        #expect(change?.applies == false)
    }

    @Test func writeOfANewFileIsAllAdditions() throws {
        let folder = try TemporaryFolder()
        let change = try #require(ProposedChange.make(
            toolName: "Write",
            input: ["file_path": .string(folder.url.appending(path: "new.md").path), "content": "# Hi\n\nThere\n"],
            root: folder.url
        ))
        #expect(change.isNewFile && change.added == 3 && change.removed == 0)
    }

    @Test func otherToolsHaveNoChange() {
        #expect(ProposedChange.make(toolName: "Bash", input: ["command": "ls"], root: URL(filePath: "/")) == nil)
    }
}

@MainActor
struct ClaudeSessionTranscriptTests {
    private func session() -> ClaudeSession {
        ClaudeSession(root: URL(filePath: "/tmp"), executable: "/usr/bin/false", systemPrompt: { "" })
    }

    @Test func streamedTextIsReplacedByTheFinalMessage() {
        let session = session()
        session.handle(.messageStarted(messageID: "m1"))
        session.handle(.blockStarted(isText: true))
        session.handle(.textDelta("Hel"))
        session.handle(.textDelta("lo"))
        #expect(session.items.map(\.content) == [.assistant("Hello")])
        session.handle(.assistant(messageID: "m1", blocks: [.text("Hello!")]))
        #expect(session.items.map(\.content) == [.assistant("Hello!")])
    }

    @Test func permissionRequestAttachesToTheToolCall() {
        let session = session()
        session.handle(.assistant(messageID: "m1", blocks: [.toolUse(id: "t1", name: "Bash", input: ["command": "ls"])]))
        session.handle(.permissionRequest(.init(requestID: "r1", toolName: "Bash", input: ["command": "ls"], toolUseID: "t1")))
        #expect(session.items.count == 1)
        #expect(session.pendingApprovals.map(\.id) == ["t1"])

        session.decline("t1")
        session.handle(.toolResults([.init(toolUseID: "t1", isError: true, text: "denied")]))
        guard case .tool(let tool) = session.items[0].content else { Issue.record("expected a tool"); return }
        #expect(tool.status == .declined)
        #expect(session.pendingApprovals.isEmpty)
    }

    @Test func notLoggedInIsDetected() {
        let session = session()
        session.handle(.assistant(messageID: "m1", blocks: [.text("Not logged in · Please run /login")]))
        session.handle(.result(.init(isError: true, text: "Not logged in · Please run /login", costUSD: 0, durationMS: 1)))
        #expect(session.needsLogin)
        #expect(session.items.count == 1) // the error isn't repeated as a notice
    }

    @Test func resultEndsTheTurnAndAddsCost() {
        let session = session()
        session.handle(.result(.init(isError: false, text: "ok", costUSD: 0.1, durationMS: 5)))
        session.handle(.result(.init(isError: false, text: "ok", costUSD: 0.2, durationMS: 5)))
        #expect(session.state == .idle)
        #expect(abs(session.totalCostUSD - 0.3) < 0.0001)
    }
}

struct PipeLineReaderTests {
    @Test func splitsChunksIntoLines() async throws {
        let pipe = Pipe()
        let lines = ClaudeSession.lines(from: pipe.fileHandleForReading)
        let writer = pipe.fileHandleForWriting
        try writer.write(contentsOf: Data("one\ntw".utf8))
        try writer.write(contentsOf: Data("o\nthree".utf8))
        try writer.close()
        var received: [String] = []
        for await line in lines { received.append(line) }
        #expect(received == ["one", "two", "three"])
    }
}

struct ClaudeRulesTests {
    private let rules = ClaudeRules.parse(projectYAML: """
    name: ledger
    claude:
      propose: [src/, test/, docs/]
      flag: [migrations/, package.json]
      never: [".env*", secrets/]
    """)
    private let root = URL(filePath: "/p")

    @Test func parsesLists() {
        #expect(rules == ClaudeRules(propose: ["src/", "test/", "docs/"], flag: ["migrations/", "package.json"], never: [".env*", "secrets/"]))
        #expect(ClaudeRules.parse(projectYAML: "name: x\n").isEmpty)
        #expect(ClaudeRules.parse(projectYAML: "claude:\n  never: secrets/\n").never == ["secrets/"])
    }

    @Test func neverBlocksReadsEditsAndCommands() {
        guard case .blocked = rules.verdict(toolName: "Edit", input: ["file_path": "/p/.env.local"], root: root) else { Issue.record("edit"); return }
        guard case .blocked = rules.verdict(toolName: "Read", input: ["file_path": "/p/config/secrets/key.pem"], root: root) else { Issue.record("read"); return }
        guard case .blocked = rules.verdict(toolName: "Bash", input: ["command": "cat ./.env | grep KEY"], root: root) else { Issue.record("bash"); return }
        #expect(rules.verdict(toolName: "Bash", input: ["command": "swift test"], root: root) == .allowed)
    }

    @Test func flagAndOutsideProposeAddNotes() {
        guard case .note = rules.verdict(toolName: "Edit", input: ["file_path": "/p/db/migrations/001.sql"], root: root) else { Issue.record("flag"); return }
        guard case .note = rules.verdict(toolName: "Write", input: ["file_path": "/p/package.json"], root: root) else { Issue.record("file flag"); return }
        guard case .note = rules.verdict(toolName: "Edit", input: ["file_path": "/p/README.md"], root: root) else { Issue.record("outside"); return }
        #expect(rules.verdict(toolName: "Edit", input: ["file_path": "/p/src/app.ts"], root: root) == .allowed)
        #expect(rules.verdict(toolName: "Read", input: ["file_path": "/p/README.md"], root: root) == .allowed)
    }

    @Test func denyRulesForClaudeCode() {
        #expect(rules.denyRules == ["Read(**/.env*)", "Edit(**/.env*)", "Read(./secrets/**)", "Edit(./secrets/**)"])
        #expect(ClaudeRules().settingsJSON == nil)
        #expect(rules.settingsJSON?.contains(#""deny":["Read(**/.env*)""#) == true)
    }

    @Test func argumentsCarryRulesAndResume() {
        let arguments = ClaudeSession.arguments(systemPrompt: "p", rules: rules, resume: "s1")
        #expect(arguments.contains("--settings"))
        #expect(Array(arguments.suffix(2)) == ["--resume", "s1"])
        #expect(!ClaudeSession.arguments(systemPrompt: "p", rules: ClaudeRules(), resume: nil).contains("--settings"))
        let withModel = ClaudeSession.arguments(systemPrompt: "p", rules: ClaudeRules(), resume: nil, model: "sonnet")
        #expect(withModel.suffix(2) == ["--model", "sonnet"])
        #expect(!ClaudeSession.arguments(systemPrompt: "p", rules: ClaudeRules(), resume: nil).contains("--model"))
    }
}

@MainActor
struct ClaudeSessionRulesTests {
    @Test func neverRuleDeclinesWithoutAsking() {
        let session = ClaudeSession(
            root: URL(filePath: "/p"), executable: "/usr/bin/false", systemPrompt: { "" },
            rules: { ClaudeRules(never: [".env*"]) }
        )
        session.handle(.permissionRequest(.init(requestID: "r1", toolName: "Edit", input: ["file_path": "/p/.env"], toolUseID: "t1")))
        guard case .tool(let tool) = session.items.first?.content else { Issue.record("no tool"); return }
        #expect(tool.blockedByRule && tool.status == .declined)
        #expect(session.pendingApprovals.isEmpty)
    }
}

struct ToolSummaryTests {
    let root = URL(filePath: "/project")

    private func tool(_ name: String, _ input: JSONValue, _ status: ToolActivity.Status = .done) -> ToolActivity {
        ToolActivity(id: "t", name: name, input: input, status: status)
    }

    @Test func editVerbFollowsStatus() {
        #expect(tool("Edit", [:], .running).verb == "Edit")
        #expect(tool("MultiEdit", [:], .awaitingApproval(requestID: "r")).verb == "Edit")
        #expect(tool("Edit", [:]).verb == "Edited")
        #expect(tool("Edit", [:], .declined).verb == "Declined edit")
    }

    @Test func bashVerbAndFirstLineOfCommand() {
        let ran = tool("Bash", ["command": "swift build\nswift test"])
        #expect(ran.verb == "Ran")
        #expect(ran.target(in: root) == "swift build")
        #expect(tool("Bash", ["command": "rm -rf build"], .declined).verb == "Didn’t run")
        #expect(tool("Bash", ["command": "ls"], .running).verb == "Run")
    }

    @Test func filePathsAreProjectRelative() {
        #expect(tool("Read", ["file_path": "/project/Sources/App.swift"]).target(in: root) == "Sources/App.swift")
        #expect(tool("NotebookEdit", ["notebook_path": "/project/a.ipynb"]).target(in: root) == "a.ipynb")
    }

    @Test func searchesShowTheirPatternOrQuery() {
        #expect(tool("Grep", ["pattern": "TODO"]).verb == "Searched for")
        #expect(tool("Grep", ["pattern": "TODO"]).target(in: root) == "TODO")
        #expect(tool("WebSearch", ["query": "swift regex"]).target(in: root) == "swift regex")
        #expect(tool("WebFetch", ["url": "https://example.com"]).target(in: root) == "https://example.com")
        #expect(tool("Agent", ["description": "Find the parser"]).target(in: root) == "Find the parser")
    }

    @Test func blockedAndUnknownTools() {
        var blocked = tool("Read", ["file_path": "/project/.env"])
        blocked.blockedByRule = true
        #expect(blocked.verb == "Blocked")
        #expect(tool("mcp__thing__do", [:]).verb == "mcp__thing__do")
        #expect(tool("TodoWrite", [:]).target(in: root) == "")
    }
}
