import Foundation
import Testing
@testable import DanteKit

@Suite struct StoryKitTests {
    @Test func writesTheKitOnceAndUpdatesAnOlderHelper() {
        let fresh = StoryKit.files { _ in nil }
        #expect(fresh.map(\.name) == ["playwright.config.ts", "dante-story.ts", ".gitignore"])
        #expect(StoryKit.version(of: StoryKit.helper) == StoryKit.version)

        let old = StoryKit.helper.replacingOccurrences(of: "story kit \(StoryKit.version))", with: "story kit 0)")
        let existing: [String: String] = ["playwright.config.ts": "// mine", "dante-story.ts": old, ".gitignore": "x"]
        #expect(StoryKit.files { existing[$0] }.map(\.name) == ["dante-story.ts"])

        // A helper the person wrote themselves is left alone.
        let own: [String: String] = ["playwright.config.ts": "", "dante-story.ts": "export const mine = 1", ".gitignore": ""]
        #expect(StoryKit.files { own[$0] }.isEmpty)
    }

    @Test func commandRunsInTheFolderAgainstTheApp() {
        let command = StoryKit.command(folder: "web/stories", baseURL: "http://localhost:5173", files: ["checkout.story.ts"])
        #expect(command.label == "Stories · checkout")
        #expect(command.playwrightReports == ["web/stories/" + Playwright.reportFile])
        let script = command.arguments.last ?? ""
        #expect(script.hasPrefix("cd web/stories && export STORY_BASE_URL=http://localhost:5173 && "))
        #expect(script.contains("checkout.story.ts"))
        #expect(!script.contains("npx"))
        #expect(StoryKit.folder(frontend: "") == "stories")
        #expect(StoryKit.installCommand(frontend: "web", tool: "pnpm") == "cd web && pnpm add -D @playwright/test && ./node_modules/.bin/playwright install chromium")
    }
}

@Suite struct StoryReportTests {
    static let record = """
    {"kit":1,"titlePath":["checkout.story.ts","Checkout","Ana pays for her mugs"],"tags":["@happy"],
     "annotations":[{"type":"story","description":"How a shopper pays"}],"viewport":{"width":1280,"height":720},
     "steps":[{"title":"Ana opens her cart","status":"passed","ms":420,"shot":"/home/me/r/step-01.png","url":"http://localhost:5173/cart"},
              {"title":"She pays","status":"failed","ms":7000,"shot":"/home/me/r/step-02.png","error":"\\u001b[31mTimeout\\u001b[39m"}],
     "calls":[{"method":"POST","url":"http://localhost:5173/api/orders?x=1","status":500,"body":"boom","at":1,"step":2}],
     "console":[],"pageErrors":[]}
    """

    static func result(status: TestResult.Status = .failed) -> TestResult {
        var result = TestResult(suite: "web/stories/checkout.story.ts", name: "Ana pays for her mugs", status: status, duration: 7.4,
                                issues: [.init(message: "Error: Timeout 10000ms exceeded")])
        result.attachments = [.init(name: "dante-story", path: "/home/me/r/dante-story.json", contentType: "application/json"),
                              .init(name: "video", path: "/home/me/r/video.webm", contentType: "video/webm")]
        return result
    }

    @Test func readsStepsCallsAndTheFeature() {
        let scenarios = StoryReport.scenarios(from: [Self.result(), TestResult(suite: "web/e2e/a.spec.ts", name: "x", status: .passed)]) { path in
            path.hasSuffix("dante-story.json") ? Data(Self.record.utf8) : nil
        }
        #expect(scenarios.count == 1)
        let scenario = scenarios[0]
        #expect(scenario.feature == "Checkout")
        #expect(scenario.kind == .happy)
        #expect(scenario.about == "How a shopper pays")
        #expect(scenario.viewport == nil)
        #expect(scenario.steps.map(\.title) == ["Ana opens her cart", "She pays"])
        #expect(scenario.steps[1].error == "Timeout")
        #expect(scenario.failedStep?.index == 2)
        #expect(scenario.calls.first?.path == "/api/orders")
        #expect(scenario.video == "/home/me/r/video.webm")
    }

    @Test func withoutARecordItStillCounts() {
        let scenarios = StoryReport.scenarios(from: [Self.result()]) { _ in nil }
        #expect(scenarios.first?.feature == "Checkout")
        #expect(scenarios.first?.steps.isEmpty == true)
        #expect(StoryReport.featureName(file: "web/stories/sign-in.story.ts") == "Sign in")
        #expect(StoryScenario.Kind.from(tags: ["@smoke", "@edge"]) == .invalid)
    }

    @Test func aRunOfOneStoryReplacesOnlyItsScenarios() {
        func scenario(_ file: String, _ title: String, _ status: TestResult.Status) -> StoryScenario {
            StoryScenario(feature: "F", title: title, file: file, kind: .happy, status: status, steps: [], issues: [], calls: [], pageErrors: [], console: [])
        }
        let old = [scenario("a.story.ts", "one", .passed), scenario("a.story.ts", "two", .passed), scenario("b.story.ts", "three", .passed)]
        let merged = StoryReport.merged(old, with: [scenario("b.story.ts", "three", .failed), scenario("a.story.ts", "four", .passed)])
        #expect(merged.map(\.title) == ["one", "two", "four", "three"])
        #expect(merged.last?.status == .failed)
        #expect(StoryReport.merged(old, with: [], files: ["b.story.ts"]).map(\.title) == ["three"])
        #expect(StoryReport.features(merged).map(\.file) == ["a.story.ts", "b.story.ts"])
    }
}

@Suite struct StoryDiagnosisTests {
    static func scenario(error: String, calls: [StoryScenario.Call] = [], pageErrors: [StoryScenario.Line] = []) -> StoryScenario {
        StoryScenario(feature: "Checkout", title: "Ana pays", file: "web/stories/checkout.story.ts", kind: .happy, status: .failed,
                      steps: [.init(title: "Ana opens her cart", passed: true, ms: 300, index: 1),
                              .init(title: "She pays", passed: false, ms: 7000, error: error, index: 2)],
                      issues: [], calls: calls, pageErrors: pageErrors, console: [])
    }

    static var routes: [BliksemRoute] {
        var route = BliksemRoute(method: "POST", path: "/orders")
        route.file = "api/orders.go"
        route.line = 42
        return [route]
    }

    @Test func aServerErrorBlamesTheAppAndNamesTheHandler() throws {
        let call = StoryScenario.Call(method: "POST", url: "http://localhost:5173/api/orders", status: 500, body: "nil pointer", step: 2, faked: false)
        let diagnosis = try #require(StoryDiagnosis.explain(Self.scenario(error: "Timeout 10000ms exceeded", calls: [call]), routes: Self.routes,
                                                            serverLog: ["api-1  | GET /health 200", "api-1  | panic: runtime error: invalid memory address"]))
        #expect(diagnosis.cause == .serverError)
        #expect(diagnosis.blame == .app)
        #expect(diagnosis.headline == "POST /api/orders answered 500 during “She pays”, so the screen couldn’t go on.")
        #expect(diagnosis.handler?.file == "api/orders.go")
        #expect(diagnosis.handler?.line == 42)
        #expect(diagnosis.serverLines == ["api-1  | panic: runtime error: invalid memory address"])
        #expect(diagnosis.step == 2)
    }

    @Test func aFakedFailureIsTheStorysOwnDoing() throws {
        let call = StoryScenario.Call(method: "POST", url: "http://localhost:5173/api/orders", status: 500, step: 2, faked: true)
        let message = "Error: expect(locator).toBeVisible() failed\nLocator: getByText('Something went wrong')\nExpected: visible\nTimeout: 7000ms\nwaiting for getByText('Something went wrong')"
        let diagnosis = try #require(StoryDiagnosis.explain(Self.scenario(error: message, calls: [call]), changed: []))
        #expect(diagnosis.cause != .serverError)
        #expect(diagnosis.headline.contains("getByText('Something went wrong')"))
    }

    @Test func aMissingElementAfterAChangePointsAtTheChange() throws {
        let message = "Error: locator.click: Timeout 10000ms exceeded.\nCall log:\n  - waiting for getByRole('button', { name: 'Pay' })"
        let diagnosis = try #require(StoryDiagnosis.explain(Self.scenario(error: message), changed: ["web/src/pages/Checkout.tsx"]))
        #expect(diagnosis.cause == .missingElement)
        #expect(diagnosis.headline == "In “She pays” the screen never showed getByRole('button', { name: 'Pay' }).")
        #expect(diagnosis.blame == .either)
        #expect(diagnosis.changed == ["web/src/pages/Checkout.tsx"])

        // Never passed: the story may never have matched.
        let fresh = try #require(StoryDiagnosis.explain(Self.scenario(error: message), changed: nil))
        #expect(fresh.blame == .story)
    }

    @Test func wrongTextQuotesBothSides() throws {
        let message = "Error: expect(locator).toHaveText(expected) failed\n\nExpected string: \"R300\"\nReceived string: \"R150\""
        let diagnosis = try #require(StoryDiagnosis.explain(Self.scenario(error: message), changed: []))
        #expect(diagnosis.cause == .wrongText)
        #expect(diagnosis.headline == "In “She pays” the screen showed “R150” where the story expects “R300”.")
        #expect(diagnosis.blame == .app)
    }

    @Test func appDownStrictModeAndPageErrors() throws {
        let down = try #require(StoryDiagnosis.explain(Self.scenario(error: "page.goto: net::ERR_CONNECTION_REFUSED at http://localhost:5173/")))
        #expect(down.cause == .appDown)
        #expect(down.blame == .setup)

        let strict = try #require(StoryDiagnosis.explain(Self.scenario(error: "strict mode violation: getByRole('button', { name: 'Add' }) resolved to 3 elements")))
        #expect(strict.cause == .ambiguous)
        #expect(strict.headline.contains("finds 3 of them"))

        let thrown = StoryScenario.Line(text: "TypeError: cannot read properties of undefined (reading 'total')\n    at Cart (http://localhost:5173/src/pages/Cart.tsx:42:13)", step: 2)
        let page = try #require(StoryDiagnosis.explain(Self.scenario(error: "Timeout", pageErrors: [thrown])))
        #expect(page.cause == .pageError)
        #expect(page.details == ["It came from Cart.tsx:42."])
    }

    @Test func passedHasNoDiagnosisAndRelevantFilesAreTheScreensAndHandlers() {
        var passed = Self.scenario(error: "")
        passed.status = .passed
        #expect(StoryDiagnosis.explain(passed) == nil)
        let changed = ["web/src/pages/Cart.tsx", "web/stories/cart.story.ts", "README.md", "api/orders.go", "api/other.go"]
        #expect(StoryDiagnosis.relevant(changed, frontend: "web", handlers: ["api/orders.go"]) == ["web/src/pages/Cart.tsx", "api/orders.go"])
    }
}

@Suite struct StoryPlanTests {
    static let files: [String: String] = [
        "web/src/pages/Home.tsx": "<Link to=\"/products\">Shop</Link>",
        "web/src/pages/Products.tsx": "fetch('/api/products'); <button>Add to cart</button> <Link to=\"/cart\">Cart</Link>",
        "web/src/pages/Cart.tsx": "<form onSubmit={pay}><input name=\"card\"/><button type=\"submit\">Pay</button></form> navigate('/orders/42')",
        "web/src/pages/orders/[id].tsx": "fetch(`/api/orders/${id}`)",
        "web/src/pages/Login.tsx": "<input type=\"password\"/>",
    ]

    static var map: SystemMap {
        let screens = ["Home": "web/src/pages/Home.tsx", "Products": "web/src/pages/Products.tsx", "Cart": "web/src/pages/Cart.tsx",
                       "orders/:id": "web/src/pages/orders/[id].tsx", "Login": "web/src/pages/Login.tsx"]
        let order = ["Home", "Products", "Cart", "orders/:id", "Login"]
        var parts = [SystemMap.Part(id: "client:web", name: "web", lane: .clients, kind: .web, items: order.map { SystemMap.Item($0, file: screens[$0]) })]
        parts.append(SystemMap.Part(id: "screen:client:web:Products", name: "Products", lane: .clients, kind: .web))
        parts.append(SystemMap.Part(id: "screen:client:web:Cart", name: "Cart", lane: .clients, kind: .web))
        parts.append(SystemMap.Part(id: "route:products", name: "/api/products", lane: .api, kind: .routes, items: [SystemMap.Item("GET /api/products")]))
        parts.append(SystemMap.Part(id: "route:orders", name: "/api/orders", lane: .api, kind: .routes, items: [SystemMap.Item("POST /api/orders")]))
        return SystemMap(parts: parts, links: [.init(from: "screen:client:web:Products", to: "route:products"),
                                               .init(from: "screen:client:web:Cart", to: "route:orders")])
    }

    @Test func ideasCoverSignInTheJourneyAndEachScreen() throws {
        let map = Self.map
        let app = try #require(StoryPlan.webApps(map).first)
        let ideas = StoryPlan.ideas(app: app, map: map, access: nil, read: { Self.files[$0] })
        #expect(ideas.map(\.title) == ["Signing in", "The main journey", "Products", "Cart"])
        let journey = ideas[1]
        #expect(journey.screens == ["Home", "Products", "Cart", "orders/:id"])
        let products = ideas[2]
        #expect(products.scenarios == [.happy, .empty, .error, .slow])
        #expect(products.controls == ["Add to cart"])
        let cart = ideas[3]
        #expect(cart.scenarios == [.happy, .invalid, .error, .slow])
        #expect(cart.file == "cart.story.ts")

        let left = StoryPlan.ideas(app: app, map: map, access: nil, read: { Self.files[$0] }, written: ["Cart", "journey.story.ts"])
        #expect(left.map(\.title) == ["Signing in", "Products"])
    }

    @Test func namesAndTheBrief() {
        #expect(StoryPlan.humanised("orders/:id") == "Order details")
        #expect(StoryPlan.humanised("ProductList") == "Product list")
        #expect(StoryPlan.humanised("check-out") == "Check out")
        #expect(StoryPlan.matches(link: "/orders/42", screen: "orders/:id"))
        #expect(!StoryPlan.matches(link: "/orders", screen: "orders/:id"))
        let idea = StoryIdea(title: "Cart", file: "cart.story.ts", summary: "A person opens Cart.", screens: ["Cart"], sources: ["web/src/pages/Cart.tsx"],
                             calls: ["POST /api/orders"], controls: ["Pay"], scenarios: [.happy, .error])
        let brief = StoryPlan.brief(ideas: [idea], app: "web", folder: "web/stories", baseURL: "http://localhost:5173", access: nil,
                                    existing: [], map: Self.map, runCommand: "cd web/stories && playwright test")
        #expect(brief.contains("web/stories/cart.story.ts"))
        #expect(brief.contains("@happy, @error"))
        #expect(brief.contains("“Pay”"))
        #expect(brief.contains("browser_open http://localhost:5173"))
    }
}
