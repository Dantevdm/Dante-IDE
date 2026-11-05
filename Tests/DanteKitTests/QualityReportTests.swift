import Foundation
import Testing
@testable import DanteKit

struct QualityReportTests {
    static func tile(_ name: String, _ state: TestMap.State, file: String = "order-service/OrderTest.java") -> TestMap.Tile {
        TestMap.Tile(test: WrittenTest(name: name, file: file, line: 1, category: "Back-end", area: "order-service"),
                     state: state, result: nil, ranAt: nil, ranBy: nil, stale: false, waiting: false)
    }

    static func finding(_ severity: SecurityFinding.Severity, file: String) -> SecurityFinding {
        SecurityFinding(rule: "r.\(severity)", category: .code, severity: severity, title: "t", why: "w", fix: "f", file: file, line: 3)
    }

    static func file(_ path: String, _ state: CodeReview.State) -> CodeReview.FileReview {
        CodeReview.FileReview(path: path, blob: "b", current: [], stale: [], askedOf: [], state: state)
    }

    @Test func gradesTests() {
        #expect(QualityReport.grade(tests: (0..<10).map { Self.tile("t\($0)", .passed) }).rating == .a)
        #expect(QualityReport.grade(tests: [Self.tile("a", .passed), Self.tile("b", .notRun)]).rating == .b)
        #expect(QualityReport.grade(tests: [Self.tile("a", .notRun), Self.tile("b", .notRun), Self.tile("c", .passed)]).rating == .c)
        #expect(QualityReport.grade(tests: [Self.tile("a", .flaky)] + (0..<5).map { Self.tile("p\($0)", .passed) }).rating == .c)
        let one = [Self.tile("a", .failed)] + (0..<19).map { Self.tile("p\($0)", .passed) }
        #expect(QualityReport.grade(tests: one).rating == .d)
        #expect(QualityReport.grade(tests: one).value == "1 failing")
        #expect(QualityReport.grade(tests: [Self.tile("a", .failed), Self.tile("b", .passed)]).rating == .e)
        #expect(QualityReport.grade(tests: []).rating == nil)
    }

    @Test func aRunThatBrokeOutsideTheTestsFails() {
        let passing = (0..<4).map { Self.tile("p\($0)", .passed) }
        let grade = QualityReport.grade(tests: passing, runBroke: true)
        #expect(grade.rating == .d)
        #expect(grade.value == "Run failed")
        #expect(QualityReport.grade(tests: (0..<4).map { Self.tile("n\($0)", .notRun) }, runBroke: true).rating == nil)
    }

    @Test func gradesSecurityByTheWorstFinding() {
        #expect(QualityReport.grade(security: [], scanned: true).rating == .a)
        #expect(QualityReport.grade(security: [Self.finding(.low, file: "a")], scanned: true).rating == .b)
        #expect(QualityReport.grade(security: [Self.finding(.low, file: "a"), Self.finding(.high, file: "b")], scanned: true).rating == .d)
        #expect(QualityReport.grade(security: [Self.finding(.critical, file: "a")], scanned: true).rating == .e)
        #expect(QualityReport.grade(security: [], scanned: false).rating == nil)
    }

    @Test func gradesReviewAndCoverage() {
        let files = (0..<10).map { Self.file("f\($0)", $0 < 9 ? .reviewed : .notReviewed) }
        #expect(QualityReport.grade(review: files, loaded: true).rating == .a)
        #expect(QualityReport.grade(review: files.map { var f = $0; if f.path == "f0" { f.state = .concern }; return f }, loaded: true).rating == .c)
        #expect(QualityReport.grade(coverage: [CoverageReport.Lines(covered: 61, total: 100)], measured: true).rating == .c)
        #expect(QualityReport.grade(coverage: [], measured: false).rating == nil)
    }

    @Test func newCodeAndTheGate() {
        let map = TestMap(groups: [TestMap.Group(name: "order-service", category: "Back-end",
                                                 tiles: [Self.tile("a", .passed), Self.tile("b", .passed, file: "shop-ui/cart.test.ts")])],
                          unmatched: [])
        let security = SecurityReport(findings: [Self.finding(.high, file: "order-service/Refunds.java"), Self.finding(.low, file: "shop-ui/cart.ts")])
        let review = CodeReview.Coverage(files: [Self.file("order-service/Refunds.java", .notReviewed), Self.file("shop-ui/cart.ts", .reviewed)],
                                         required: 1, requests: [])
        let coverage = CoverageReport(files: ["order-service/Refunds.java": .init(covered: 5, total: 10), "shop-ui/cart.ts": .init(covered: 9, total: 10)],
                                      source: "lcov.info", date: nil)
        let report = QualityReport.make(tests: map, newTests: [], security: security, review: review, reviewInUse: true,
                                        coverage: coverage, changed: ["order-service/Refunds.java"], newCodeMeans: "this branch")
        #expect(report.measure(.security)?.all.rating == .d)
        #expect(report.measure(.security)?.new.rating == .d)
        #expect(report.measure(.review)?.new.rating == .e)
        #expect(report.measure(.coverage)?.new.value == "50%")
        #expect(report.measure(.coverage)?.all.value == "70%")
        #expect(!report.gatePassed)
        #expect(report.conditions.map(\.passed) == [true, false, false, false])
        #expect(report.gate == .failed)
        #expect(report.severities.first { $0.severity == .high }?.new == 1)
        #expect(report.testsPassed == 2 && report.testsWithResult == 2)

        let clean = QualityReport.make(tests: map, newTests: [], security: SecurityReport(findings: []), review: review, reviewInUse: false,
                                       coverage: nil, changed: ["shop-ui/cart.ts"], newCodeMeans: "this branch")
        #expect(clean.gatePassed)
        #expect(clean.conditions.count == 2) // review not in use, nothing measured
        #expect(clean.measure(.review)?.all.rating == nil)

        let unknown = QualityReport.make(tests: TestMap(groups: [TestMap.Group(name: "x", category: "Back-end", tiles: [Self.tile("a", .notRun)])], unmatched: []),
                                         newTests: [], security: nil, review: nil, reviewInUse: false, coverage: nil, changed: [], newCodeMeans: "this branch")
        #expect(unknown.gate == .incomplete)
        #expect(unknown.measure(.tests)?.all.rating == nil)
    }
}

struct TidyCommandTests {
    @Test func tidiesAnAgentsCommand() {
        let line = "cd \"/home/me/work/shop/order-service\" && PW=$(docker exec sp-pg printenv POSTGRES_" + "PASSWORD) && TEST_DB=\"postgres://shop:$PW@127.0.0.1:5432/shop\" go test ./internal/api -run EndToEnd -count=1 -v 2>&1 | tail -10 && TEST_DB=x go test ./internal/api -run EndToEnd -count=1 2>&1 | tail -3"
        let tidy = TestCommandLine.tidy(line)
        #expect(tidy.command == "go test ./internal/api -run EndToEnd -count=1 -v")
        #expect(tidy.folder == "order-service")
        #expect(tidy.more == 1)
        #expect(tidy.label == "go test ./internal/api -run EndToEnd -count=1 -v in order-service (+1 more)")
        #expect(!tidy.label.contains("PASSWORD") && !tidy.label.contains("/home/me"))
    }

    @Test func leavesAPlainCommandAlone() {
        #expect(TestCommandLine.tidy("npm test").label == "npm test")
        #expect(TestCommandLine.tidy("cd shop-ui && npm test -- --watch=false").label == "npm test -- --watch=false in shop-ui")
        #expect(TestCommandLine.tidy("make lint").command == "make lint")
    }
}

struct SubtestCountTests {
    @Test func countsTestsWithoutTheirSubtests() {
        let results = [
            TestResult(suite: "shop/orders", name: "TestTotals", status: .passed),
            TestResult(suite: "shop/orders", name: "TestTotals/rounds_down", status: .passed),
            TestResult(suite: "shop/orders", name: "TestTotals/rounds_up", status: .passed),
            TestResult(suite: "shop/orders", name: "a/b reads a path", status: .failed),
        ]
        let run = SavedTestRun(date: .now, by: TestRunner(.you), command: "go test ./...", results: results)
        #expect(run.passed == 1)
        #expect(run.failed == 1)
        #expect(run.tests.map(\.name) == ["TestTotals", "a/b reads a path"])
    }
}
