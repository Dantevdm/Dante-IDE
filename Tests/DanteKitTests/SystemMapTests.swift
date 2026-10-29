import Foundation
import Testing
@testable import DanteKit

struct SystemMapTests {
    static let files: [String: String] = [
        "backend/go.mod": "module example.com/shop\n\ngo 1.22\n\nrequire modernc.org/sqlite v1.30.0\n",
        "backend/main.go": """
        package main

        import (
            "example.com/shop/internal/api"
            "example.com/shop/internal/db"
        )

        func main() {
            mux.Handle("/", http.FileServerFS(sub))
        }
        """,
        "backend/internal/api/handlers.go": """
        package api

        import (
            "example.com/shop/internal/db"
        )

        func (h *Handlers) Register(mux *http.ServeMux) {
            mux.HandleFunc("GET /api/orders", h.listOrders)
            mux.HandleFunc("GET /api/orders/{id}", h.getOrder)
            mux.HandleFunc("POST /api/orders", h.createOrder)
            mux.HandleFunc("GET /api/stats", h.stats)
        }
        """,
        "backend/internal/api/notify.go": """
        package api

        import mail "gopkg.in/mail.v2"

        const base = "https://graph.facebook.com/v20.0" // whatsapp messages
        """,
        "backend/internal/db/db.go": """
        package db

        import _ "modernc.org/sqlite"

        const seed = `INSERT INTO settings VALUES ('model_url', 'http://localhost:11434')`
        """,
        "backend/internal/api/handlers_test.go": "package api\nfunc TestX(t *testing.T) { mux.HandleFunc(\"GET /api/secret\", nil) }\n",
        "backend/public/app.js": "fetch('/api/orders')",
        "frontend/index.html": "<script type=module src=app.js></script>",
        "frontend/app.js": "import { renderOrders } from './views/orders.js';",
        "frontend/views/orders.js": "api(`/api/orders?page=${page}`); api(`/api/orders/${id}`); fetch('/api/stats')",
        "frontend/views/settings.js": "fetch('/api/unknown')",
        "docker-compose.yml": "",
    ]

    static func build(compose: ComposeFile? = nil) -> SystemMap {
        let paths = files.keys.sorted()
        let modules = ArchitectureGraph.goModules(files: paths) { files[$0] }
        return SystemMap.build(files: paths, read: { files[$0] }, compose: compose, modules: modules)
    }

    @Test func drawsEveryLaneFromTheCode() {
        let map = Self.build()
        #expect(map.lanes.map(\.lane) == [.clients, .api, .backend, .data, .outside])

        let client = map.part("client:frontend")
        #expect(client?.detail == "JavaScript · 2 screens")
        #expect(client?.items.map(\.text) == ["orders", "settings"])
        // The build copy under backend/public isn't a second client.
        #expect(map.parts.filter { $0.lane == .clients }.count == 1)

        let orders = map.part("route:/api/orders")
        #expect(orders?.items.map(\.text) == ["GET /api/orders", "GET /api/orders/{id}", "POST /api/orders"])
        #expect(orders?.items.first?.file == "backend/internal/api/handlers.go" && orders?.items.first?.line == 8)
        #expect(orders?.detail == "3 routes · GET POST · 3 open")
        #expect(map.part("route:/api/secret") == nil)
        #expect(map.routeCount == 4)

        #expect(map.parts.filter { $0.lane == .backend }.map(\.name) == ["backend", "api", "db"])
    }

    @Test func linksFollowCallsImportsAndHosts() {
        let map = Self.build()
        let module = "code:example.com/shop"
        func linked(_ from: String, _ to: String) -> Bool { map.links.contains { $0.from == from && $0.to == to } }
        #expect(linked("client:frontend", "route:/api/orders"))
        #expect(map.links.first { $0.from == "client:frontend" && $0.to == "route:/api/orders" }?.weight == 2)
        #expect(linked("client:frontend", "route:/api/stats"))
        #expect(linked("route:/api/orders", module + "/internal/api"))
        #expect(linked(module, module + "/internal/api"))
        #expect(linked(module + "/internal/api", module + "/internal/db"))
        #expect(linked(module + "/internal/db", "db:sqlite"))
        #expect(linked(module + "/internal/api", "ext:smtp"))
        #expect(map.part("ext:meta")?.name == "WhatsApp Cloud API")
        // A host stored as a setting in the db package isn't a call.
        #expect(map.part("ext:ollama") == nil)
    }

    @Test func composeServicesJoinTheirParts() throws {
        let yaml = """
        services:
          app:
            build: ./backend
            depends_on: [models]
          models:
            image: ollama/ollama:latest
          cache:
            image: redis:7
        """
        let compose = ComposeFile(url: URL(filePath: "/home/me/shop/docker-compose.yml"), services: try ComposeFile.parse(yaml))
        let map = Self.build(compose: compose)
        #expect(map.parts.filter { $0.lane == .backend }.allSatisfy { $0.container == "app" })
        #expect(map.part("client:frontend")?.container == nil)
        let models = map.parts.first { $0.container == "models" }
        #expect(models?.name == "Ollama" && models?.lane == .outside)
        #expect(map.links.contains { $0.from == "code:example.com/shop" && $0.to == models?.id })
        #expect(map.parts.first { $0.container == "cache" }?.lane == .data)
    }

    @Test func screensThatCallTheAPIGetTheirOwnBoxes() {
        var files = Self.files
        files["frontend/views/stats.js"] = "fetch('/api/stats')"
        files["frontend/views/orders.js"] = "api(`/api/orders/${id}`)"
        let paths = files.keys.sorted()
        let map = SystemMap.build(files: paths, read: { files[$0] }, modules: ArchitectureGraph.goModules(files: paths) { files[$0] })
        #expect(map.parts.filter { $0.lane == .clients }.map(\.name) == ["frontend", "orders", "stats"])
        #expect(map.links.contains { $0.from == "screen:client:frontend:orders" && $0.to == "route:/api/orders" })
        #expect(map.links.contains { $0.from == "screen:client:frontend:stats" && $0.to == "route:/api/stats" })
        #expect(!map.links.contains { $0.from == "client:frontend" && $0.to.hasPrefix("route:") })
    }

    @Test func routeShapes() {
        let go = SystemMap.routes(in: "r.Get(\"/accounts/{id}\", h)\nmux.HandleFunc(\"/health\", ok)")
        #expect(go == [.init(method: "GET", path: "/accounts/{id}", line: 1), .init(method: nil, path: "/health", line: 2)])
        let express = SystemMap.routes(in: "router.post('/login', auth)\naxios.get('/api/x')")
        #expect(express.map(\.path) == ["/login"])
        let python = SystemMap.routes(in: "@app.get(\"/items/{id}\")\n@bp.route('/old')")
        #expect(python.map(\.method) == ["GET", nil])
        #expect(SystemMap.routeGroup("/api/v1/accounts/{id}") == "/api/v1/accounts")
        #expect(SystemMap.routeGroup("/health") == "/health")
        #expect(SystemMap.calledPaths(in: "fetch(`/api/emails?page=${p}`)") == ["/api/emails"])
    }

    @Test func nextAppScreens() {
        let files = ["web/package.json", "web/app/page.tsx", "web/app/orders/[id]/page.tsx", "web/app/layout.tsx", "web/components/Button.tsx"]
        let clients = SystemMap.frontends(files: files) { $0.hasSuffix("package.json") ? #"{"dependencies": {"next": "15", "react": "19"}}"# : nil }
        #expect(clients.first?.detail == "Next.js · 2 screens")
        #expect(clients.first?.items.map(\.text) == ["home", "orders/:id"])
    }

    @Test func servicesNeedAPackageOrHostNotJustTheirName() {
        var files = Self.files
        files["backend/internal/api/detect.go"] = "package api\nvar roots = []string{\"supabase/migrations/\", \"firebase.json\"}"
        var paths = files.keys.sorted()
        var map = SystemMap.build(files: paths, read: { files[$0] }, modules: ArchitectureGraph.goModules(files: paths) { files[$0] })
        #expect(map.part("ext:supabase") == nil && map.part("ext:firebase") == nil)

        files["backend/internal/api/auth.go"] = "package api\nconst url = \"https://abc.supabase.co/auth/v1\""
        paths = files.keys.sorted()
        map = SystemMap.build(files: paths, read: { files[$0] }, modules: ArchitectureGraph.goModules(files: paths) { files[$0] })
        #expect(map.part("ext:supabase") != nil)
    }

    @Test func tablesWebhooksAndEnvironment() {
        var files = Self.files
        files["backend/internal/db/schema.sql"] = "CREATE TABLE IF NOT EXISTS orders (id INTEGER);\ncreate table \"settings\" (key TEXT);"
        files["backend/internal/api/orders.go"] = """
        package api
        func (h *Handlers) list() { h.db.Query(`SELECT id FROM orders WHERE x = ?`) }
        var token = os.Getenv("WHATSAPP_TOKEN")
        var port = os.Getenv("PORT")
        """
        files["backend/internal/api/hooks.go"] = """
        package api
        func (h *Handlers) Register2(mux *http.ServeMux) {
            mux.HandleFunc("POST /api/webhooks/whatsapp", h.inbound) // from graph.facebook.com
        }
        """
        files["frontend/views/orders.js"] = "fetch('/api/orders'); const url = import.meta.env.VITE_API_URL"
        let paths = files.keys.sorted()
        let map = SystemMap.build(files: paths, read: { files[$0] }, modules: ArchitectureGraph.goModules(files: paths) { files[$0] })
        let api = "code:example.com/shop/internal/api"

        #expect(map.part("table:orders")?.detail == "SQLite table")
        #expect(map.part("table:settings")?.detail == "SQLite table")
        #expect(map.part("db:sqlite")?.items.map(\.text) == ["orders", "settings"])
        #expect(map.links.contains { $0.from == api && $0.to == "table:orders" })
        #expect(map.links.contains { $0.from == "code:example.com/shop/internal/db" && $0.to == "table:settings" })

        #expect(map.part("route:/api/webhooks")?.isWebhook == true)
        #expect(map.links.contains { $0.from == "ext:meta" && $0.to == "route:/api/webhooks" })

        #expect(map.part(api)?.env == ["PORT", "WHATSAPP_TOKEN"])
        #expect(map.part("client:frontend")?.env == ["VITE_API_URL"])
        #expect(SystemMap.isSecret("WHATSAPP_TOKEN") && SystemMap.isSecret("SMTP_PASSWORD") && !SystemMap.isSecret("PORT"))
    }

    @Test func exportsMermaidIntoArchitectureNotes() {
        let map = Self.build()
        let chart = map.mermaid()
        #expect(chart.hasPrefix("flowchart LR"))
        #expect(chart.contains("subgraph API[\"API\"]") || chart.contains("[\"API"))
        #expect(chart.contains("nclient_frontend --> nroute__api_orders"))
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = map.exporting(into: "# Notes\n\nKeep this.", date: date)
        #expect(first.hasPrefix("# Notes\n\nKeep this.\n\n<!-- dante:system-map -->"))
        let again = map.exporting(into: first + "\nAfter.", date: date)
        #expect(again.components(separatedBy: "<!-- dante:system-map -->").count == 2)
        #expect(again.hasSuffix("After."))
    }

    @Test func coverageReportsMatchProjectFiles() {
        let files = ["backend/internal/api/handlers.go", "web/src/app.ts", "app/views.py", "other/api/handlers.go"]
        let go = CoverageReport.parse("""
        mode: set
        example.com/shop/internal/api/handlers.go:10.2,12.3 2 1
        example.com/shop/internal/api/handlers.go:14.2,15.3 3 0
        example.com/shop/internal/api/handlers.go:10.2,12.3 2 0
        """, files: files)
        #expect(go.files["backend/internal/api/handlers.go"] == .init(covered: 2, total: 5))
        #expect(go.files["other/api/handlers.go"] == nil)
        let lcov = CoverageReport.parse("SF:/home/me/shop/web/src/app.ts\nLF:10\nLH:7\nend_of_record\n", files: files, root: "/home/me/shop")
        #expect(lcov.files["web/src/app.ts"]?.fraction == 0.7)
        let xml = CoverageReport.parse("<coverage><packages><package><classes><class filename=\"app/views.py\" line-rate=\"0.5\"><lines><line number=\"1\" hits=\"1\"/><line number=\"2\" hits=\"0\"/></lines></class></classes></package></packages></coverage>", files: files)
        #expect(xml.files["app/views.py"] == .init(covered: 1, total: 2))
    }

    @Test func byteSearchAndKeywordLines() {
        #expect(SystemMap.has("calls api.stripe.com here", "stripe.com"))
        #expect(!SystemMap.has("short", "longer than it"))
        #expect(SystemMap.has("anything", ""))
        #expect(SystemMap.has("naïve café", "café"))
        let sql = "select *\nfrom\n  users\nwhere id = 1\n-- unrelated"
        #expect(SystemMap.lines(of: sql, holding: ["from"], andNext: true) == "from\n  users")
        #expect(SystemMap.lines(of: "a\nENV x\nb", holding: ["ENV"]) == "ENV x")
    }

    @Test func goPackageClause() {
        #expect(ArchitectureGraph.goPackage("// Package main is the server.\npackage main\n\nfunc main() {}") == "main")
        #expect(ArchitectureGraph.goPackage("package store // import \"x\"") == "store")
        #expect(ArchitectureGraph.goPackage("func f() {}") == nil)
    }

    @Test func manyRouteGroupsKeepTheSameOnesEveryTime() {
        var files: [String: String] = ["go.mod": "module example.com/x\n"]
        for n in 0..<20 { files["h\(n).go"] = "package main\nfunc r(mux *http.ServeMux) { mux.HandleFunc(\"GET /g\(n)/a\", h) }" }
        let paths = Array(files.keys).sorted()
        let names = (0..<3).map { _ in
            SystemMap.build(files: paths, read: { files[$0] }).parts.filter { $0.lane == .api }.map(\.name)
        }
        #expect(names.allSatisfy { $0 == names[0] })
        #expect(names[0].contains("Other routes"))
    }
    @Test func testsFixturesCommentsAndCataloguesStayOffTheMap() {
        #expect(SystemMap.isTest("Tests/AppTests/ParserTests.swift"))
        #expect(SystemMap.isTest("src/test/java/app/UserTest.java"))
        #expect(SystemMap.isTest("internal/x/testdata/routes.go"))
        #expect(!SystemMap.isTest("Sources/App/Latest.swift"))
        #expect(!SystemMap.isTest("Sources/App/Contest.swift"))

        let files: [String: String] = [
            "go.mod": "module example.com/x\n",
            "main.go": "package main\n// e.g. mux.HandleFunc(\"GET /docs/example\", h)\nfunc main() { mux.HandleFunc(\"GET /api/orders\", h) }",
            "catalog.go": "package main\nvar known = []string{\"api.stripe.com\", \"api.openai.com\", \"api.anthropic.com\", \"hooks.slack.com\", \"api.twilio.com\", \"api.sendgrid.com\"}",
            "schema.go": "package main\nconst example = `CREATE TABLE widgets (id int)`",
            "Tests/MainTests/RoutesTests.swift": "app.get(\"/api/fixture\")",
        ]
        let paths = Array(files.keys).sorted()
        let map = SystemMap.build(files: paths, read: { files[$0] })
        let routes = map.parts.filter { $0.lane == .api }.flatMap(\.items).map(\.text)
        #expect(routes == ["GET /api/orders"])
        #expect(!map.parts.contains { $0.lane == .outside })
        #expect(!map.parts.contains { $0.kind == .table })
    }

    @Test func aServiceIsItsPackageNotItsName() {
        // A list of design references names Stripe; only a dependency or an import uses it.
        let named: [String: String] = [
            "go.mod": "module example.com/x\n",
            "looks.go": "package main\nvar looks = []string{\"Apple keynote\", \"Stripe\", \"Linear\"}",
        ]
        let quiet = SystemMap.build(files: Array(named.keys), read: { named[$0] })
        #expect(!quiet.parts.contains { $0.id.contains("stripe") })

        let stripe = try! #require(SystemMap.outsideServices.first { $0.id == "stripe" })
        let uses = { (text: String) in stripe.patterns.contains { SystemMap.has(text.lowercased(), $0.lowercased()) } }
        #expect(uses(#"{ "dependencies": { "stripe": "^14.0.0" } }"#))
        #expect(uses("import Stripe from 'stripe'"))
        #expect(!uses(#"options: ["Apple keynote", "Stripe", "Linear"]"#))
    }
}

struct GroupedServicesMapTests {
    /// services/java holds two Gradle builds and services/react a Vite app: the backend is the
    /// two services and the React app is only a client.
    @Test func groupingFoldersGiveWayToTheirProjects() {
        let files = [
            "services/java/order-service/build.gradle.kts",
            "services/java/order-service/src/main/java/shop/OrderController.java",
            "services/java/order-service/src/main/java/shop/OrderRepository.java",
            "services/java/starter-app/build.gradle.kts",
            "services/java/starter-app/src/main/java/shop/App.java",
            "services/react/shop-ui/package.json",
            "services/react/shop-ui/src/main.tsx",
            "services/react/shop-ui/src/App.tsx",
        ]
        let modules = ArchitectureGraph.folders(files)
        #expect(Set(modules?.nodes.map(\.path) ?? []) == ["services/java/order-service", "services/java/starter-app", "services/react/shop-ui"])
        let read: (String) -> String? = { $0.hasSuffix("package.json") ? #"{"dependencies":{"react":"18.3.1"}}"# : "" }
        let map = SystemMap.build(files: files, read: read, modules: modules)
        #expect(map.parts.filter { $0.lane == .clients }.map(\.name) == ["shop-ui"])
        #expect(Set(map.parts.filter { $0.lane == .backend }.map(\.name)) == ["order-service", "starter-app"])
    }

    @Test func aFolderAroundAFrontendStaysOnlyForItsOwnCode() {
        let files = ["services/react/shop-ui/package.json", "services/react/shop-ui/src/App.tsx", "services/api/main.go", "services/api/routes.go"]
        let modules = ArchitectureGraph(title: "Folders", source: "test", nodes: [
            .init(id: "services/react", name: "react", kind: .folder, path: "services/react", detail: ""),
            .init(id: "services/api", name: "api", kind: .folder, path: "services/api", detail: ""),
        ], edges: [])
        let read: (String) -> String? = { $0.hasSuffix("package.json") ? #"{"dependencies":{"react":"18.3.1"}}"# : "" }
        let map = SystemMap.build(files: files, read: read, modules: modules)
        #expect(map.parts.filter { $0.lane == .backend }.map(\.name) == ["api"])
    }
}
