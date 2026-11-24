import Foundation
import Testing
@testable import DanteKit

struct ResourceReadingTests {
    @Test func readsPsAndDockerStats() {
        let ps = ResourceReading.ps("   1:02.50  204800\n")
        #expect(ps?.cpuSeconds == 62.5)
        #expect(ps?.memory == 209_715_200)
        #expect(ResourceReading.ps("2-01:00:00 10")?.cpuSeconds == 176_400)
        let line = "\u{1b}[2J\u{1b}[H{\"CPUPerc\":\"153.20%\",\"MemUsage\":\"512MiB / 7.6GiB\",\"Name\":\"shop-api-1\"}"
        let docker = ResourceReading.dockerStats(line)
        #expect(docker?.cpu == 153.2)
        #expect(docker?.memory == 536_870_912)
        #expect(ResourceReading.memory(1_400_000_000) == "1.4 GB")
    }
}

struct ProfileTests {
    let dump = """
    "eventLoopGroupProxy-4-1" #45 prio=5 os_prio=31 cpu=812.21ms elapsed=60.1s tid=0x1 nid=0x2 runnable  [0x3]
       java.lang.Thread.State: RUNNABLE
    \tat org.apache.pdfbox.pdmodel.PDPageContentStream.showText(PDPageContentStream.java:401)
    \tat shop.pdf.QuoteRenderer.render(QuoteRenderer.kt:5)
    \tat shop.orders.OrderService.quotePdf(OrderService.kt:6)
    \tat shop.orders.OrderRoutesKt$orderRoutes$1$2.invokeSuspend(OrderRoutes.kt:6)
    \tat kotlin.coroutines.jvm.internal.BaseContinuationImpl.resumeWith(ContinuationImpl.kt:33)

    "nioEventLoopGroup-2-1" #20 prio=10 runnable
       java.lang.Thread.State: RUNNABLE
    \tat sun.nio.ch.KQueue.poll(java.base@21.0.4/Native Method)
    \tat sun.nio.ch.KQueueSelectorImpl.doSelect(KQueueSelectorImpl.java:125)

    "worker-1" #30 waiting on condition
       java.lang.Thread.State: WAITING (parking)
    \tat jdk.internal.misc.Unsafe.park(java.base@21.0.4/Native Method)
    """

    @Test func keepsBusyThreadsAndCountsTheProjectsMethods() {
        let stacks = ThreadDump.busyStacks(dump)
        #expect(stacks.count == 1)
        #expect(stacks[0][1] == StackFrame(type: "shop.pdf.QuoteRenderer", method: "render", file: "QuoteRenderer.kt", line: 5))
        var profile = Profile(packages: ["shop"])
        profile.add(stacks)
        profile.add(stacks)
        let (busy, methods) = profile.methods()
        #expect(busy == 2)
        #expect(methods.first { $0.label == "QuoteRenderer.render" }?.own == 2)
        #expect(methods.first { $0.label == "OrderService.quotePdf" }?.own == 0)
        #expect(methods.first { $0.label == "OrderService.quotePdf" }?.total == 2)
        #expect(methods.contains { $0.label == "orderRoutes (lambda)" })
    }

    @Test func packagesComeFromTheSources() {
        let files = ["src/shop/orders/Order.kt": "package shop.orders.model\n", "src/shop/App.kt": "package shop\n", "test/AppTest.kt": "package other\n"]
        #expect(Profile.packages(files: Array(files.keys), read: { files[$0] }) == ["shop"])
    }
}

struct RouteFlowTests {
    let routes = """
    package shop.orders

    fun Route.orderRoutes(service: OrderService) {
        get("/orders/{id}/pdf") {
            val id = call.parameters["id"]!!
            call.respondBytes(service.quotePdf(id))
        }
    }
    """
    let service = """
    package shop.orders

    class OrderService(private val renderer: QuoteRenderer) {
        fun quotePdf(id: String): ByteArray {
            val order = loadOrder(id)
            return renderer.render(order)
        }

        private fun loadOrder(id: String): Order = transaction {
            exec("SELECT * FROM orders WHERE id = ?")
        }
    }
    """
    let renderer = """
    package shop.pdf

    class QuoteRenderer {
        fun render(order: Order): ByteArray {
            PDDocument().use { doc -> doc.save() }
            return ByteArray(0)
        }
    }
    """

    @Test func followsTheHandlersCallsAndWhatTheyTouch() throws {
        let files = ["src/shop/orders/OrderRoutes.kt": routes, "src/shop/orders/OrderService.kt": service, "src/shop/pdf/QuoteRenderer.kt": renderer]
        let flow = try #require(RouteFlow.build(file: "src/shop/orders/OrderRoutes.kt", line: 4, title: "GET /orders/{id}/pdf", files: Array(files.keys), read: { files[$0] }))
        #expect(flow.steps.map(\.name) == ["GET /orders/{id}/pdf", "quotePdf", "loadOrder", "render"])
        #expect(flow.steps[0].end == 7)
        #expect(flow.steps.first { $0.name == "loadOrder" }?.effects == ["SQL on orders", "database transaction"])
        #expect(flow.steps.first { $0.name == "render" }?.effects == ["renders a PDF"])
        #expect(flow.steps.first { $0.name == "render" }?.parent == 1)

        var profile = Profile(packages: ["shop"])
        profile.add(ThreadDump.busyStacks(ProfileTests().dump))
        let heat = flow.heat(profile)
        #expect(heat[0] == 1)
        #expect(heat[3] == 1)
        #expect(heat[2] == nil)
    }

    @Test func aTaskFindsTheRouteThatServesIt() {
        var route = BliksemRoute(method: "GET", path: "/orders/{id}/pdf")
        route.file = "OrderRoutes.kt"
        var task = BliksemRoute(method: "GET", path: "/orders/ab12/pdf?inline=1")
        task.name = "Order PDF"
        #expect(task.handler(in: [route]) == route)
        #expect(BliksemRoute(method: "GET", path: "/orders/{id}").serves(method: "GET", path: "/orders/1/pdf") == false)
    }
}

struct ChaosAdviceTests {
    @Test func suggestsFailingFastHealthAndReadinessFromHowItBroke() {
        let analysis = ChaosAnalysis(baselineFailing: 0, baselineP95: 0.01, outageFailing: 0.71, outageP95: 4.6, firstFailure: 0.3,
                                     verdict: .recovered(9), answers: [.init(text: "timed out", count: 70), .init(text: "500", count: 5)])
        let files = ["module.yaml": "dependencies:\n  - com.zaxxer:HikariCP:7.1.0\n",
                     "docker-compose.yml": "services:\n  db:\n    image: postgres\n",
                     "src/App.kt": "fun x() {\n    get(\"/health\") {\n        call.respondText(\"ok\")\n    }\n}\n"]
        let found = ChaosAdvice.suggest(analysis, service: "db", fault: .stop, files: Array(files.keys), read: { files[$0] },
                                        healthRoute: ("src/App.kt", 2))
        let titles = found.map(\.title)
        #expect(titles.contains("Fail fast instead of hanging"))
        #expect(found.first?.fix.contains("connectionTimeout") == true)
        #expect(titles.contains("Recover faster"))
        #expect(titles.contains("Make the health check see db"))
        #expect(titles.contains("Start the app after db is ready"))
        #expect(!titles.contains("Answer 503 with Retry-After"))
    }

    @Test func nothingToSayWhenItRodeItOut() {
        let analysis = ChaosAnalysis(baselineFailing: 0, baselineP95: 0.01, outageFailing: 0, outageP95: 0.01, firstFailure: nil, verdict: .rodeItOut, answers: [])
        #expect(ChaosAdvice.suggest(analysis, service: "cache", fault: .stop, files: [], read: { _ in nil }, healthRoute: nil).isEmpty)
    }
}

struct RouteFlowBlockTests {
    @Test func anAnnotatedJavaMethodIsReadToItsClosingBrace() {
        let java = "class C {\n    @GetMapping(\"/x\")\n    public byte[] x() {\n        return y();\n    }\n}\n"
        #expect(RouteFlow.block(in: java, line: 2) == "    @GetMapping(\"/x\")\n    public byte[] x() {\n        return y();\n    }")
        let python = "@app.get(\"/x\")\ndef x():\n    return y()\n\ndef z():\n    pass\n"
        #expect(RouteFlow.block(in: python, line: 1, python: true) == "@app.get(\"/x\")\ndef x():\n    return y()\n")
    }
}

struct JavaDeclarationTests {
    @Test func javaMethodsAreDeclarationsButStatementsAreNot() {
        let java = """
        public class OrderService {
            public byte[] render(String order) {
            String loadOrder(String id) {
            private static <T> List<T> all(Class<T> type) throws IOException {
            data = digest.digest(data);
            return renderer.render(order);
            String sql = "SELECT 1";
            for (int i = 0; i < 4; i++) {
        """
        let names = DeclarationScanner.symbols(in: java, language: .java, url: URL(fileURLWithPath: "/home/me/A.java")).map(\.name)
        #expect(names == ["OrderService", "render", "loadOrder", "all"])
    }
}
