import Foundation
import Testing
@testable import DanteKit

@Suite struct TimelineTests {
    @Test func readsCommitsAndTags() {
        let output = "aaa1111\u{1F}Add search\u{1F}Someone\u{1F}2026-05-01T10:00:00Z\u{1F}HEAD -> main, tag: v1.2.0, origin/main\n"
            + "bbb2222\u{1F}Start\u{1F}Someone\u{1F}2026-04-30T09:00:00Z\u{1F}"
        let events = Timeline.commits(from: output)
        #expect(events.map(\.kind) == [.commit, .release, .commit])
        #expect(events[0].detail == "Someone · aaa1111" && events[0].reference == "aaa1111")
        #expect(events[1].title == "Tagged v1.2.0" && events[1].date > events[0].date)
    }

    @Test func readsAClaudeTranscript() {
        let transcript = """
        {"type":"queue-operation","timestamp":"2026-05-01T10:00:00.000Z"}
        {"type":"user","message":{"role":"user","content":"Add a dark theme\\nwith tokens"},"timestamp":"2026-05-01T10:00:01.000Z"}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]},"timestamp":"2026-05-01T10:05:00.000Z"}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"timestamp":"2026-05-01T10:05:01.000Z"}
        {"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"timestamp":"2026-05-01T10:06:00.000Z"}
        {"type":"user","message":{"role":"user","content":"Now the light one"},"timestamp":"2026-05-01T10:30:00.000Z"}
        """
        let event = ClaudeTranscripts.session(id: "abc", transcript: transcript)
        #expect(event?.title == "Add a dark theme with tokens")
        #expect(event?.detail == "2 prompts · 30 min · 1 edit")
        #expect(event?.isQuick == false && event?.reference == "abc")

        let named = transcript + "\n{\"type\":\"custom-title\",\"customTitle\":\"Themes\"}"
        #expect(ClaudeTranscripts.session(id: "abc", transcript: named)?.title == "Themes")
        let quick = #"{"type":"user","message":{"content":"Write a commit message"},"timestamp":"2026-05-01T10:00:01.000Z"}"#
        #expect(ClaudeTranscripts.session(id: "q", transcript: quick)?.isQuick == true)
        #expect(ClaudeTranscripts.session(id: "e", transcript: "") == nil)
    }

    @Test func findsTheTranscriptFolder() {
        let folder = ClaudeTranscripts.folder(for: URL(filePath: "/home/me/Code/My App.v2"), home: URL(filePath: "/home/me"))
        #expect(folder.path == "/home/me/.claude/projects/-home-me-Code-My-App-v2")
    }

    @Test func keepsTestHistoryPerProject() {
        let name = "dante-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let root = URL(filePath: "/p/one")
        TestRecord(date: Date(timeIntervalSince1970: 1), label: "swift test", passed: 10, failed: 0, skipped: 1, duration: 3.2).append(for: root, defaults: defaults)
        TestRecord(date: Date(timeIntervalSince1970: 2), label: "swift test", passed: 9, failed: 1, skipped: 0, duration: 2).append(for: root, defaults: defaults)
        let records = TestRecord.load(for: root, defaults: defaults)
        #expect(records.count == 2 && TestRecord.load(for: URL(filePath: "/p/two"), defaults: defaults).isEmpty)
        #expect(records[0].event.title == "10 tests passed" && records[0].event.detail == "swift test · 3s · 1 skipped")
        #expect(records[1].event.title == "1 test failed" && records[1].event.outcome == .bad)
    }

    @Test func turnsCIRunsIntoEvents() {
        let run = CIRun(id: 7, title: "Fix", workflow: "CI", branch: "main", status: "completed", conclusion: "failure", created: Date(), url: nil)
        #expect(Timeline.event(for: run)?.outcome == .bad)
        #expect(Timeline.event(for: run)?.detail == "main · failure")
    }
}
