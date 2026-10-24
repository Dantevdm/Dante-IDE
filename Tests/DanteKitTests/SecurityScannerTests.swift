import Foundation
import Synchronization
import Testing
@testable import DanteKit

@Suite struct SecurityScannerTests {
    private func rules(_ text: String, _ path: String) -> [String] {
        SecurityScanner.scan(text: text, path: path).map(\.rule)
    }

    @Test func findsSecretsAndMasksThem() {
        let key = "AKIA" + "Q7ZK3M9WX2PLR4TN"
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        let found = SecurityScanner.scan(text: "aws = \"\(key)\"\nlet t = \"\(token)\"\n", path: "src/config.ts")
        #expect(found.map(\.rule) == ["secret.aws", "secret.github"])
        #expect(found[0].evidence.contains("AKIA") && !found[0].evidence.contains(key))
        #expect(found[0].severity == .critical && found[0].line == 1)
    }

    @Test func placeholdersAndExamplesAreNotSecrets() {
        #expect(rules(#"password = "changeme123""#, "app.py").isEmpty)
        #expect(rules(#"api_key: "your_api_key_here""#, "config.yml").isEmpty)
        #expect(rules(#"password = "s3cr3tP4ssw0rd""#, ".env.example").isEmpty)
        #expect(rules(#"password = "s3cr3tP4ssw0rd""#, "settings.py") == ["secret.password"])
        #expect(rules(#"db = "postgres://app:hunter22@db:5432/app""#, "main.go") == ["secret.connection"])
    }

    @Test func findsInjection() {
        #expect(rules("db.query(`SELECT * FROM users WHERE id = ${id}`)", "api/users.ts") == ["js.sql"])
        #expect(rules(#"cur.execute(f"SELECT * FROM users WHERE id = {uid}")"#, "app/db.py") == ["py.sql"])
        #expect(rules(#"rows, err := db.Query(fmt.Sprintf("SELECT * FROM t WHERE id = %s", id))"#, "store.go") == ["go.sql"])
        #expect(rules(#"stmt.executeQuery("SELECT * FROM users WHERE name = '" + name + "'");"#, "Users.java") == ["sql.concat"])
        #expect(rules(#"subprocess.run(cmd, shell=True)"#, "tool.py") == ["py.shell"])
        #expect(rules("el.innerHTML = html", "view.js") == ["js.html"])
        // Parameterised queries are fine.
        #expect(rules("db.query('SELECT * FROM users WHERE id = $1', [id])", "api/users.ts").isEmpty)
        #expect(rules(#"cur.execute("SELECT * FROM users WHERE id = %s", (uid,))"#, "app/db.py").isEmpty)
    }

    @Test func findsWeakEncryption() {
        #expect(rules("const c = crypto.createCipher('aes192', key)", "enc.js") == ["crypto.weak-cipher"])
        #expect(rules("requests.get(url, verify=False)", "client.py") == ["py.tls"])
        #expect(rules(#"const api = "http://api.payments.co.za/v1""#, "client.ts") == ["crypto.http"])
        #expect(rules(#"const api = "http://localhost:3000""#, "client.ts").isEmpty)
        #expect(rules("hash = hashlib.md5(password.encode())", "auth.py").contains("crypto.password-hash"))
    }

    @Test func findsPersonalInformation() {
        #expect(rules("console.log('user', user.idNumber, user.id_number)", "api/users.ts") == ["pii.log"])
        #expect(rules("logger.info(request.json)", "app.py") == ["pii.request-log"])
        // A message that says what happened isn't personal information; logging the value is.
        #expect(rules(#"slog.Info("password changed by its owner", "user_id", user.ID)"#, "api/users.go").isEmpty)
        #expect(rules(#"slog.Info("password changed", "password", body.Password)"#, "api/users.go") == ["pii.log"])
        #expect(rules(#"log.Printf("password: %s", pw)"#, "api/users.go") == ["pii.log"])
        #expect(rules(#"print(f"reset for {user.email}, password={password}")"#, "auth.py") == ["pii.log"])
        #expect(rules("  id_number VARCHAR(13) NOT NULL,", "db/schema.sql") == ["pii.plain-column"])
        #expect(rules("  id_number_encrypted BYTEA,", "db/schema.sql").isEmpty)
        #expect(rules("  password TEXT NOT NULL,", "migrations/001.sql") == ["pii.password-column"])
        #expect(rules("localStorage.setItem('authToken', token)", "web/auth.ts") == ["pii.local-storage"])
    }

    @Test func checksIdentityNumbers() {
        #expect(SecurityScanner.isSouthAfricanID("8001015009087"))
        #expect(!SecurityScanner.isSouthAfricanID("8001015009088"))
        #expect(!SecurityScanner.isSouthAfricanID("8013015009087"))
        let found = SecurityScanner.scan(text: "const customer = { id: \"8001015009087\" }", path: "src/seed.ts")
        #expect(found.map(\.rule) == ["pii.sa-id"])
        #expect(found.first?.severity == .high && found.first?.evidence.contains("8001015009087") == false)
        #expect(SecurityScanner.scan(text: "id: 8001015009087", path: "tests/fixtures/people.yml").first?.severity == .medium)
        #expect(rules("card = '4532 0151 1283 0366'", "billing.py") == ["pii.card"])
        #expect(rules("card = '4242424242424242'", "billing.py").isEmpty)
        #expect(rules("let timestamp = 1700000000000", "a.ts").isEmpty)
        #expect(rules(#"key = "AKIA" + "ABCDEFGHIJKLMNOP""#, "a.ts").isEmpty)
    }

    @Test func checksContainersAndPipelines() {
        let dockerfile = "FROM node:latest AS build\nRUN npm ci\nFROM build\nENV API_TOKEN=abc123\nCMD [\"node\", \"server.js\"]\n"
        let found = rules(dockerfile, "Dockerfile")
        #expect(found.contains("docker.latest") && found.contains("docker.secret") && found.contains("docker.root"))
        #expect(found.filter { $0 == "docker.latest" }.count == 1)
        #expect(!rules("FROM node:22-alpine\nUSER node\n", "Dockerfile").contains("docker.root"))
        let compose = "services:\n  db:\n    image: postgres:16\n    ports:\n      - \"5432:5432\"\n    environment:\n      POSTGRES_PASSWORD: postgres\n"
        #expect(rules(compose, "docker-compose.yml") == ["compose.db-port", "compose.default-password"])
        #expect(rules("    ports:\n      - \"127.0.0.1:5432:5432\"\n", "compose.yaml").isEmpty)
        let workflow = "on: pull_request_target\njobs:\n  b:\n    steps:\n      - uses: actions/checkout@v4\n        with:\n          ref: ${{ github.event.pull_request.head.sha }}\n      - run: echo \"${{ github.event.pull_request.title }}\"\n      - uses: someone/deploy@v1\n"
        let ci = rules(workflow, ".github/workflows/ci.yml")
        #expect(ci.contains("gha.pwn-request") && ci.contains("gha.injection") && ci.contains("gha.unpinned"))
        #expect(rules(#"  cidr_blocks = ["0.0.0.0/0"]"#, "infra/main.tf") == ["tf.open"])
    }

    @Test func testsAreMilderAndCommentsAndSuppressionsAreSkipped() {
        #expect(SecurityScanner.scan(text: "eval(code)", path: "src/run.js").first?.severity == .high)
        #expect(SecurityScanner.scan(text: "eval(code)", path: "src/run.test.js").first?.severity == .medium)
        #expect(rules("// eval(code) would be wrong here", "src/run.js").isEmpty)
        #expect(rules("eval(code) // nosec: input is a constant", "src/run.js").isEmpty)
        #expect(rules("eval(code) # dante:ignore", "src/run.py").isEmpty)
    }

    @Test func checksTheRepository() {
        let files = [".env", ".env.example", "certs/server.key", "web/package.json", "api/package.json", "api/package-lock.json"]
        let git = SecurityScanner.GitView(tracked: [".env", "certs/server.key", "web/package.json"], ignored: [])
        let found = SecurityScanner.scan(files: files, read: { _ in "" }, git: git).map(\.rule)
        #expect(found.contains("repo.env-committed") && found.contains("repo.key-file") && found.contains("deps.unlocked"))
        #expect(!found.contains("repo.env-unignored"))
        let ignored = SecurityScanner.scan(files: [".env"], read: { _ in "" }, git: SecurityScanner.GitView(tracked: [], ignored: [".env"]))
        #expect(ignored.isEmpty)
    }

    @Test func neverPathsAndDataAreNotRead() {
        let read = Mutex<[String]>([])
        _ = SecurityScanner.scan(files: ["data/app.db", "src/a.ts", "private/notes.txt", "node_modules/x/index.js", "dist/app.min.js"],
                                 read: { path in read.withLock { $0.append(path) }; return "" }, never: { $0.hasPrefix("private/") })
        #expect(read.withLock { $0 } == ["src/a.ts"])
    }

    @Test func bundledLibrariesAreNotRead() {
        let files = ["LICENSE", "App/Resources/Lib/three/LICENSE", "App/Resources/Lib/three/three.module.js",
                     "web/public/vendor-ish/chart/LICENSE.md", "web/public/vendor-ish/chart/chart.js",
                     "packages/api/LICENSE", "packages/api/server.ts", "App/main.swift"]
        #expect(SecurityScanner.vendoredFolders(files) == ["App/Resources/Lib/three/", "web/public/vendor-ish/chart/"])
        // Files are read on every core, so the order they're read in varies.
        let read = Mutex<[String]>([])
        _ = SecurityScanner.scan(files: files, read: { path in read.withLock { $0.append(path) }; return "" })
        // A monorepo's own package keeps its licence and is still read.
        #expect(read.withLock { $0 }.sorted() == ["App/main.swift", "LICENSE", "packages/api/LICENSE", "packages/api/server.ts"])
    }

    @Test func idsSurviveMovedLines() {
        let one = SecurityScanner.scan(text: "eval(code)", path: "a.js")
        let two = SecurityScanner.scan(text: "\n\n// moved\neval(code)", path: "a.js")
        #expect(one.first?.id == two.first?.id)
    }
}

@Suite struct SecurityReportTests {
    private func finding(_ rule: String, _ severity: SecurityFinding.Severity, file: String = "a.ts", line: Int = 1, source: String = "Dante",
                         reference: String? = nil) -> SecurityFinding {
        SecurityFinding(rule: rule, category: .code, severity: severity, title: rule, why: "", fix: "", file: file, line: line,
                        evidence: "\(rule)\(line)", reference: reference, source: source)
    }

    @Test func gradesTheProject() {
        #expect(SecurityReport(findings: []).grade == "A")
        #expect(SecurityReport(findings: [finding("a", .medium), finding("b", .low, line: 2)]).score == 94)
        #expect(SecurityReport(findings: [finding("a", .critical)]).grade == "D")
        #expect(SecurityReport(findings: (1...30).map { finding("a", .medium, line: $0) }).score > 40)
    }

    @Test func mergesTheSameProblemFromTwoScanners() {
        let report = SecurityReport(findings: [finding("js.sql", .high, reference: "CWE-89"),
                                               finding("semgrep.sqli", .critical, source: "Semgrep", reference: "CWE-89")])
        #expect(report.findings.count == 1)
        #expect(report.findings[0].severity == .critical)
        #expect(report.findings[0].source == "Dante + Semgrep")
    }

    @Test func saysWhatChanged() {
        let before = SecurityReport(findings: [finding("a", .high), finding("b", .low, line: 2)])
        let after = SecurityReport(findings: [finding("b", .low, line: 2), finding("c", .medium, line: 3)])
        let changes = after.changes(since: before)
        #expect(changes.new.map(\.rule) == ["c"])
        #expect(changes.fixed.map(\.rule) == ["a"])
        #expect(changes.edited.isEmpty)
    }

    @Test func repeatedLinesAreEachAFinding() {
        let text = "fn a() {\n  log.Println(user.passport)\n}\nfn b() {\n  log.Println(user.passport)\n}"
        let found = SecurityScanner.scan(text: text, path: "api/users.go").filter { $0.rule == "pii.log" }
        #expect(found.map(\.line) == [2, 5])
        #expect(Set(found.map(\.id)).count == 2 && Set(found.map(\.lineID)).count == 1)
        // A line added above shifts the repeats; nothing is new or fixed.
        let shifted = SecurityScanner.scan(text: "// header\n" + text, path: "api/users.go")
        #expect(SecurityReport(findings: shifted).changes(since: SecurityReport(findings: found)) == SecurityChanges(new: [], fixed: [], edited: []))
        // A third line edited into the same text is the new one, not the last repeat.
        let more = text + "\nfn c() {\n  log.Println(user.passport)\n}"
        let changes = SecurityReport(findings: SecurityScanner.scan(text: more, path: "api/users.go")).changes(since: SecurityReport(findings: found))
        #expect(changes.new.map(\.line) == [8] && changes.fixed.isEmpty)
        // One edited between two repeats into the same text pairs with neither of them.
        let between = "fn a() {\n  log.Println(user.passport)\n  log.Println(user.passport, 1)\n  log.Println(user.passport)\n}"
        let edited = between.replacingOccurrences(of: "user.passport, 1", with: "user.passport")
        let before = SecurityReport(findings: SecurityScanner.scan(text: between, path: "a.go"))
        let after = SecurityReport(findings: SecurityScanner.scan(text: edited, path: "a.go")).changes(since: before)
        #expect(after.new.isEmpty && after.fixed.isEmpty && after.edited.map(\.after.line) == [3])
    }

    @Test func anEditedLineThatStillHasTheProblemIsNeitherNewNorFixed() {
        func logged(_ text: String, line: Int) -> SecurityFinding {
            SecurityFinding(rule: "pii.log", category: .privacy, severity: .medium, title: "", why: "", fix: "", file: "api/users.go", line: line, evidence: text)
        }
        let before = SecurityReport(findings: [logged("log(user.email)", line: 40), logged("log(user.phone)", line: 90)])
        let after = SecurityReport(findings: [logged("log(user.email, user.dob)", line: 41), logged("log.Println(user.passport)", line: 200)])
        let changes = after.changes(since: before)
        #expect(changes.edited.map(\.before.line) == [40])
        #expect(changes.before(changes.edited[0].after.id)?.evidence == "log(user.email)")
        #expect(changes.new.map(\.line) == [200])
        #expect(changes.fixed.map(\.line) == [90])
    }

    @Test func savesPerProject() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dante-security-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = URL(filePath: "/home/me/app")
        SecurityReport(findings: [finding("a", .high)], files: 3).save(for: root, in: folder)
        #expect(SecurityReport.load(for: root, in: folder)?.findings.first?.rule == "a")
        #expect(SecurityReport.load(for: URL(filePath: "/home/me/other"), in: folder) == nil)
    }

    @Test func ignoresByIdRuleOrPath() {
        let yaml = """
        # accepted
        ignore:
          - id: "js.html:src/view.ts:abc"
            reason: Sanitised
          - rule: gha.unpinned
          - path: examples/
        """
        let ignores = SecurityIgnores.parse(yaml)
        #expect(ignores.entries.count == 3)
        let a = SecurityFinding(id: "js.html:src/view.ts:abc", rule: "js.html", category: .code, severity: .medium, title: "", why: "", fix: "", file: "src/view.ts", line: 3)
        let b = finding("gha.unpinned", .low, file: ".github/workflows/ci.yml")
        let c = finding("js.eval", .high, file: "examples/demo.js")
        let d = finding("js.eval", .high, file: "examplesX/demo.js")
        let split = ignores.apply([a, b, c, d])
        #expect(split.open == [d])
        #expect(ignores.reason(for: a) == .some("Sanitised"))
    }

    @Test func addsIgnoresWithoutLosingComments() {
        let first = SecurityIgnores.adding(.init(id: "x:y:1", reason: "Fine \"here\""), to: nil)
        #expect(SecurityIgnores.parse(first).entries.first?.reason == "Fine \"here\"")
        let second = SecurityIgnores.adding(.init(rule: "gha.unpinned"), to: "# keep me\nignore: []\n")
        #expect(second.hasPrefix("# keep me\n"))
        #expect(SecurityIgnores.parse(second).entries.map(\.rule) == ["gha.unpinned"])
        let third = SecurityIgnores.adding(.init(path: "docs/"), to: second)
        #expect(SecurityIgnores.parse(third).entries.count == 2)
    }

    @Test func aRescanKeepsTheAgentsAuditFindings() {
        func finding(_ rule: String) -> SecurityFinding {
            SecurityFinding(rule: rule, category: .code, severity: .high, title: rule, why: "", fix: "", file: "app.py", line: 1)
        }
        let earlier = SecurityReport(findings: [finding("audit.codex"), finding("py.sql")])
        let fresh = SecurityReport(findings: [finding("py.eval")])
        #expect(ProjectSecurity.keepingAudits(fresh, from: earlier).findings.map(\.rule) == ["py.eval", "audit.codex"])
        #expect(ProjectSecurity.keepingAudits(fresh, from: nil) == fresh)
    }

}

@Suite("Code places")
struct CodePlaceTests {
    @Test func eachLanguageMarksItsTests() {
        let tests = [
            "backend/cmd/server/api/orders_handler_test.go", "internal/store/mock_store.go", "pkg/testdata/users.json",
            "app/tests/test_orders.py", "app/orders_test.py", "conftest.py",
            "web/src/cart.test.tsx", "web/src/cart.spec.ts", "web/src/__tests__/cart.ts", "web/cypress/login.cy.ts",
            "src/test/java/shop/OrderServiceTest.java", "src/main/java/shop/OrderServiceIT.java", "src/OrderSpec.groovy",
            "Tests/ShopTests/CartTests.swift", "Shop.Api.Tests/OrdersControllerTests.cs", "spec/models/order_spec.rb",
            "crates/shop/tests/orders.rs", "lib/cart_test.dart", "src/cart_unittest.cc",
        ]
        for path in tests { #expect(CodePlace.of(path) == .tests, "\(path)") }
        let shipped = [
            "backend/cmd/server/api/orders_handler.go", "src/main/java/shop/Latest.java", "Sources/Shop/PageSpec.swift",
            "src/main/java/shop/AUDIT.java", "web/src/contest.ts", "Sources/Shop/Testing.swift", "requirements.txt",
        ]
        for path in shipped { #expect(CodePlace.of(path) == .shipped, "\(path)") }
        #expect(CodePlace.of("Documentation/Design/screens/support.js") == .docs)
        #expect(CodePlace.of("examples/client.py") == .docs)
        #expect(CodePlace.of("qa/load.go", tests: ["qa/"]) == .tests)
        #expect(CodePlace.of("api/orders_it.go", tests: ["*_it.go"]) == .tests)
    }

    @Test func findingsInTestsAndDocsAreNotGraded() {
        func finding(_ rule: String, _ file: String, _ category: SecurityFinding.Category = .secrets) -> SecurityFinding {
            SecurityFinding(rule: rule, category: category, severity: .high, title: rule, why: "", fix: "", file: file, line: 3, evidence: rule)
        }
        let report = SecurityReport(findings: [
            finding("secret.password", "api/users_test.go"),
            finding("semgrep.eval", "docs/design/support.js", .code),
            finding("secret.aws", "api/users_test.go"),
            finding("secret.password", "api/users.go"),
            finding("deps.GHSA-1", "web/tests/package-lock.json", .dependencies),
        ])
        #expect(Set(report.findings.map(\.rule)) == ["secret.aws", "secret.password", "deps.GHSA-1"])
        #expect(report.findings.allSatisfy { $0.rule != "secret.password" || $0.file == "api/users.go" })
        #expect(report.aside.map(\.file).sorted() == ["api/users_test.go", "docs/design/support.js"])
        let shippedOnly = SecurityReport(findings: report.findings.filter { $0.file == "api/users.go" || $0.rule == "secret.aws" || $0.rule.hasPrefix("deps") })
        #expect(report.score == shippedOnly.score)
    }

    @Test func movingAsideIsNotAFix() {
        let test = SecurityFinding(rule: "secret.password", category: .secrets, severity: .high, title: "", why: "", fix: "",
                                   file: "qa/load.go", line: 4, evidence: "pass = x")
        let before = SecurityReport(findings: [test])
        let after = SecurityReport(findings: [test], testPaths: ["qa/"])
        #expect(before.findings.count == 1 && after.findings.isEmpty && after.aside.count == 1)
        let changes = after.changes(since: before)
        #expect(changes.fixed.isEmpty && changes.new.isEmpty)
    }

    @Test func securityYamlNamesMoreTestPaths() {
        let ignores = SecurityIgnores.parse("tests:\n  - qa/\n  - \"*_it.go\"\n")
        #expect(ignores.tests == ["qa/", "*_it.go"] && ignores.entries.isEmpty)
        #expect(SecurityIgnores.parse("ignore:\n  - rule: x\ntests: e2e-suite/\n").tests == ["e2e-suite/"])
    }

    @Test func savedReportsFromBeforeStillLoad() throws {
        let json = #"{"date":"2026-10-01T10:00:00Z","findings":[{"id":"a","rule":"secret.password","category":"secrets","severity":"high","title":"","why":"","fix":"","file":"api/a_test.go","line":1,"evidence":"","source":"Dante"}],"ignored":[],"scanners":["Dante"],"files":3,"seconds":1}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(SecurityReport.self, from: Data(json.utf8))
        #expect(report.findings.isEmpty && report.aside.count == 1)
    }
}
