import Foundation
import Testing
@testable import DanteKit

/// A Spring Boot service behind a React app, with its schema in a SQL folder of its own.
struct MapDrillTests {
    static let java = "services/java/shop/src/main/java/com/example/shop"
    static let files: [String: String] = [
        "services/java/shop/pom.xml": "<project><artifactId>spring-boot-starter-web</artifactId><artifactId>postgresql</artifactId></project>",
        "\(java)/ShopApplication.java": "package com.example.shop;\n@SpringBootApplication\npublic class ShopApplication { public static void main(String[] a) {} }",
        "\(java)/controllers/OrderController.java": """
        package com.example.shop.controllers;
        import com.example.shop.services.OrderService;
        @RestController
        @RequestMapping("/api/orders")
        public class OrderController {
            @GetMapping
            public List<Order> list() { return service.all(); }
            @GetMapping("/{id}")
            public Order one(@PathVariable long id) { return null; }
            @PostMapping(value = "/{id}/cancel")
            public void cancel() {}
        }
        """,
        "\(java)/services/OrderService.java": """
        package com.example.shop.services;
        import com.example.shop.repositories.OrderRepository;
        import com.example.shop.repositories.AuditDao;
        @Service
        public class OrderService { String url = System.getenv("PAYMENTS_URL"); }
        """,
        "\(java)/repositories/OrderRepository.java": """
        package com.example.shop.repositories;
        import com.example.shop.models.Order;
        @Repository
        public interface OrderRepository extends JpaRepository<Order, Long> {}
        """,
        "\(java)/repositories/AuditDao.java": """
        package com.example.shop.repositories;
        @Repository
        public class AuditDao {
            void write() { jdbc.update("INSERT INTO shop.audit_log (what) VALUES (?)"); }
        }
        """,
        "\(java)/models/Order.java": """
        package com.example.shop.models;
        @Entity
        @Table(name = "orders")
        public class Order {}
        """,
        "services/java/shop/src/test/java/com/example/shop/OrderTest.java": "class OrderTest {}",
        "database/postgres/schema.sql": "create table shop.orders (id bigint);\ncreate table shop.audit_log (id bigint);",
        "services/web/package.json": #"{"dependencies":{"react":"18"}}"#,
        "services/web/vite.config.ts": "export default {}",
        "services/web/src/main.tsx": "import App from './App'",
        "services/web/src/App.tsx": "import { OrdersPage } from '@/pages/OrdersPage'",
        "services/web/src/pages/OrdersPage.tsx": "import { list } from '../api/orders'\nexport function OrdersPage() {}",
        "services/web/src/api/orders.ts": "export const list = () => http.get(`${API_BASE_URL}/orders/${id}`)",
        "services/web/src/components/Table.tsx": "export function Table() {}",
    ]

    func build() -> SystemMap {
        let paths = Array(Self.files.keys)
        return SystemMap.build(files: paths, read: { Self.files[$0] }, modules: ArchitectureGraph.folders(paths))
    }

    @Test func springRoutesAreReadFromTheirAnnotations() {
        let routes = SystemMap.annotatedRoutes(in: Self.files["\(Self.java)/controllers/OrderController.java"]!)
        #expect(routes.map { "\($0.method ?? "") \($0.path)" } == ["GET /api/orders", "GET /api/orders/{id}", "POST /api/orders/{id}/cancel"])
        let jaxrs = SystemMap.annotatedRoutes(in: """
        @Path("/items")
        public class ItemResource {
            @GET
            @Path("/{id}")
            public Item get() {}
            @POST
            public void add() {}
        }
        """)
        #expect(jaxrs.map { "\($0.method ?? "") \($0.path)" } == ["GET /items/{id}", "POST /items"])
        // Generated controllers spread each annotation over several lines.
        let generated = SystemMap.annotatedRoutes(in: """
        @RequestMapping("/session")
        public class SessionController {
          @PostMapping(
              produces = {"application/json"},
              value = "/end")
          public ResponseEntity<Void> end() {}
          @GetMapping(
              value = "/whoami",
              produces = {JSON})
          public ResponseEntity<Me> whoami() {}
        }
        """)
        #expect(generated.map { "\($0.method ?? "") \($0.path)" } == ["POST /session/end", "GET /session/whoami"])
        #expect(generated.map(\.line) == [3, 7])
    }

    @Test func theBackendLaneRunsFromItsEntryToWhatEverythingShares() {
        var map = SystemMap(parts: [], links: [])
        for name in ["server", "billing", "shipping", "shared", "tools"] {
            map.parts.append(SystemMap.Part(id: name, name: name, lane: .backend, kind: .package))
        }
        map.parts.append(SystemMap.Part(id: "route", name: "/x", lane: .api, kind: .routes))
        map.links = [.init(from: "route", to: "server"), .init(from: "server", to: "billing"), .init(from: "server", to: "shipping"),
                     .init(from: "billing", to: "shared"), .init(from: "shipping", to: "shared"), .init(from: "server", to: "shared")]
        #expect(map.tiers(of: .backend).map { $0.map(\.id) } == [["server"], ["billing", "shipping", "tools"], ["shared"]])
        #expect(map.tiers(of: .api).count == 1)
        map.links.append(.init(from: "shared", to: "server"))
        #expect(map.tiers(of: .backend).flatMap { $0 }.count == 5)
    }

    @Test func pythonPackagesImportTheFoldersTheyName() throws {
        let files: [String: String] = [
            "app/main.py": "from app.billing import invoices\nfrom app.shipping import parcels\n",
            "app/billing/invoices.py": "from app.core import db\n",
            "app/shipping/parcels.py": "from app.core import db\n",
            "app/core/db.py": "def query(): pass\n",
            "app/reports/weekly.py": "def run(): pass\n",
        ]
        let part = SystemMap.Part(id: "x", name: "app", lane: .backend, kind: .package, path: "app")
        let map = try #require(SystemMap.inside(part, files: Array(files.keys), read: { files[$0] }))
        #expect(map.tiers(of: .backend).map { Set($0.map(\.name)) } == [["app"], ["billing", "shipping", "reports"], ["core"]])
    }

    @Test func theWholeSystemLinksScreensRoutesAndTables() {
        let map = build()
        #expect(map.routeCount == 3)
        // The web app calls "/orders" on a base URL; the API serves it under /api.
        #expect(map.links.contains { $0.from == "client:services/web" && $0.to == "route:/api/orders" })
        let tables = map.parts.filter { $0.kind == .table }
        #expect(Set(tables.map(\.name)) == ["orders", "audit_log"])
        #expect(tables.allSatisfy { !$0.detail.contains("no queries") })
    }

    @Test func openingTheServiceShowsItsLayers() throws {
        let map = build()
        let service = try #require(map.parts.first { $0.lane == .backend && $0.name == "shop" })
        let paths = Array(Self.files.keys)
        #expect(map.opens(service, files: paths))
        let inside = try #require(SystemMap.inside(service, files: paths, read: { Self.files[$0] }))
        let pieces = inside.parts.filter { $0.lane == .backend }
        #expect(Set(pieces.map(\.name)) == ["shop", "controllers", "services", "repositories", "models"])
        #expect(inside.title(of: .backend) == "Inside shop")
        func id(_ name: String) -> String { pieces.first { $0.name == name }!.id }
        #expect(inside.links.contains { $0.from == id("controllers") && $0.to == id("services") })
        #expect(inside.links.contains { $0.from == id("services") && $0.to == id("repositories") })
        // Routes belong to the controllers; tables to the repository and the entity.
        #expect(inside.links.contains { $0.from == "route:/api/orders" && $0.to == id("controllers") })
        #expect(inside.links.contains { $0.from == id("repositories") && $0.to == "table:orders" })
        #expect(inside.links.contains { $0.from == id("repositories") && $0.to == "table:audit_log" })
        #expect(inside.links.contains { $0.from == id("models") && $0.to == "table:orders" })
        #expect(pieces.first { $0.name == "controllers" }?.detail == "1 controller · 1 file")
        #expect(pieces.first { $0.name == "services" }?.env == ["PAYMENTS_URL"])
        // The loose files are the entry point, with nothing further inside.
        let entry = try #require(pieces.first { $0.name == "shop" })
        #expect(entry.kind == .app && !inside.opens(entry, files: paths))
        #expect(inside.opens(pieces.first { $0.name == "controllers" }!, files: paths) == false)
    }

    @Test func openingTheWebAppShowsItsFolders() throws {
        let map = build()
        let web = try #require(map.parts.first { $0.id == "client:services/web" })
        let paths = Array(Self.files.keys)
        let inside = try #require(SystemMap.inside(web, files: paths, read: { Self.files[$0] }))
        let pieces = inside.parts.filter { $0.lane == .backend }
        // Down into src: vite.config.ts is tooling.
        #expect(Set(pieces.map(\.name)) == ["src", "pages", "api", "components"])
        func id(_ name: String) -> String { pieces.first { $0.name == name }!.id }
        #expect(inside.links.contains { $0.from == id("src") && $0.to == id("pages") })
        #expect(inside.links.contains { $0.from == id("pages") && $0.to == id("api") })
    }
}
