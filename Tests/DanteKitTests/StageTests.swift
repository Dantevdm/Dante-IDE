import DanteKit
import Foundation
import Testing

@Suite struct StageTests {
    @Test func captionKeepsTheNewestWords() {
        let short = "I'll **look** at `Parser.swift` first."
        #expect(StageCaption.tail(of: short) == "I'll look at Parser.swift first.")
        let reply = (1...12).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let tail = StageCaption.tail(of: reply, length: 70)
        #expect(tail.hasSuffix("Sentence number 12 is here."))
        #expect(tail.count <= 70)
        #expect(tail.hasPrefix("Sentence number"))
        let run = String(repeating: "word ", count: 80) + "end"
        let words = StageCaption.tail(of: run, length: 40)
        #expect(words.hasPrefix("…word") && words.hasSuffix("end") && words.count <= 40)
    }

    @Test func tallyCountsTodaysJobs() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func job(_ provider: AgentJob.Provider, _ model: String, _ tokens: Int, at offset: TimeInterval) -> AgentJob {
            AgentJob(date: start.addingTimeInterval(offset), kind: "summary", provider: provider, model: model, project: "shop",
                     promptTokens: tokens, outputTokens: 0, seconds: 1, outcome: .done, requestedBy: "claude", title: "x")
        }
        let tally = StageTally(jobs: [
            job(.local, "qwen3:14b", 900, at: 10), job(.local, "qwen3:14b", 100, at: 20),
            job(.local, "devstral:24b", 50, at: 30), job(.claude, "opus", 5000, at: 40),
            job(.local, "qwen3:14b", 7000, at: -10),
        ], since: start)
        #expect(tally.localJobs == 3 && tally.claudeJobs == 1)
        #expect(tally.tokensKeptLocal == 1050)
        #expect(tally.topLocalModel == "qwen3:14b")
    }
}
