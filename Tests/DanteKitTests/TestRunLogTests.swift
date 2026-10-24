import Foundation
import Testing
@testable import DanteKit

struct TestRunLogTests {
    @Test func testCommandsAreRecognised() {
        for command in ["swift test", "swift test --filter Jobs 2>&1 | tail -5", "cd api && go test ./...", "CI=1 npm test", "npx vitest run",
                        "python3 -m pytest -q tests/test_limits.py", "./gradlew test", "./mvnw -B test", "time cargo test", "bundle exec rspec"] {
            #expect(TestCommandLine.runsTests(command), "\(command)")
        }
        for command in ["swift build", "git commit -m 'swift test passes'", "echo go test", "npm install", "ls tests", "cat test.swift", "grep -rn \"swift test\" ."] {
            #expect(!TestCommandLine.runsTests(command), "\(command)")
        }
        #expect(TestCommandLine.runsTests("make check", projectCommand: "make check"))
    }

    @Test func narrowedRuns() {
        #expect(TestCommandLine.isNarrowed("swift test --filter JobTests"))
        #expect(TestCommandLine.isNarrowed("go test -run TestLimit ./..."))
        #expect(TestCommandLine.isNarrowed("pytest tests/test_limits.py"))
        #expect(TestCommandLine.isNarrowed("npx vitest src/limits.test.ts"))
        #expect(!TestCommandLine.isNarrowed("swift test"))
        #expect(!TestCommandLine.isNarrowed("npm test"))
    }

    @Test func anAgentsRunIsReadFromItsOutput() throws {
        let output = """
        Building for debugging...
        ✔ Test passes() passed after 0.001 seconds.
        ✘ Test "Adds up" recorded an issue at Sums.swift:6:41: Expectation failed: 2 == 3
        ✘ Test "Adds up" failed after 0.002 seconds with 1 issue.
        ✘ Test run with 2 tests in 1 suite failed after 0.010 seconds with 1 issue.
        """
        let run = try #require(SavedTestRun.reading(command: "swift test", output: output, failed: true, by: TestRunner(.agent, name: "Claude")))
        #expect(run.passed == 1 && run.failed == 1)
        #expect(!run.brokeOutsideTests && !run.narrowed)
        #expect(run.duration == 0.010)
        #expect(run.failures.first?.issues.first?.line == 6)
        #expect(run.by.label == "Claude")

        let broken = try #require(SavedTestRun.reading(command: "swift test", output: "error: cannot find 'x' in scope\nerror: fatalError", failed: true, by: .you))
        #expect(broken.brokeOutsideTests)
        #expect(broken.tail.count == 2)
        #expect(SavedTestRun.reading(command: "swift test --list-tests", output: "JobTests/a\nJobTests/b", failed: false, by: .you) == nil)
    }

    @Test func runsAreKeptPerProjectNewestLast() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dante-runlog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = try #require(UserDefaults(suiteName: "dante-runlog-\(UUID().uuidString)"))
        let root = URL(filePath: "/tmp/shop")
        for n in 0..<(TestRunLog.limit + 3) {
            TestRunLog.append(SavedTestRun(date: Date(timeIntervalSince1970: Double(n)), by: .you, command: "swift test",
                                           results: [TestResult(suite: "S", name: "t\(n)", status: .passed)]), for: root, in: folder, defaults: defaults)
        }
        let runs = TestRunLog.load(for: root, in: folder)
        #expect(runs.count == TestRunLog.limit)
        #expect(runs.last?.results.first?.name == "t\(TestRunLog.limit + 2)")
        #expect(TestRecord.load(for: root, defaults: defaults).count == TestRunLog.limit + 3)
        #expect(TestRunLog.load(for: URL(filePath: "/tmp/other"), in: folder).isEmpty)
    }
}

struct TestMapTests {
    static let inventory = TestInventory(tests: [
        WrittenTest(name: "passes", file: "Tests/A/SumTests.swift", line: 3, category: "Unit", area: "Tests/A"),
        WrittenTest(name: "breaks", file: "Tests/A/SumTests.swift", line: 9, category: "Unit", area: "Tests/A"),
        WrittenTest(name: "wobbles", file: "Tests/B/NetTests.swift", line: 4, category: "Integration", area: "Tests/B"),
        WrittenTest(name: "neverRun", file: "Tests/B/NetTests.swift", line: 12, category: "Integration", area: "Tests/B"),
    ])

    static func run(_ day: Double, _ results: [(String, TestResult.Status)], by runner: TestRunner = .you) -> SavedTestRun {
        SavedTestRun(date: Date(timeIntervalSince1970: day * 86_400), by: runner, command: "swift test",
                     results: results.map { TestResult(suite: "", name: $0.0 + "()", status: $0.1) })
    }

    @Test func tilesTakeTheirLastResult() {
        let runs = [
            Self.run(1, [("passes", .passed), ("breaks", .passed), ("wobbles", .failed)]),
            Self.run(2, [("passes", .passed), ("breaks", .failed), ("wobbles", .passed)], by: TestRunner(.agent, name: "Codex")),
        ]
        let map = TestMap.build(inventory: Self.inventory, runs: runs, modified: ["Tests/A/SumTests.swift": Date(timeIntervalSince1970: 3 * 86_400)])
        let state = Dictionary(uniqueKeysWithValues: map.tiles.map { ($0.test.name, $0.state) })
        #expect(state == ["passes": .passed, "breaks": .failed, "wobbles": .flaky, "neverRun": .notRun])
        #expect(map.groups.first?.name == "Tests/A")
        #expect(map.tiles.first { $0.test.name == "breaks" }?.ranBy?.label == "Codex")
        #expect(map.staleCount == 2)
        // A flaky test that failed last is still failing, marked flaky.
        let failedLast = TestMap.build(inventory: Self.inventory, runs: runs + [Self.run(3, [("wobbles", .failed)])])
        let wobbles = failedLast.tiles.first { $0.test.name == "wobbles" }
        #expect(wobbles?.state == .failed && wobbles?.flaky == true)
        #expect(failedLast.flakyKeys == ["wobbles"])
        #expect(map.tiles.first { $0.test.name == "wobbles" }?.stale == false)
    }

    @Test func aLiveRunFillsInAsItGoes() {
        let runs = [Self.run(1, [("passes", .passed), ("breaks", .failed)])]
        let map = TestMap.build(inventory: Self.inventory, runs: runs, live: [TestResult(suite: "", name: "breaks()", status: .passed)], liveCoversAll: true)
        let tiles = Dictionary(uniqueKeysWithValues: map.tiles.map { ($0.test.name, $0) })
        #expect(tiles["breaks"]?.state == .passed && tiles["breaks"]?.waiting == false)
        #expect(tiles["passes"]?.waiting == true)
        #expect(tiles["neverRun"]?.waiting == true && tiles["neverRun"]?.state == .notRun)
    }

    @Test func aBreakIsNotFlaky() {
        let runs = [Self.run(1, [("breaks", .passed)]), Self.run(2, [("breaks", .passed)]), Self.run(3, [("breaks", .failed)])]
        #expect(TestMap.flakyKeys(runs).isEmpty)
        #expect(TestMap.flakyKeys(runs + [Self.run(4, [("breaks", .passed)])]) == ["breaks"])
        #expect(TestMap.key("`adds up`") == "adds up")
        #expect(TestMap.key("TestLimit/zero") == "TestLimit")
    }
}
