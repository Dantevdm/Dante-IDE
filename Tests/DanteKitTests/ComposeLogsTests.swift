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

    @Test func hidesHealthCheckRequests() {
        let raw = [
            "ollama-1  | [GIN] 2026/10/09 - 12:04:02 | 200 |     137.417µs |       127.0.0.1 | GET      \"/api/tags\"",
            "ollama-1  | [GIN] 2026/10/09 - 12:04:12 | 200 |      19.458µs |       127.0.0.1 | HEAD     \"/\"",
            "ollama-1  | [GIN] 2026/10/09 - 12:04:13 | 500 |      19.458µs |       127.0.0.1 | GET      \"/api/tags\"",
            "ollama-1  | [GIN] 2026/10/09 - 12:04:14 | 200 |   2.1s |      172.18.0.1 | POST     \"/api/chat\"",
            "web-1  | 172.18.0.1 - - [09/Oct/2026:12:00:00 +0000] \"GET /api/stats HTTP/1.1\" 200 512",
            "web-1  | 172.18.0.1 - - [09/Oct/2026:12:00:01 +0000] \"GET /healthz HTTP/1.1\" 204 0",
            "app-1  | listening on :3000",
        ]
        let lines = raw.enumerated().map { LogLine.parse($1, id: $0, service: "x") }
        let paths = LogFilter.healthPaths(composeText: """
            healthcheck:
              test: ["CMD", "curl", "-sf", "http://localhost:3000/api/stats"]
            """)
        #expect(paths == ["/api/stats"])
        let filter = LogFilter(healthPaths: paths)
        // A failed check stays, and so do real requests from outside and ordinary lines.
        #expect(filter.apply(lines).map(\.id) == [2, 3, 6])
        #expect(filter.healthCheckCount(in: lines) == 4)
        #expect(LogFilter(hidesHealthChecks: false).apply(lines).count == 7)
    }
}
