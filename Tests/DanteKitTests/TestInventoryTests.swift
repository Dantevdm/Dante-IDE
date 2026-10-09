import Foundation
import Testing
@testable import DanteKit

struct TestInventoryTests {
    @Test func findsTestsInEachLanguage() {
        let go = """
        package api

        func TestSendEmail(t *testing.T) {}
        func helper(t *testing.T) {}
        func BenchmarkRender(b *testing.B) {}
        """
        #expect(TestInventory.tests(in: go, path: "backend/internal/api/smtp_test.go").map { "\($0.name):\($0.line):\($0.category)" }
                == ["TestSendEmail:3:Unit", "BenchmarkRender:5:Performance"])

        let swift = """
        struct T {
            @Test func adds() {}
            @Test("Display name") func named() async throws {}
            @Test(arguments: [1, 2])
            func many(_ n: Int) {}
        }
        final class Old: XCTestCase {
            func testLegacy() {}
        }
        """
        #expect(TestInventory.tests(in: swift, path: "Tests/KitTests/T.swift").map(\.name) == ["adds", "named", "many", "testLegacy"])

        let ts = """
        describe('cart', () => {
          it('adds an item', () => {})
          test.skip("removes it", async () => {})
        })
        """
        #expect(TestInventory.tests(in: ts, path: "web/src/cart.test.ts").map(\.name) == ["adds an item", "removes it"])
        #expect(TestInventory.tests(in: "def test_login(client):\n    pass\ndef helper(): pass", path: "tests/test_auth.py").map(\.name) == ["test_login"])
        #expect(TestInventory.tests(in: "#[cfg(test)]\nmod tests {\n    #[test]\n    fn parses() {}\n}", path: "src/lib.rs").map(\.name) == ["parses"])
    }

    @Test func categorises() {
        #expect(TestInventory.category(path: "e2e/login.spec.ts", text: "") == "End-to-end")
        #expect(TestInventory.category(path: "AppUITests/LaunchTests.swift", text: "") == "UI")
        #expect(TestInventory.category(path: "tests/integration/test_db.py", text: "") == "Integration")
        #expect(TestInventory.category(path: "internal/db/db_test.go", text: "db, _ := sql.Open(\"sqlite\", \":memory:\")") == "Integration")
        #expect(TestInventory.category(path: "internal/api/helpers_test.go", text: "func TestX(t *testing.T) {}") == "Unit")
        let rules = TestInventory.categoryRules(yaml: """
        test:
          command: go test ./...
          categories:
            Contract: ["backend/internal/api/*whatsapp*"]
            Smoke: scripts/smoke/
        """)
        #expect(rules == [.init(name: "Contract", globs: ["backend/internal/api/*whatsapp*"]), .init(name: "Smoke", globs: ["scripts/smoke/"])])
        #expect(TestInventory.category(path: "backend/internal/api/whatsapp_test.go", text: "", rules: rules) == "Contract")
        #expect(TestInventory.category(path: "scripts/smoke/run_test.go", text: "", rules: rules) == "Smoke")
    }

    @Test func knowsTestFiles() {
        #expect(TestInventory.isTestFile("a/b_test.go") && !TestInventory.isTestFile("a/b.go"))
        #expect(TestInventory.isTestFile("Tests/DanteKitTests/Foo.swift") && !TestInventory.isTestFile("Sources/Kit/Foo.swift"))
        #expect(TestInventory.isTestFile("src/__tests__/x.js") && TestInventory.isTestFile("src/x.spec.tsx") && !TestInventory.isTestFile("src/x.ts"))
        #expect(TestInventory.isTestFile("tests/test_x.py") && !TestInventory.isTestFile("app/x.py"))
    }

    @Test func ordersCategories() {
        let inventory = TestInventory(tests: [
            WrittenTest(name: "a", file: "f", line: 1, category: "Integration", area: ""),
            WrittenTest(name: "b", file: "f", line: 2, category: "Unit", area: ""),
            WrittenTest(name: "c", file: "f", line: 3, category: "Contract", area: ""),
        ], rules: [.init(name: "Contract", globs: ["x"])])
        #expect(inventory.categories == ["Contract", "Unit", "Integration"])
    }
}

struct TestGapsTests {
    @Test func findsWhatNoTestNames() {
        let sources: [(path: String, text: String)] = [
            ("internal/api/smtp.go", "package api\n\nfunc SendEmail() {}\nfunc buildMIME() {}\nfunc main() {}\n"),
            ("internal/db/db.go", "package db\n\ntype Store struct{}\nfunc Open() {}\n"),
        ]
        let gaps = TestGaps.find(sources: sources, testText: "func TestSend(t *testing.T) { SendEmail() }", testFiles: ["internal/api/smtp_test.go"])
        #expect(gaps.sourceFiles == 2 && gaps.declarations == 4)
        #expect(gaps.files.map(\.path) == ["internal/db/db.go", "internal/api/smtp.go"])
        #expect(gaps.files[1].untested == ["buildMIME"] && gaps.files[1].hasTestFile)
        #expect(gaps.files[0].untested == ["Store", "Open"] && !gaps.files[0].hasTestFile)
        #expect(gaps.untestedCount == 3)
        #expect(gaps.prompt().contains("- internal/db/db.go (4 lines): Store, Open"))
    }

    @Test func skipsWhatIsntSource() {
        #expect(TestGaps.isSource("backend/internal/api/handlers.go"))
        #expect(!TestGaps.isSource("node_modules/x/index.js") && !TestGaps.isSource("dist/app.js") && !TestGaps.isSource("a_test.go"))
        #expect(!TestGaps.isSource("README.md") && !TestGaps.isSource("Package.swift"))
    }
}

struct TestHistoryTests {
    func record(_ failed: [String]?, label: String = "go test", broke: Bool = false) -> TestRecord {
        TestRecord(date: .now, label: label, passed: 5, failed: failed?.count ?? 0, skipped: 0, duration: 1, brokeOutsideTests: broke, failedTests: failed)
    }

    @Test func findsFlakyTests() {
        let records = [record(["a/x"]), record([]), record(["a/x", "a/y"]), record(["a/y"]), record(["a/z"], label: "go test · 1 test"), record(nil)]
        let flaky = TestHistory.flaky(records)
        // a/y failed in two of four full runs, a/x in two; a re-run and an old record don't count.
        #expect(flaky.map(\.test) == ["a/x", "a/y"] && flaky[0].runs == 4)
        #expect(TestHistory.flaky([record(["a/x"]), record(["a/x"])]).isEmpty)
    }

    @Test func countsFailingStreaks() {
        let records = [record(["a/x"]), record(["a/x", "a/y"]), record(["a/x", "a/y"])]
        #expect(TestHistory.failingStreaks(records).map { "\($0.test):\($0.runs)" } == ["a/x:3", "a/y:2"])
    }

    @Test func addsVerboseToGoTest() {
        #expect(TestCommand.verbose("cd backend && go test ./...") == "cd backend && go test -v ./...")
        #expect(TestCommand.verbose("go test -v ./...") == "go test -v ./...")
        #expect(TestCommand.verbose("npm test") == "npm test")
    }
}

struct TestGapsRankingTests {
    @Test func ranksLogicBeforeInterface() {
        let sources: [(path: String, text: String)] = [
            ("web/views/emails.js", "function renderEmails() {}\nfunction openEmail() {}\nfunction closeEmail() {}\n"),
            ("internal/api/smtp.go", "func SendEmail() {}\n"),
        ]
        let gaps = TestGaps.find(sources: sources, testText: "", testFiles: [])
        #expect(gaps.files.map(\.path) == ["internal/api/smtp.go", "web/views/emails.js"])
        #expect(gaps.files[1].isInterface && !gaps.files[0].isInterface)
    }
}
