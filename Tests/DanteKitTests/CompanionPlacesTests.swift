import Foundation
import Testing
@testable import DanteKit

struct CompanionPlacesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func input() -> CompanionPlaces.Input {
        let failing = TestResult(suite: "OrdersTests", name: "totalIncludesTax", status: .failed,
                                 issues: [.init(message: "expected 110, got 100", file: "/home/me/shop/OrdersTests.swift", line: 12)])
        let run = SavedTestRun(date: now.addingTimeInterval(-3600), by: .you, command: "swift test",
                               results: [failing, TestResult(suite: "OrdersTests", name: "empty", status: .passed, duration: 2.5)], duration: 4)
        let finding = SecurityFinding(rule: "sql.concat", category: .code, severity: .high, title: "SQL built from input",
                                      why: "Input reaches a query.", fix: "Use a parameter.", file: "api/orders.go", line: 40)
        return .init(now: now, project: "shop",
                     commits: [.init(hash: "abcdef1234", author: "Ana", date: now.addingTimeInterval(-7200), subject: "Orders: tax")],
                     testRuns: [run], security: SecurityReport(date: now, findings: [finding]),
                     pipelines: [.init(id: "p", project: "shop", name: "deploy", branch: "main", status: .bad, state: "Failed")],
                     jobs: [AgentJob(date: now.addingTimeInterval(-600), kind: "review", provider: .claude, model: "claude-opus-5-5", project: "shop", title: "Review the orders change")])
    }

    @Test func homeSaysHowItStands() {
        let home = CompanionPlaces.make(.home, input())
        #expect(home.headline.hasPrefix("1 test failing"))
        #expect(home.status == .bad)
        #expect(home.tiles.map(\.label) == ["Tests", "Security", "Changes", "Pipelines", "Agents"])
        #expect(home.tiles.first?.opens == .tests)
        #expect(home.sections.first?.title == "Recent changes")
    }

    @Test func testsListFailuresWithTheirMessage() {
        let tests = CompanionPlaces.make(.tests, input())
        let failing = tests.sections.first { $0.title == "Failing" }
        #expect(failing?.rows.first?.detail == "OrdersTests · OrdersTests.swift:12")
        #expect(failing?.rows.first?.expanded == "expected 110, got 100")
        #expect(tests.sections.contains { $0.title == "Slowest" })
    }

    @Test func securityGroupsBySeverityWithTheFix() {
        let security = CompanionPlaces.make(.security, input())
        #expect(security.sections.first?.title == "High")
        #expect(security.sections.first?.rows.first?.detail == "api/orders.go:40")
        #expect(security.sections.first?.rows.first?.expanded?.contains("Fix: Use a parameter.") == true)
    }

    @Test func nothingKeptSaysSo() {
        let empty = CompanionPlaces.Input(now: now, project: "shop")
        #expect(CompanionPlaces.make(.tests, empty).headline.hasPrefix("No test runs"))
        #expect(CompanionPlaces.make(.security, empty).tiles.isEmpty)
        #expect(CompanionPlaces.make(.ship, empty).headline == "No changes this week.")
    }
}
