import Testing
@testable import DanteKit

struct ComposeLogsTests {
    @Test func splitsServiceTimestampAndMessage() {
        let line = LogLine.parse("app-1  | 2026/10/09 09:54:14 [db] migrations applied", id: 1, service: "x")
        #expect(line.service == "app" && line.timestamp == "2026/10/09 09:54:14" && line.message == "[db] migrations applied" && line.level == .info)
        let iso = LogLine.parse("ollama  | time=2026-10-09T09:26:38.751Z level=INFO msg=\"server config\"", id: 2, service: "x")
        #expect(iso.service == "ollama" && iso.timestamp == nil && iso.level == .info)
        let bracketed = LogLine.parse("[2026-10-09 09:54:14,123] WARNING: disk almost full", id: 3, service: "db")
        #expect(bracketed.service == "db" && bracketed.timestamp == "[2026-10-09 09:54:14,123]" && bracketed.message == "WARNING: disk almost full" && bracketed.level == .warning)
        #expect(LogLine.parse("app  |", id: 4, service: "x").message == "")
    }

    @Test func readsLevels() {
        #expect(LogLine.level(of: "level=ERROR msg=boom") == .error)
        #expect(LogLine.level(of: "panic: runtime error: index out of range") == .error)
        #expect(LogLine.level(of: "{\"level\":\"warn\",\"msg\":\"slow\"}") == .warning)
        #expect(LogLine.level(of: "[debug] cache miss") == .debug)
        #expect(LogLine.level(of: "seeded 10 errors-free emails") == .info)
        #expect(LogLine.level(of: "Traceback (most recent call last):") == .error)
    }

    @Test func filtersBySearchAndLevel() {
        let lines = [
            LogLine(id: 1, service: "app", message: "listening on :3000"),
            LogLine(id: 2, service: "app", message: "GET /api/stats 500", level: .error),
            LogLine(id: 3, service: "app", message: "cache miss", level: .debug),
        ]
        #expect(LogFilter(query: "API").apply(lines).map(\.id) == [2])
        #expect(LogFilter(query: "api", onlyMatches: false).apply(lines).map(\.id) == [1, 2, 3])
        #expect(LogFilter(minimum: .info).apply(lines).map(\.id) == [1, 2])
        #expect(LogFilter(minimum: .error).apply(lines).map(\.id) == [2])
        #expect(LogFilter.ranges(of: "a", in: "banana").count == 3)
        #expect(LogFilter.ranges(of: "  ", in: "banana").isEmpty)
    }
}
