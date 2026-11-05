import Foundation
import Testing
@testable import DanteKit

struct PlaywrightTests {
    @Test func readsTheTestDir() {
        #expect(Playwright.testDir(inConfig: "export default defineConfig({ testDir: './e2e/', retries: 1 })") == "e2e")
        #expect(Playwright.testDir(inConfig: "module.exports = { testDir: \"tests/ui\" }") == "tests/ui")
        #expect(Playwright.testDir(inConfig: "export default defineConfig({})") == "")
    }

    @Test func findsASuiteBesideTheUnitTests() {
        let files = ["shop-ui/package.json", "shop-ui/package-lock.json", "shop-ui/playwright.config.ts",
                     "shop-ui/src/cart.test.ts", "shop-ui/e2e/checkout.spec.ts"]
        let read: (String) -> String? = { path in
            switch path {
            case "shop-ui/package.json": #"{"scripts": {"test": "vitest"}, "devDependencies": {"react": "1", "@playwright/test": "1"}}"#
            case "shop-ui/playwright.config.ts": "export default defineConfig({ testDir: './e2e' })"
            default: nil
            }
        }
        let suites = TestSuites.find(files: files, read: read)
        #expect(suites.map(\.tool) == [.playwright, .node])
        #expect(TestSuites.suite(for: "shop-ui/e2e/checkout.spec.ts", in: suites)?.tool == .playwright)
        #expect(TestSuites.suite(for: "shop-ui/src/cart.test.ts", in: suites)?.tool == .node)
        let playwright = suites[0]
        #expect(playwright.scope == "shop-ui/e2e")
        let command = TestSuites.command([playwright], only: [WrittenTest(name: "pays by card", file: "shop-ui/e2e/checkout.spec.ts", line: 4, category: "End-to-end", area: "shop-ui")])
        let script = command?.arguments.last ?? ""
        #expect(script.contains("node_modules/.bin/playwright"))
        #expect(!script.contains("npx"))
        #expect(script.contains("--reporter=list,json"))
        #expect(script.contains(" e2e/checkout.spec.ts"))
        #expect(script.contains("--grep 'pays by card'"))
        #expect(command?.playwrightReports == ["shop-ui/test-results/.dante-playwright.json"])
    }

    @Test func readsListLines() {
        var parser = TestOutputParser()
        parser.consume("  ✓  1 [chromium] › e2e/checkout.spec.ts:4:7 › Checkout › pays by card (1.2s)")
        parser.consume("  ✘  2 [firefox] › e2e/checkout.spec.ts:4:7 › Checkout › pays by card (30.0s)")
        parser.consume("  ✓  3 [webkit] › e2e/checkout.spec.ts:4:7 › Checkout › pays by card (900ms)")
        parser.consume("  -  4 [chromium] › e2e/cart.spec.ts:9:3 › empties the cart")
        #expect(parser.results.count == 2)
        #expect(parser.results[0].name == "pays by card" && parser.results[0].status == .failed)
        #expect(parser.results[1].status == .skipped)
    }

    static let report = """
    {"config": {"rootDir": "/home/me/shop/shop-ui/e2e"},
     "suites": [{"title": "checkout.spec.ts", "file": "checkout.spec.ts", "specs": [], "suites": [
       {"title": "Checkout", "file": "checkout.spec.ts", "specs": [
         {"title": "pays by card", "file": "checkout.spec.ts", "line": 4, "tests": [
           {"projectName": "chromium", "status": "expected", "results": [{"status": "passed", "duration": 1200, "attachments": []}]},
           {"projectName": "firefox", "status": "unexpected", "results": [{"status": "failed", "duration": 30000, "retry": 0,
             "errors": [{"message": "\\u001b[31mError: expect(locator).toBeVisible()\\u001b[39m\\nLocator: getByText('Paid')",
                         "location": {"file": "/home/me/shop/shop-ui/e2e/checkout.spec.ts", "line": 12}}],
             "attachments": [{"name": "screenshot", "contentType": "image/png", "path": "/home/me/shop/shop-ui/test-results/pays/test-failed-1.png"},
                             {"name": "video", "contentType": "video/webm", "path": "/home/me/shop/shop-ui/test-results/pays/video.webm"},
                             {"name": "trace", "contentType": "application/zip", "path": "/home/me/shop/shop-ui/test-results/pays/trace.zip"}]}]}]},
         {"title": "keeps the basket", "file": "checkout.spec.ts", "line": 20, "tests": [
           {"projectName": "chromium", "status": "flaky", "results": [
             {"status": "failed", "retry": 0, "duration": 500, "errors": [{"message": "Timeout 5000ms exceeded."}]},
             {"status": "passed", "retry": 1, "duration": 700}]}]}]}]}]}
    """

    @Test func readsTheReport() throws {
        let results = PlaywrightReport.results(Data(Self.report.utf8), projectRoot: "/home/me/shop", suiteFolder: "shop-ui")
        #expect(results.map(\.name) == ["pays by card", "keeps the basket"])
        let paid = try #require(results.first)
        #expect(paid.suite == "shop-ui/e2e/checkout.spec.ts")
        #expect(paid.status == .failed)
        #expect(paid.issues.first?.message.hasPrefix("[firefox] Error: expect(locator).toBeVisible()") == true)
        #expect(paid.issues.first?.line == 12)
        #expect(paid.attachments?.map(\.kind) == [.screenshot, .video, .trace])
        #expect(paid.attachments?.first?.project == "firefox")
        #expect(paid.duration == 30)
        let flaky = results[1]
        #expect(flaky.status == .passed)
        #expect(flaky.issues.first?.message.contains("flaky") == true)
    }

    @Test func theReportReplacesTheListLines() {
        var parser = TestOutputParser()
        parser.consume("  ✘  2 [firefox] › checkout.spec.ts:4:7 › Checkout › pays by card (30.0s)")
        parser.applyPlaywright(PlaywrightReport.results(Data(Self.report.utf8), projectRoot: "/home/me/shop", suiteFolder: "shop-ui"))
        #expect(parser.results.count == 2)
        #expect(parser.results.first { $0.name == "pays by card" }?.attachments?.count == 3)
    }

    @Test func agentsRunsCount() {
        #expect(TestCommandLine.runsTests("npx playwright test e2e/checkout.spec.ts"))
        #expect(TestCommandLine.runsTests("pnpm exec playwright test"))
    }
}
