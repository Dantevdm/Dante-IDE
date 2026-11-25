import Foundation
import Testing
@testable import DanteKit

struct KtorRoutesTests {
    let application = """
    package shop
    import io.ktor.server.routing.*

    fun Application.module() {
        routing {
            get("/health") { call.respondText("ok") }
            authenticate("api-key") {
                route("/api/v1") {
                    get("/ping") { call.respondText("pong") }
                    orderRoutes(service)
                    // get("/commented") {}
                    val note = "get(\\"/not-a-route\\") {}"
                }
            }
            route("/mcp") {
                post { call.respond(handle(call.receiveText())) }
            }
        }
    }
    """
    let orders = """
    package shop.orders
    import io.ktor.server.routing.*

    internal fun Route.orderRoutes(service: OrderService) {
        get("/orders") { call.respond(service.all()) }
        route("/orders/{id}") {
            get { call.respond(service.one(call.parameters["id"]!!)) }
            get("/pdf") { call.respondBytes(service.pdf()) }
        }
        post("/orders") { call.respond(service.create(call.receive())) }
    }
    """

    @Test func readsNestedRoutesAndRouteFunctionsMountedInOtherFiles() {
        let files = ["src/shop/Application.kt": application, "src/shop/orders/OrderRoutes.kt": orders]
        let found = SystemMap.ktorRoutes(files: Array(files.keys), text: { files[$0] ?? "" })
        let app = found["src/shop/Application.kt"]?.map { "\($0.method ?? "") \($0.path)" } ?? []
        #expect(app == ["GET /health", "GET /api/v1/ping", "POST /mcp"])
        let mounted = found["src/shop/orders/OrderRoutes.kt"]?.map { "\($0.method ?? "") \($0.path)" } ?? []
        #expect(mounted == ["GET /api/v1/orders", "GET /api/v1/orders/{id}", "GET /api/v1/orders/{id}/pdf", "POST /api/v1/orders"])
        #expect(found["src/shop/orders/OrderRoutes.kt"]?.first?.line == 5)
    }

    @Test func theMapAndBliksemSeeKtorRoutes() {
        let files = ["src/shop/Application.kt": application, "src/shop/orders/OrderRoutes.kt": orders]
        let paths = Array(files.keys).sorted()
        let map = SystemMap.build(files: paths, read: { files[$0] }, modules: ArchitectureGraph.folders(paths))
        let routes = BliksemRoute.from(map).map(\.id)
        #expect(routes.contains("GET /api/v1/orders/{id}/pdf"))
        #expect(routes.contains("POST /mcp"))
    }

    @Test func aRouteFunctionReadAloneHasNoPrefix() {
        #expect(SystemMap.serverRoutes(file: "Routes.kt", text: orders).first?.path == "/orders")
    }
}

struct BliksemTasksTests {
    @Test func readsTasksAndFillsVariablesFromTheEnvironment() {
        let file = BliksemTasks.parse("""
        headers:
          X-API-Key: ${SHOP_API_KEY}
        tasks:
          - name: Price an order
            path: /api/v1/quotes
            weight: 3
            body: |
              {"items": [{"sku": "A1", "count": 2}]}
          - name: Order as PDF
            path: /api/v1/orders/1/pdf
            headers: { Accept: application/pdf }
          - name: No path
        """)
        #expect(file.tasks.count == 2)
        #expect(file.problems.count == 1)
        #expect(file.tasks[0].method == "POST")
        #expect(file.tasks[0].weight == 3)
        #expect(file.tasks[1].method == "GET")
        #expect(file.tasks[0].id == "task: Price an order")
        #expect(file.missing(env: [:]) == ["SHOP_API_KEY"])
        let key = "k-" + "123"
        let filled = file.filled(env: ["SHOP_API_KEY": key])
        #expect(filled.headers["X-API-Key"] == key)
        #expect(filled.missing(env: [:]).isEmpty)
    }

    @Test func aTaskRequestCarriesItsHeadersAndBody() throws {
        var task = BliksemRoute(method: "POST", path: "/quotes?draft=1")
        task.name = "Quote"
        task.body = "{\"a\":1}"
        task.headers = ["Accept": "application/pdf"]
        let runner = BliksemRunner(base: URL(string: "http://localhost:8080")!, hosts: BrowserHosts(extra: []), headers: ["X-API-Key": "x"])
        let request = try #require(runner.request(task))
        #expect(request.url?.absoluteString == "http://localhost:8080/quotes?draft=1")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "x")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/pdf")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data("{\"a\":1}".utf8))
    }
}

struct ThroughputTests {
    private func second(_ n: Int, _ requests: Int, failures: Int = 0, p95: Double = 0.1, users: Int = 10) -> BliksemSecond {
        BliksemSecond(second: n, requests: requests, failures: failures, p50: 0.05, p95: p95, users: users)
    }

    @Test func theMaximumIsTheBestRateHeldWhileHealthy() {
        let timeline = [second(0, 100), second(1, 200), second(2, 210), second(3, 205), second(4, 900), second(5, 250, failures: 50),
                        second(6, 240, p95: 2)]
        let most = BliksemStats.maxThroughput(timeline)
        // One lucky second (900) doesn't count; seconds 5 and 6 aren't healthy.
        #expect(most?.second == 2)
        #expect(most?.floor == 205)
    }

    @Test func nothingBeforeTheBreakingPointIsTooShort() {
        #expect(BliksemStats.maxThroughput([second(0, 10), second(1, 10)]) == nil)
    }

    @Test func theLimitPlanStepsUpToTheMost() {
        let plan = LoadPlan.limit(most: 60)
        #expect(plan.stages.map(\.to) == [1, 2, 5, 10, 20, 50, 60])
        #expect(plan.duration == 70)
        #expect(plan.users(at: 35) == 10)
    }
}

struct AmperTests {
    @Test func anAmperModuleRunsThroughItsWrapper() {
        let files = ["module.yaml", "kotlin", "src/shop/App.kt", "test/shop/AppTest.kt"]
        let suites = TestSuites.find(files: files, read: { $0 == "module.yaml" ? "product: jvm/app\n" : nil })
        #expect(suites.map(\.tool) == [.amper])
        #expect(suites.first?.runner == "./kotlin")
        #expect(suites.first?.reportFolders == ["build/tasks"])
        let only = suites[0].script(only: [WrittenTest(name: "adds", file: "test/shop/AppTest.kt", line: 3, category: "Unit", area: "shop")])
        #expect(only == "./kotlin test --include-classes '*AppTest'")
    }

    @Test func readsTheJUnitConsoleTree() {
        var parser = TestOutputParser()
        for line in ["╷", "├─ JUnit Jupiter ✔", "│  ├─ MigrationTest ✔", "│  │  ├─ freshDatabase() ✔", "│  │  └─ upgradesInPlace() ✘ expected 2 but was 3"] {
            parser.consume(line)
        }
        #expect(parser.results.map(\.name) == ["freshDatabase", "upgradesInPlace"])
        #expect(parser.results.map(\.suite) == ["MigrationTest", "MigrationTest"])
        #expect(parser.results.last?.status == .failed)
        #expect(parser.results.last?.issues.first?.message == "expected 2 but was 3")
    }
}

struct KtorAccessAndHelpersTests {
    let server = """
    package shop
    import io.ktor.server.auth.*

    fun Application.module() {
        routing {
            route("/api") {
                get("/health") { call.respond("ok") }
                post("/auth/login") { call.respond(auth.login()) }
                authenticate("session") {
                    get("/me") { call.respond(me()) }
                    // a comment with a { brace
                    get("/orders") { call.respond("{") }
                }
                get("/catalogue") { call.respond(list()) }
            }
        }
    }
    """
    let api = """
    export const tokenStore = { set: (t: string) => save(t) }
    async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
      const headers = new Headers(init.headers)
      const res = await fetch(`/api${path}`, { ...init, headers })
      return res.json()
    }
    export const api = {
      login: (email: string) => request<Login>('/auth/login', { method: 'POST' }),
      me: () => request<User>('/me'),
      orders: () => request('/orders'),
    }
    """

    @Test func authenticateBlocksSecureTheirRoutes() {
        let lines = server.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func line(_ text: String) -> Int { (lines.firstIndex { $0.contains(text) } ?? 0) + 1 }
        #expect(SystemMap.ktorAuthenticate(around: line("get(\"/me\")"), in: lines)?.name == "session")
        #expect(SystemMap.ktorAuthenticate(around: line("get(\"/orders\")"), in: lines) != nil)
        #expect(SystemMap.ktorAuthenticate(around: line("get(\"/catalogue\")"), in: lines) == nil)
        #expect(SystemMap.ktorAuthenticate(around: line("get(\"/health\")"), in: lines) == nil)
    }

    @Test func mapFollowsTheFrontendsFetchHelper() {
        let files = ["server/src/main/kotlin/shop/Application.kt", "web/package.json", "web/src/lib/api.ts", "web/src/pages/Orders.tsx"]
        let texts = [files[0]: server, files[1]: #"{"dependencies":{"react":"19"},"scripts":{"dev":"vite"}}"#, files[2]: api,
                     files[3]: "export default function Orders() { return api.orders() }"]
        let map = SystemMap.build(files: files, read: { texts[$0] })
        let called = Set(map.links.filter { $0.from.hasPrefix("client:") || $0.from.hasPrefix("screen:") }.map(\.to))
        #expect(called.contains("route:/api/me"))
        #expect(called.contains("route:/api/orders"))
        #expect(called.contains("route:/api/auth"))
        let me = map.parts.first { $0.id == "route:/api/me" }?.items.first?.access
        #expect(me?.level == .secured)
        let catalogue = map.parts.first { $0.id == "route:/api/catalogue" }?.items.first?.access
        #expect(catalogue?.level == .open)
    }

    @Test func helpersAndBaseURLs() {
        let helpers = APIHelpers.find(in: [api])
        #expect(helpers.functions == ["request": "/api"])
        #expect(helpers.paths(in: api).sorted() == ["/api/auth/login", "/api/me", "/api/orders"])
        let axios = APIHelpers.find(in: ["const http = axios.create({ baseURL: '/api/v1' })"])
        #expect(axios.paths(in: "http.get<Order[]>('/orders'); http.post('/orders', o)") == ["/api/v1/orders", "/api/v1/orders"])
        #expect(APIHelpers.find(in: ["fetch(`/api${p}`)"]).isEmpty)
    }

    @Test func ktorIsARunnableBackend() {
        let files = ["backend/build.gradle.kts", "backend/gradlew", "backend/src/main/kotlin/Application.kt"]
        let apps = RunnableApp.detect(files: files, read: { _ in #"implementation("io.ktor:ktor-server-netty-jvm:3.0")"# })
        #expect(apps.map(\.stack) == ["Ktor"])
        #expect(apps.first?.command == "./gradlew run")
    }
}
