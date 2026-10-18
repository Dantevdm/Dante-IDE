import Foundation
import Testing
@testable import DanteKit

@Suite struct AgentDigestTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func job(_ kind: String, _ provider: AgentJob.Provider, at offset: TimeInterval, by requester: String,
                     model: String = "m", title: String = "", seconds: Double = 0, outcome: AgentJob.Outcome = .done,
                     why: String? = nil, gist: String? = nil, files: [String]? = nil, tokens: Int = 0, project: String = "app") -> AgentJob {
        AgentJob(date: start.addingTimeInterval(offset), kind: kind, provider: provider, model: model, project: project,
                 promptTokens: tokens, seconds: seconds, outcome: outcome, requestedBy: requester, title: title,
                 why: why, gist: gist, files: files)
    }

    @Test func helpersJoinTheRequestTheyRanIn() {
        let jobs = [
            job("summary", .local, at: 10, by: "codex", model: "qwen3:14b", title: "Summarise the log", tokens: 300),
            job("opinion", .claude, at: 20, by: "codex", model: "claude", title: "Review the patch",
                why: "check the migration can't lock the table", gist: "Looks safe."),
            job("turn", .codex, at: 30, by: "you", model: "gpt-6.1-sol", title: "Add an index", seconds: 30, files: ["db/migrate.sql"]),
            job("commitMessage", .local, at: 40, by: "dante", model: "qwen3:14b", title: "Commit messages", tokens: 100),
            job("summary", .local, at: 25, by: "claude", model: "qwen3:14b", title: "Elsewhere", project: "other"),
        ]
        let digest = AgentDigest(jobs)
        let request = digest.threads.first { $0.lead.role == .led }
        #expect(request?.lead.agent == "Codex")
        #expect(request?.helpers.map(\.job.title) == ["Summarise the log", "Review the patch"])
        #expect(digest.threads.count == 3)
        #expect(digest.checks.first?.agent == "Claude")
        #expect(digest.checks.first?.asker == "Codex")
        #expect(digest.checks.first?.job.why == "check the migration can't lock the table")
    }

    @Test func sentencesTellTheStory() {
        let jobs = [
            job("turn", .codex, at: 0, by: "you", title: "One", seconds: 5, files: ["LIST.md"]),
            job("turn", .codex, at: 60, by: "you", title: "Two", seconds: 5, files: ["LIST.md", "src/a.swift"]),
            job("turn", .claude, at: 120, by: "you", model: "opus", title: "Three", seconds: 5),
            job("opinion", .claude, at: 58, by: "codex", title: "Review"),
            job("opinion", .claude, at: 59, by: "codex", title: "Review again"),
            job("summary", .local, at: 115, by: "claude", model: "qwen3:14b", tokens: 387),
            job("draft", .local, at: 200, by: "claude", title: "Draft the parser", outcome: .failed),
        ]
        let sentences = AgentDigest(jobs).sentences
        #expect(sentences[0] == "You asked for 3 things: Codex led 2 and Claude led 1.")
        #expect(sentences[1] == "Together they changed 2 files (LIST.md, a.swift).")
        #expect(sentences[2] == "Claude checked Codex’s work twice.")
        #expect(sentences[3] == "Local models took 2 jobs (summaries and code drafts), keeping 387 tokens off your plans.")
        #expect(sentences.last == "1 job failed: Drafter on “Draft the parser”.")
    }

    @Test func saysWhenNothingWasChecked() {
        let jobs = [job("turn", .claude, at: 0, by: "you"), job("turn", .claude, at: 100, by: "you")]
        let sentences = AgentDigest(jobs).sentences
        #expect(sentences.first == "You asked for 2 things, both led by Claude.")
        #expect(sentences.contains { $0.hasPrefix("Nothing was cross-checked") })
    }

    @Test func modelsSayWhatTheyDid() {
        let jobs = [
            job("summary", .local, at: 0, by: "claude", model: "qwen3:14b"),
            job("commitMessage", .local, at: 1, by: "dante", model: "qwen3:14b"),
            job("turn", .claude, at: 2, by: "you", model: "claude-opus-5-5"),
            job("opinion", .codex, at: 3, by: "claude", model: "codex"),
        ]
        let models = AgentDigest(jobs).models
        #expect(models.first?.name == "qwen3:14b")
        #expect(models.first?.agents == ["Reader", "Scribe"])
        #expect(models.first?.work == ["summaries", "commit messages"])
        #expect(models.contains { $0.name == "Claude Opus" && $0.work == ["led your requests"] })
        #expect(models.contains { $0.name == "Codex" && $0.work == ["checked Claude’s work"] })
    }

    @Test func gistIsTheFirstPlainSentence() {
        #expect(AgentJob.gist(of: "[Codex · 10→20 tokens · 3s] A second opinion: weigh it, don’t just adopt it.\n\n## Review\n**Looks safe.** The index is built concurrently.") == "Looks safe.")
        #expect(AgentJob.gist(of: "```swift\nlet x = 1\n```\n- Use `x` here, e.g. in tests. Then ship.") == "Use x here, e.g. in tests.")
        #expect(AgentJob.gist(of: "1. First point\n2. Second") == "First point")
        #expect(AgentJob.gist(of: String(repeating: "word ", count: 60))?.count == 160)
        #expect(AgentJob.gist(of: "\n\n") == nil)
    }

    @Test func oldLedgerLinesStillRead() {
        let line = #"{"id":"6B1D5E1C-1F2A-4C7B-9C55-0A1B2C3D4E5F","date":"2026-10-18T10:00:00Z","kind":"turn","provider":"claude","model":"opus","project":"app","promptTokens":1,"outputTokens":2,"seconds":3,"outcome":"done","requestedBy":"you","title":"Hi"}"#
        let jobs = AgentLedger.parse(Data(line.utf8))
        #expect(jobs.count == 1)
        #expect(jobs.first?.why == nil && jobs.first?.files == nil)
    }

    @Test func serverToolsAskWhy() {
        let tool = DelegateServer.askingWhy(DelegateServer.codexTool)
        #expect(tool["inputSchema"]?["properties"]?["why"]?["type"]?.string == "string")
    }

    @Test func auditsCountAsChecks() {
        let digest = AgentDigest([job("audit", .codex, at: 0, by: "you", model: "gpt-6.1-sol", title: "Security audit")])
        #expect(digest.checks.first?.agent == "Codex")
        #expect(digest.models.first?.work == ["security audits"])
    }
}
