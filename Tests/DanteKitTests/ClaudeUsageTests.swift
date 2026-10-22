import Foundation
import Testing
@testable import DanteKit

struct ClaudeUsageTests {
    static let transcript = """
    {"type":"user","uuid":"u1","timestamp":"2026-10-12T08:05:00.000Z","message":{"role":"user","content":"Add a stats endpoint\\n\\n<dante-context>\\nThe user has main.go open\\n</dante-context>"}}
    {"type":"assistant","requestId":"r1","timestamp":"2026-10-12T08:05:03.000Z","message":{"id":"m1","model":"claude-sonnet","content":[{"type":"text","text":"Looking at the router."}],"usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":1000,"cache_read_input_tokens":5000}}}
    {"type":"assistant","requestId":"r1","timestamp":"2026-10-12T08:05:04.000Z","message":{"id":"m1","model":"claude-sonnet","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/home/me/app/main.go"}}],"usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":1000,"cache_read_input_tokens":5000}}}
    {"type":"user","uuid":"u2","timestamp":"2026-10-12T08:05:09.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
    {"type":"user","uuid":"u3","isMeta":true,"timestamp":"2026-10-12T08:05:10.000Z","message":{"role":"user","content":"<command-name>/compact</command-name>"}}
    {"type":"assistant","isSidechain":true,"requestId":"r9","timestamp":"2026-10-12T08:06:00.000Z","message":{"id":"m9","model":"claude-haiku","content":[{"type":"text","text":"subagent"}],"usage":{"input_tokens":5,"output_tokens":5}}}
    {"type":"assistant","requestId":"r2","timestamp":"2026-10-12T14:30:00.000Z","message":{"id":"m2","model":"claude-sonnet","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}
    """

    @Test func readsAConversationBack() {
        let items = ClaudeHistory.items(fromTranscript: Self.transcript)
        #expect(items.count == 4)
        #expect(items[0].content == .user("Add a stats endpoint"))
        #expect(items[1].content == .assistant("Looking at the router."))
        guard case .tool(let tool) = items[2].content else { Issue.record("expected a tool"); return }
        #expect(tool.name == "Edit" && tool.status == .done)
        #expect(items[3].content == .assistant("Done."))
    }

    @Test func countsEachCallOnceInFiveHourWindows() {
        let entries = ClaudeUsage.entries(fromTranscript: Self.transcript)
        // m1's two lines are one call; the subagent's call still counts against the plan.
        #expect(entries.count == 3)
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-10-12T15:00:00Z")!
        let usage = ClaudeUsage.summarise(entries, now: now)
        // 08:05 opens a window at 08:00 that ends at 13:00; 14:30 opens the current one.
        #expect(usage.current?.start == formatter.date(from: "2026-10-12T14:00:00Z"))
        #expect(usage.current?.resets == formatter.date(from: "2026-10-12T19:00:00Z"))
        #expect(usage.current?.usage.weighted == 6)
        #expect(usage.busiestWindow?.weighted == 1030 + 10)
        #expect(ClaudeUsage.summarise(entries, now: formatter.date(from: "2026-10-12T20:00:00Z")!).current == nil)
    }

    @Test func keepsOnlyThePlanFromAuthStatus() {
        let account = ClaudeAccount.parse(#"{"loggedIn": true, "authMethod": "claude.ai", "email": "me@example.com", "subscriptionType": "pro"}"#)
        #expect(account?.loggedIn == true && account?.plan == "pro" && account?.method == "claude.ai")
        #expect(account?.planName == "Pro plan")
        #expect(ClaudeUsage.short(1_234_567) == "1.2M" && ClaudeUsage.short(86_400) == "86k")
    }

    @Test func noticesADifferentSignInWithoutKeepingTheAddress() throws {
        // Claude Code prints its status as indented JSON.
        func status(_ email: String, _ org: String) -> String {
            "{\n  \"loggedIn\": true,\n  \"authMethod\": \"claude.ai\",\n  \"email\": \"\(email)\",\n  \"orgId\": \"\(org)\",\n  \"subscriptionType\": \"max\"\n}\n"
        }
        let old = try #require(ClaudeAccount.parse(status("old@example.com", "org-1")))
        let new = try #require(ClaudeAccount.parse(status("new@example.com", "org-2")))
        #expect(old.identity != nil && old.identity != new.identity && old.plan == "max")
        #expect(old.identity == ClaudeAccount.parse(status("old@example.com", "org-1"))?.identity)
        #expect(!(old.identity ?? "").contains("example") && !"\(old)".contains("old@"))
        #expect(ClaudeAccount.parse(#"{"loggedIn": false}"#)?.identity == nil)
        #expect(ClaudeSession.accountChanged(started: old.identity, now: new.identity))
        #expect(!ClaudeSession.accountChanged(started: old.identity, now: old.identity))
        // Not known yet, or signed out: carry on with the process as it is.
        #expect(!ClaudeSession.accountChanged(started: nil, now: new.identity) && !ClaudeSession.accountChanged(started: old.identity, now: nil))
    }

    @MainActor
    @Test func costIsARunningTotalNotASum() {
        let session = ClaudeSession(root: URL(filePath: "/home/me/app"), executable: nil, systemPrompt: { "" })
        session.handle(.result(.init(isError: false, text: "", costUSD: 0.10, contextWindow: 200_000)))
        session.handle(.result(.init(isError: false, text: "", costUSD: 0.25)))
        #expect(abs(session.totalCostUSD - 0.25) < 0.0001)
        session.handle(.assistant(messageID: "m1", blocks: [.text("hi")], usage: TokenUsage(input: 5, output: 5, cacheWrite: 10, cacheRead: 80)))
        #expect(session.context?.context == 100)
    }
}
