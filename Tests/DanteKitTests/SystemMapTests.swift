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
        #expect(orders?.detail == "3 routes · GET POST")
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
}
