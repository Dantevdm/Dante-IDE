import Foundation
import Testing
@testable import DanteKit

@Suite("Home pulse")
struct HomePulseTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func theSketchKeepsTheBusiestPartsOfEachLane() {
        let parts = [
            SystemMap.Part(id: "web", name: "web", lane: .clients, kind: .web),
            SystemMap.Part(id: "orders", name: "orders", lane: .api, kind: .routes),
            SystemMap.Part(id: "users", name: "users", lane: .api, kind: .routes),
            SystemMap.Part(id: "health", name: "health", lane: .api, kind: .routes),
            SystemMap.Part(id: "db", name: "db", lane: .data, kind: .database),
        ]
        let links = [
            SystemMap.Link(from: "web", to: "orders", weight: 3), SystemMap.Link(from: "web", to: "users"),
            SystemMap.Link(from: "orders", to: "db", weight: 2), SystemMap.Link(from: "health", to: "health"),
        ]
        let sketch = HomePulse.sketch(SystemMap(parts: parts, links: links), perLane: 2)
        #expect(sketch.lanes.map(\.lane) == [.clients, .api, .data])
        // In the lane's own order, not by weight; health has no links to others and goes.
        #expect(sketch.lanes[1].parts.map(\.id) == ["orders", "users"] && sketch.lanes[1].more == 1)
        #expect(sketch.links.map(\.to) == ["orders", "users", "db"])
    }

    @Test func theCommitGridHasAColumnPerWeek() {
        // Wednesday 2026-10-21.
        let now = Date(timeIntervalSince1970: 1_792_584_000)
        let day: TimeInterval = 86_400
        let dates = [now, now - 3600, now - day, now - 7 * day, now - 200 * day]
        let grid = HomePulse.commitGrid(dates, weeks: 3, now: now, calendar: calendar)
        #expect(grid.count == 3)
        #expect(grid[2] == [0, 1, 2, -1, -1, -1, -1])
        #expect(grid[1] == [0, 0, 1, 0, 0, 0, 0])
        #expect(grid[0].allSatisfy { $0 == 0 })
    }

    @Test func countsPerDayEndToday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_792_584_000)
        let day: TimeInterval = 86_400
        let counts = HomePulse.perDay([now, now - 60, now - day, now - 6 * day, now - 7 * day, now + day], days: 7, now: now, calendar: calendar)
        #expect(counts == [1, 0, 0, 0, 0, 1, 2])
    }

    @Test func languagesAddUpToTheWholeCode() {
        let paths = (0..<6).map { "api/\($0).go" } + ["web/a.ts", "web/b.ts", "web/c.py", "README.md", "web/d.rb"]
        let shares = HomePulse.languages(paths, limit: 2)
        #expect(shares.map(\.name) == ["Go", "TypeScript", "Other"])
        #expect(abs(shares.reduce(0) { $0 + $1.share } - 1) < 0.0001)
        #expect(HomePulse.languages(["README.md"]).isEmpty)
    }
}
