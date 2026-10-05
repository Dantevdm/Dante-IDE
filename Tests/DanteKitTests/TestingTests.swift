import Foundation
import Testing
@testable import DanteKit

@Suite struct TestOutputParserTests {
    private func parse(_ text: String) -> [TestResult] {
        var parser = TestOutputParser()
        text.split(separator: "\n", omittingEmptySubsequences: false).forEach { parser.consume(String($0)) }
        return parser.results
    }

    @Test func swiftTestingPassAndFailWithIssue() {
        let results = parse("""
        ◇ Suite Maths started.
        ◇ Test "Adds up wrong" started.
        ✔ Test passes() passed after 0.001 seconds.
        ✘ Test "Adds up wrong" recorded an issue at T.swift:6:41: Expectation failed: (one() → 1) == 2
        ↳ off by one
        ✘ Test "Adds up wrong" failed after 0.002 seconds with 1 issue.
        ✘ Suite Maths failed after 0.001 seconds with 1 issue.
        ✘ Test run with 2 tests in 1 suite failed after 0.001 seconds with 1 issue.
        """)
        #expect(results.map(\.name) == ["passes()", "Adds up wrong"])
        #expect(results[0].status == .passed)
        #expect(results[1].status == .failed)
        #expect(results[1].duration == 0.002)
        #expect(results[1].issues == [.init(message: "Expectation failed: (one() → 1) == 2\noff by one", file: "T.swift", line: 6)])
    }

    @Test func xcTestCases() {
        let results = parse("""
        Test Case '-[MTests.Old testBad]' started.
        /tmp/ft/Tests/MTests/T.swift:10: error: -[MTests.Old testBad] : XCTAssertEqual failed: ("1") is not equal to ("3")
        Test Case '-[MTests.Old testBad]' failed (0.105 seconds).
        Test Case '-[MTests.Old testOK]' passed (0.000 seconds).
        """)
        #expect(results.count == 2)
        #expect(results[0] == TestResult(suite: "Old", name: "testBad", status: .failed, duration: 0.105, issues: [
            .init(message: #"XCTAssertEqual failed: ("1") is not equal to ("3")"#, file: "/tmp/ft/Tests/MTests/T.swift", line: 10),
        ]))
        #expect(results[1].status == .passed)
    }

    @Test func xUnitNamesSwiftTestingSuites() {
        var parser = TestOutputParser()
        parser.consume("✔ Test passes() passed after 0.001 seconds.")
        parser.applyXUnit("""
        <testsuites><testsuite name="TestResults">
          <testcase classname="MTests.Maths" name="passes()" time="0.0001" />
          <testcase classname="MTests.Maths" name="fails()" time="0.0002"><failure message="off by one" /></testcase>
        </testsuite></testsuites>
        """)
        #expect(parser.results.map(\.suite) == ["Maths", "Maths"])
        #expect(parser.results[1].status == .failed)
        #expect(parser.results[1].issues.first?.message == "off by one")
    }

    @Test func otherRunners() {
        let results = parse("""
        test limits::tests::resets ... ok
        test limits::tests::rejects ... FAILED
        --- FAIL: TestLimit (0.01s)
            limits_test.go:12: got 3, want 2
        FAIL	example.com/ledger	0.012s
        tests/test_limits.py::test_resets PASSED                                 [ 50%]
        PASS src/limits.test.ts
          ✓ rejects zero amounts (3 ms)
          ○ skipped one
        """)
        #expect(results.map(\.name) == ["resets", "rejects", "TestLimit", "test_resets", "rejects zero amounts", "skipped one"])
        #expect(results[0].suite == "limits::tests")
        #expect(results[1].status == .failed)
        #expect(results[2].suite == "example.com/ledger")
        #expect(results[2].issues.first?.line == 12)
        #expect(results[3].suite == "tests/test_limits.py")
        #expect(results[4].duration == 0.003)
        #expect(results[5].status == .skipped)
    }
}

@Suite struct DocsAndSpecTests {
    @Test func markdownBlocks() {
        let document = MarkdownDocument("""
        ---
        title: ignored
        ---
        # Transfer limits

        Each account may send **at most** a set amount.

        ## Rules
        - [x] Default limit
        - [ ] Per-account override
          that wraps
        1. First
        2. Second

        | ID | Criterion |
        |----|-----------|
        | AC-1 | Under the limit |

        > A quote

        ```swift
        let x = 1
        ```
        ---
        ## Rules
        """)
        #expect(document.title == "Transfer limits")
        #expect(document.outline.map(\.anchor) == ["transfer-limits", "rules", "rules-1"])
        guard case .list(let checklist, ordered: false) = document.blocks[3] else { Issue.record("no list"); return }
        #expect(checklist.map(\.checked) == [true, false])
        #expect(checklist[1].text == "Per-account override that wraps")
        guard case .list(let numbered, ordered: true) = document.blocks[4] else { Issue.record("no ordered list"); return }
        #expect(numbered.map(\.number) == [1, 2])
        #expect(document.blocks[5] == .table(header: ["ID", "Criterion"], rows: [["AC-1", "Under the limit"]]))
        #expect(document.blocks[6] == .quote("A quote"))
        #expect(document.blocks[7] == .code("let x = 1", language: "swift"))
        #expect(document.blocks[8] == .rule)
    }

    @Test func docLibraryGroups() {
        let library = DocLibrary(paths: [
            "Sources/App.swift", "CLAUDE.md", "README.md", ".dante/phases/test.md", ".dante/phases/build.md",
            ".dante/specs/limits.md", ".dante/decisions/0001-money.md", "docs/setup.md", "Sources/Notes.md",
        ])
        #expect(library.groups.map(\.title) == ["Project", "Specs", "Decisions", "Phases", "Docs", "Elsewhere"])
        #expect(library.groups[0].docs.map(\.path) == ["README.md", "CLAUDE.md"])
        #expect(library.groups[3].docs.map(\.path) == [".dante/phases/build.md", ".dante/phases/test.md"])
        #expect(DocLibrary.Doc(path: "docs/getting-started.md").title == "Getting started")
    }

    @Test func projectInfoReadsChecks() {
        let info = ProjectInfo.parse(projectYAML: """
        name: ledger
        summary: Payments.
        operate:
          checks:
            - { name: api, url: "https://example.com/health" }
            - { url: "ftp://nope" }
        """)
        #expect(info.name == "ledger")
        #expect(info.checks.map(\.name) == ["api"])
    }

    @Test func composeServices() throws {
        let services = try ComposeFile.parse("""
        services:
          worker:
            build: ./src/worker
            depends_on: [nats]
          nats:
            image: nats:2.10-alpine
            ports: ["4222:4222"]
        """)
        #expect(services.map(\.name) == ["nats", "worker"])
        #expect(services[0].ports == ["4222:4222"])
        #expect(services[1].source == "build ./src/worker")
        #expect(services[1].dependsOn == ["nats"])
    }

    @Test func containerStatesFromBothFormats() {
        let lines = #"{"Service":"db","State":"running","Health":"healthy","Status":"Up 3 hours","Publishers":[{"PublishedPort":5432}]}"#
        #expect(ContainerState.parse(lines) == [ContainerState(service: "db", state: "running", health: "healthy", status: "Up 3 hours", ports: [":5432"])])
        #expect(ContainerState.parse("[\(lines)]").count == 1)
    }

    @Test func gitLogParsing() {
        let separator = GitSnapshot.separator
        let commits = GitSnapshot.parseLog("abc\(separator)1700000000\(separator)Add limits\ndef\(separator)bad\(separator)x")
        #expect(commits == [GitSnapshot.Commit(hash: "abc", subject: "Add limits", date: Date(timeIntervalSince1970: 1_700_000_000))])
    }
}

@Suite struct ReleaseDraftTests {
    private func commits(_ subjects: [String]) -> [GitSnapshot.Commit] {
        subjects.enumerated().map { GitSnapshot.Commit(hash: "h\($0.offset)", subject: $0.element, date: .now) }
    }

    @Test func groupsConventionalCommits() {
        let draft = ReleaseDraft(previousTag: "v0.3.2", commits: commits([
            "feat(api): add transfer limits", "fix: seed data duplicates", "Refactor the parser", "chore: bump deps", "Merge branch 'x'",
        ]))
        #expect(draft.version == "v0.4.0")
        #expect(draft.sections.map(\.title) == ["Added", "Changed", "Fixed"])
        #expect(draft.sections[0].entries.map(\.text) == ["Add transfer limits"])
        #expect(draft.skipped == 2)
        #expect(draft.markdown.hasPrefix("## v0.4.0\n\n### Added\n- Add transfer limits"))
    }

    @Test func versionBumps() {
        #expect(ReleaseDraft.next(after: nil, breaking: false, features: true) == "v0.1.0")
        #expect(ReleaseDraft.next(after: "1.2.3", breaking: false, features: false) == "1.2.4")
        #expect(ReleaseDraft.next(after: "v1.2.3", breaking: true, features: false) == "v2.0.0")
        #expect(ReleaseDraft.next(after: "v0.2.3", breaking: true, features: false) == "v0.3.0")
    }

    @Test func ciRuns() {
        let runs = CIRun.parse(#"[{"databaseId":214,"displayTitle":"Add limits","workflowName":"CI","headBranch":"main","status":"completed","conclusion":"failure","createdAt":"2026-10-01T10:00:00Z","url":"https://github.com/o/r/actions/runs/214"}]"#)
        #expect(runs.count == 1)
        #expect(runs[0].isRunning == false)
        #expect(runs[0].succeeded == false)
        #expect(runs[0].created != nil)
    }
}
