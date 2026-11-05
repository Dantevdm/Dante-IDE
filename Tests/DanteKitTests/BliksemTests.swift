import Foundation
import Testing
@testable import DanteKit

struct BliksemRouteTests {
    @Test func readsTheMapsRouteText() {
        #expect(BliksemRoute.parse("GET /orders/{id}") == BliksemRoute(method: "GET", path: "/orders/{id}"))
        #expect(BliksemRoute.parse("post /orders") == BliksemRoute(method: "POST", path: "/orders"))
        #expect(BliksemRoute.parse("/health")?.method == "GET")
        #expect(BliksemRoute.parse("ALL /hooks")?.method == "GET")
        #expect(BliksemRoute.parse("orders") == nil)
        #expect(BliksemRoute.parse("FETCH /x") == nil)
    }

    @Test func fillsEveryParameterStyle() {
        #expect(BliksemRoute(method: "GET", path: "/orders/{id}").samplePath == "/orders/1")
        #expect(BliksemRoute(method: "GET", path: "/orders/:orderId/items").samplePath == "/orders/1/items")
        #expect(BliksemRoute(method: "GET", path: "/people/<int:person_id>").samplePath == "/people/1")
        #expect(BliksemRoute(method: "GET", path: "/blog/[slug]").samplePath == "/blog/sample")
        #expect(BliksemRoute(method: "GET", path: "/docs/[...rest]").parameters == ["rest"])
        #expect(BliksemRoute(method: "GET", path: "/a/{id:int}").parameters == ["id"])
        #expect(BliksemRoute(method: "GET", path: "/things/{uuid}").samplePath == "/things/00000000-0000-4000-8000-000000000001")
        #expect(BliksemRoute(method: "GET", path: "/a/b").parameters.isEmpty)
    }

    @Test func takesRoutesFromTheMapsApiLane() {
        var group = SystemMap.Part(id: "route:/orders", name: "/orders", lane: .api, kind: .routes, detail: "", items: [
            .init("GET /orders", file: "a.go", line: 1), .init("POST /orders", file: "a.go", line: 2),
            .init("GET /orders", file: "b.go", line: 3), .init("GET /files/*", file: "a.go", line: 4),
        ])
        group.items.append(.init("GET /orders/{id}", file: "a.go", line: 5))
        let other = SystemMap.Part(id: "db", name: "db", lane: .data, kind: .database, detail: "", items: [.init("GET /nope")])
        let map = SystemMap(parts: [group, other], links: [])
        #expect(BliksemRoute.from(map).map(\.id) == ["GET /orders", "GET /orders/{id}", "POST /orders"])
    }
}

struct BliksemTargetTests {
    @Test func onlyLocalAndTestHosts() throws {
        let hosts = BrowserHosts(extra: ["staging.shop.example"])
        #expect(try BliksemTarget.check("localhost:8080", hosts: hosts).get().absoluteString == "http://localhost:8080")
        #expect((try? BliksemTarget.check("http://127.0.0.1:3000/api", hosts: hosts).get()) != nil)
        #expect((try? BliksemTarget.check("https://api.staging.shop.example", hosts: hosts).get()) != nil)
        #expect(BliksemTarget.check("https://shop.example", hosts: hosts) == .failure(.notLocal("shop.example")))
        #expect(BliksemTarget.check("ftp://localhost", hosts: hosts) == .failure(.notHTTP))
        #expect(BliksemTarget.check("", hosts: hosts) == .failure(.notAURL))
    }

    @Test func keepsTheBasePath() {
        let base = URL(string: "http://localhost:8080/api/")!
        #expect(BliksemTarget.url(base, path: "/orders/1", query: "q=a")?.absoluteString == "http://localhost:8080/api/orders/1?q=a")
        #expect(BliksemTarget.url(URL(string: "http://localhost:8080")!, path: "/x")?.absoluteString == "http://localhost:8080/x")
    }
}

struct LoadPlanTests {
    @Test func standardPlanRampsSpikesAndCools() {
        let plan = LoadPlan.standard(peak: 50, seconds: 60)
        #expect(plan.stages.map(\.name) == ["Warm-up", "Ramp", "Spike", "Cool-down"])
        #expect(plan.duration == 60)
        #expect(plan.peak == 100)
        #expect(plan.users(at: 0) == 1)
        #expect(plan.users(at: 9 + 27 - 0.01) == 50)
        #expect(plan.users(at: 40) == 100)
        #expect(plan.users(at: 61) == 0)
        #expect(LoadPlan.standard(peak: 500, seconds: 60).peak == Bliksem.maxUsers)
    }
}

struct BliksemStatsTests {
    func sample(_ start: Double, _ duration: Double, _ status: Int? = 200, route: String = "GET /a") -> BliksemSample {
        BliksemSample(route: route, start: start, duration: duration, status: status)
    }

    @Test func percentilesByNearestRank() {
        let values = (1...100).map(Double.init)
        #expect(BliksemStats.percentile(values, 50) == 50)
        #expect(BliksemStats.percentile(values, 95) == 95)
        #expect(BliksemStats.percentile(values, 99) == 99)
        #expect(BliksemStats.percentile([], 95) == 0)
    }

    @Test func notFoundIsntAFailureButOverloadedIs() {
        #expect(!sample(0, 0.1, 404).failed)
        #expect(sample(0, 0.1, 429).failed)
        #expect(sample(0, 0.1, 503).failed)
        #expect(sample(0, 0.1, nil).failed)
    }

    @Test func bucketsBySecondAndFindsTheBreakingPoint() {
        var samples: [BliksemSample] = []
        for second in 0..<6 {
            for i in 0..<10 {
                let slow = second >= 3
                samples.append(sample(Double(second) + Double(i) / 10, slow ? 1.5 : 0.05))
            }
        }
        let timeline = BliksemStats.seconds(samples) { $0 * 10 }
        #expect(timeline.count == 6)
        #expect(timeline[0].requests == 10)
        #expect(timeline[0].p95 == 0.05)
        let point = BliksemStats.breakingPoint(timeline)
        #expect(point?.second == 3)
        #expect(point?.users == 30)
        #expect(point?.reason == "95% took up to 1.5 s")
    }

    @Test func oneBadSecondIsAHiccup() {
        var samples: [BliksemSample] = []
        for second in 0..<4 {
            for i in 0..<10 { samples.append(sample(Double(second) + Double(i) / 10, 0.05, second == 1 && i < 3 ? 500 : 200)) }
        }
        #expect(BliksemStats.breakingPoint(BliksemStats.seconds(samples) { _ in 5 }) == nil)
    }

    @Test func routesWorstFirstWithTheirUsualAnswer() {
        let samples = [sample(0, 0.1, 200, route: "GET /a"), sample(0, 0.2, 500, route: "GET /b"), sample(0, 0.1, 500, route: "GET /b"),
                       sample(0, 0.1, 404, route: "GET /c"), sample(0, 0.1, 404, route: "GET /c"), sample(0, 0.1, 200, route: "GET /c")]
        let routes = BliksemStats.routes(samples)
        #expect(routes.first?.route == "GET /b")
        #expect(routes.first?.usual == "500")
        #expect(routes.first { $0.route == "GET /c" }?.usual == "404")
    }

    @Test func summarySaysWhetherItHeld() {
        let held = LoadSummary.make([sample(0, 0.1), sample(1, 0.2)], timeline: [], duration: 2)
        #expect(held.verdict.hasPrefix("It held up to"))
        #expect(LoadSummary.make([], timeline: [], duration: 2).verdict.contains("is the app running"))
    }
}

struct FuzzTests {
    let route = BliksemRoute(method: "GET", path: "/orders/{id}")

    @Test func casesForPathQueryAndBody() {
        let post = BliksemRoute(method: "POST", path: "/orders")
        let reads = Fuzz.cases(for: [route, post], includeWrites: false)
        #expect(reads.allSatisfy { $0.route == route })
        #expect(reads.contains { $0.place == .path } && reads.contains { $0.place == .query })
        let writes = Fuzz.cases(for: [route, post], includeWrites: true)
        #expect(writes.contains { $0.route == post && $0.place == .body })
        #expect(!writes.contains { $0.route == post && $0.place == .query })
        let sqlOnly = Fuzz.cases(for: [route], includeWrites: false, kinds: [.sql])
        #expect(sqlOnly.allSatisfy { $0.payload.kind == .sql })
    }

    @Test func probesNeverChangeData() {
        for payload in Fuzz.payloads + Fuzz.bodies {
            let upper = payload.value.uppercased()
            for word in ["DROP ", "DELETE ", "UPDATE ", "INSERT ", "TRUNCATE ", "SHUTDOWN"] { #expect(!upper.contains(word), "\(payload.name)") }
        }
    }

    @Test func buildsTheRequest() throws {
        let base = URL(string: "http://localhost:8080")!
        let sql = FuzzCase(route: route, place: .path, payload: .init(.sql, "or true", "' OR '1'='1"))
        let request = try #require(Fuzz.request(sql, base: base, timeout: 5))
        #expect(request.url?.absoluteString == "http://localhost:8080/orders/%27%20OR%20%271%27%3D%271")
        let query = FuzzCase(route: route, place: .query, payload: .init(.types, "negative", "-1"))
        #expect(Fuzz.request(query, base: base, timeout: 5)?.url?.query()?.hasPrefix("id=-1&q=-1") == true)
        let body = FuzzCase(route: BliksemRoute(method: "POST", path: "/orders"), place: .body, payload: .init(.json, "cut off", "{\"a\":"))
        let posted = try #require(Fuzz.request(body, base: base, timeout: 5))
        #expect(posted.httpMethod == "POST")
        #expect(posted.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(posted.httpBody == Data("{\"a\":".utf8))
    }

    func classify(_ kind: FuzzPayload.Kind = .sql, status: Int?, error: String? = nil, body: String = "", type: String? = nil, duration: Double = 0.1, baseline: Int? = 200) -> FuzzFinding? {
        let fuzz = FuzzCase(route: route, place: .query, payload: Fuzz.payloads.first { $0.kind == kind }!)
        return Fuzz.classify(fuzz, status: status, error: error, contentType: type, body: body, duration: duration, timeout: 8, baselineStatus: baseline)
    }

    @Test func classifiesWhatResponsesGiveAway() {
        #expect(classify(status: 400, body: "{\"error\":\"bad id\"}") == nil)
        #expect(classify(status: 200) == nil)
        #expect(classify(status: 500, body: "pq: syntax error at or near \"OR\"")?.problem == .sqlError)
        #expect(classify(status: 500, body: "pq: syntax error at or near \"OR\"")?.severity == .critical)
        #expect(classify(.types, status: 500, body: "Traceback (most recent call last):\n  File \"/app/main.py\", line 3")?.problem == .stackTrace)
        let python = "Internal error\nTraceback (most recent call last):\n  File \"/app/main.py\", line 3, in order\n    n = int(id)\nValueError: invalid literal for int() with base 10: 'x'\n"
        #expect(classify(.types, status: 500, body: python)?.evidence == "ValueError: invalid literal for int() with base 10: 'x'")
        let java = "java.lang.NullPointerException: id\n\tat shop.OrderController.get(OrderController.java:42)"
        #expect(classify(.types, status: 500, body: java)?.evidence == "java.lang.NullPointerException: id")
        #expect(classify(.types, status: 500, body: "oops")?.problem == .serverError)
        // A route that already answers 500 isn't blamed on the payload.
        #expect(classify(.types, status: 500, body: "oops", baseline: 500) == nil)
        #expect(classify(.types, status: nil, error: "timed out")?.problem == .hang)
        #expect(classify(.types, status: nil, error: "connection dropped")?.problem == .dropped)
        #expect(classify(.types, status: 200, duration: 6)?.problem == .slow)
        #expect(classify(.traversal, status: 200, body: "root:x:0:0:root:/root:/bin/sh")?.severity == .critical)
        #expect(classify(.template, status: 200, body: "Hello 1787569")?.problem == .template)
        #expect(classify(.script, status: 200, body: "<p><script>dante7bliksem</script></p>", type: "text/html")?.severity == .high)
        #expect(classify(.script, status: 200, body: "{\"q\":\"<script>dante7bliksem</script>\"}", type: "application/json")?.severity == .low)
        // A page naming its own scripts isn't a stack trace.
        #expect(classify(.types, status: 200, body: "at render (/src/app.js:10:5)") == nil)
    }

    @Test func mergesByRouteAndProblem() {
        let a = FuzzFinding(route: "GET /a", problem: .serverError, severity: .high, sent: "query: -1", answer: "500")
        var b = a
        b.sent = "query: 0"
        let c = FuzzFinding(route: "GET /a", problem: .sqlError, severity: .critical, sent: "query: '", answer: "500")
        let merged = Fuzz.merged([a, b, c])
        #expect(merged.map(\.problem) == [.sqlError, .serverError])
        #expect(merged.last?.count == 2)
        #expect(merged.last?.sent == "query: -1")
    }
}

struct ChaosTests {
    func samples(_ ranges: [(ClosedRange<Int>, Int?)]) -> [BliksemSample] {
        ranges.flatMap { range, status in
            range.flatMap { second in (0..<5).map { BliksemSample(route: "GET /a", start: Double(second) + Double($0) / 5, duration: 0.02, status: status) } }
        }
    }

    @Test func recoveredAfterTheRestore() {
        let run = samples([(0...9, 200), (10...19, 503), (20...22, 503), (23...40, 200)])
        let analysis = ChaosAnalysis.analyse(run, times: ChaosTimes(broke: 10, restored: 20, ended: 41))
        #expect(analysis.verdict == .recovered(3))
        #expect(analysis.firstFailure == 0)
        #expect(analysis.outageFailing == 1)
        #expect(analysis.answers.first == .init(text: "503", count: 65))
        #expect(analysis.story(service: "db", fault: .stop) == "With db stopped, 100% of requests failed, mostly 503. It recovered 3 s after it was back.")
    }

    @Test func rodeItOut() {
        let analysis = ChaosAnalysis.analyse(samples([(0...40, 200)]), times: ChaosTimes(broke: 10, restored: 20, ended: 41))
        #expect(analysis.verdict == .rodeItOut)
        #expect(analysis.story(service: "cache", fault: .pause).hasSuffix("the system rode it out."))
    }

    @Test func stayedBroken() {
        let analysis = ChaosAnalysis.analyse(samples([(0...9, 200), (10...40, nil)]), times: ChaosTimes(broke: 10, restored: 20, ended: 41))
        #expect(analysis.verdict == .stayedBroken)
        #expect(analysis.answers.first?.text == "no answer")
    }

    @Test func faultsAndTheirRestores() {
        #expect(ChaosFault.pause.breaking("db") == ["docker", "compose", "pause", "db"])
        #expect(ChaosFault.pause.restoring("db") == ["docker", "compose", "unpause", "db"])
        #expect(ChaosFault.kill.restoring("db") == ["docker", "compose", "start", "db"])
        #expect(ChaosFault.restart.restoring("db") == nil)
    }

    @Test func onlyThisProjectsRunningServices() {
        let compose = ComposeFile(services: [.init(name: "db"), .init(name: "api"), .init(name: "worker")])
        let containers = [ContainerState(service: "db", state: "running"), ContainerState(service: "api", state: "running"),
                          ContainerState(service: "worker", state: "exited"), ContainerState(service: "other", state: "running")]
        #expect(ChaosPlan.candidates(compose: compose, containers: containers) == ["api", "db"])
    }
}
