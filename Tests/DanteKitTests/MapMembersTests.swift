import Foundation
import Testing
@testable import DanteKit

/// The deepest levels of the map: folders of files, a file's methods, and a table traced
/// back to the routes that reach it.
struct MapMembersTests {
    static let java = "app/src/main/java/com/example/shop"
    static let files: [String: String] = [
        "\(java)/ShopApplication.java": "package com.example.shop;\n@SpringBootApplication\npublic class ShopApplication {}",
        "\(java)/controllers/OrderController.java": """
        package com.example.shop.controllers;
        import com.example.shop.services.OrderService;
        @RestController
        @RequestMapping("/api/orders")
        public class OrderController {
            private final OrderService orders;

            @GetMapping
            public List<Order> list() {
                return orders.all();
            }

            @PostMapping("/{id}/cancel")
            public void cancel(@PathVariable long id) {
                if (id > 0) { log(id); }
            }

            private void log(long id) {
                System.out.println(id);
            }
        }
        """,
        "\(java)/controllers/HealthController.java": """
        package com.example.shop.controllers;
        @RestController
        public class HealthController {
            @GetMapping("/ping")
            public String ping() { return "ok"; }
        }
        """,
        "\(java)/services/OrderService.java": """
        package com.example.shop.services;
        import com.example.shop.repositories.OrderRepository;
        @Service
        public class OrderService {
            private final OrderRepository repository;
            public List<Order> all() { return repository.findAll(); }
        }
        """,
        "\(java)/repositories/OrderRepository.java": """
        package com.example.shop.repositories;
        @Repository
        public interface OrderRepository extends JpaRepository<Order, Long> {
            List<Order> findByStatus(String status);
            List<Order> findByCustomer(long customer);
        }
        """,
        "\(java)/models/Order.java": """
        package com.example.shop.models;
        @Entity
        @Table(name = "orders")
        public class Order {}
        """,
        "db/schema.sql": """
        create table customers (id bigint primary key, name text);
        create table orders (
            id bigint primary key,
            customer_id bigint references customers(id),
            status varchar(20) not null, -- open, paid
            total numeric(10, 2)
        );
        create table order_lines (id bigint, order_id bigint, constraint fk_order foreign key (order_id) references orders (id));
        """,
    ]
    static var paths: [String] { Array(files.keys) }
    static func read(_ path: String) -> String? { files[path] }

    @Test func aFolderOfFilesOpensIntoItsClasses() throws {
        let inside = try #require(ArchitectureGraph.inner(files: Self.paths, root: "\(Self.java)/controllers", read: Self.read))
        #expect(Set(inside.nodes.map(\.name)) == ["OrderController", "HealthController"])
        let order = try #require(inside.nodes.first { $0.name == "OrderController" })
        #expect(order.detail == "controller · 3 methods")
        // Classes in one package name each other without importing.
        let services = try #require(ArchitectureGraph.inner(files: Self.paths, root: Self.java, read: Self.read))
        #expect(services.edges.contains { $0.from.hasSuffix("/controllers") && $0.to.hasSuffix("/services") })
    }

    @Test func javaMethodsAreFoundWithoutStatements() {
        let members = SystemMap.members(of: "\(Self.java)/controllers/OrderController.java", text: Self.files["\(Self.java)/controllers/OrderController.java"]!)
        #expect(members.map(\.name) == ["list", "cancel", "log"])
        #expect(members[0].line == 9 && members[0].end == 11)
        let repository = SystemMap.members(of: "x/OrderRepository.java", text: Self.files["\(Self.java)/repositories/OrderRepository.java"]!)
        #expect(repository.map(\.name) == ["findByStatus", "findByCustomer"])
    }

    @Test func aFileOpensIntoItsMethodsWithRoutesAndWhatTheyUse() throws {
        let file = "\(Self.java)/controllers/OrderController.java"
        let map = try #require(SystemMap.inside(file: file, files: Self.paths, read: Self.read))
        #expect(map.parts.filter { $0.lane == .backend }.map(\.name) == ["list()", "cancel()", "log()"])
        #expect(map.parts.filter { $0.lane == .api }.map(\.name) == ["/api/orders", "/api/orders/{id}/cancel"])
        let list = try #require(map.parts.first { $0.name == "list()" })
        let cancel = try #require(map.parts.first { $0.name == "cancel()" })
        let log = try #require(map.parts.first { $0.name == "log()" })
        #expect(map.links.contains { $0.from == "route:GET /api/orders" && $0.to == list.id })
        #expect(map.links.contains { $0.from == cancel.id && $0.to == log.id })
        // The service it uses through its field, which opens in turn.
        let service = try #require(map.parts.first { $0.lane == .outside && $0.name == "OrderService" })
        #expect(service.name == "OrderService" && service.detail == "service · 1 method")
        #expect(map.links.contains { $0.from == list.id && $0.to == service.id })
        #expect(map.opens(service, files: Self.paths, read: Self.read) == false)
        #expect(map.opens(list, files: Self.paths, read: Self.read) == false)
        // A repository's methods all use its entity's table.
        let repository = try #require(SystemMap.inside(file: "\(Self.java)/repositories/OrderRepository.java", files: Self.paths, read: Self.read))
        #expect(repository.links.filter { $0.to == "table:orders" }.count == 2)
    }

    @Test func columnsAndForeignKeysAreRead() {
        let columns = SystemMap.columns(of: "orders", in: Self.files["db/schema.sql"]!)
        #expect(columns.map(\.name) == ["id", "customer_id", "status", "total"])
        #expect(columns[1].references == "customers")
        #expect(columns[2].type == "varchar(20)")
        let lines = SystemMap.columns(of: "order_lines", in: Self.files["db/schema.sql"]!)
        #expect(lines.first { $0.name == "order_id" }?.references == "orders")
    }

    @Test func aTableIsTracedBackToTheRoutesThatReachIt() throws {
        let part = SystemMap.Part(id: "table:orders", name: "orders", lane: .data, kind: .table)
        let map = try #require(SystemMap.inside(part, files: Self.paths, read: Self.read))
        let code = Set(map.parts.filter { $0.lane == .backend }.map(\.name))
        #expect(code == ["OrderRepository", "OrderService", "OrderController", "Order"])
        #expect(map.links.contains { $0.from.hasSuffix("OrderController.java") && $0.to.hasSuffix("OrderService.java") })
        #expect(map.links.contains { $0.from.hasSuffix("OrderRepository.java") && $0.to == "table:orders" })
        // Only the route whose handler reaches the service.
        #expect(map.parts.filter { $0.lane == .api }.map(\.name) == ["/api/orders"])
        // Its columns, and the tables either side of a foreign key, which open too.
        let table = try #require(map.part("table:orders"))
        #expect(table.items.map(\.text) == ["id bigint", "customer_id bigint → customers", "status varchar(20)", "total numeric(10, 2)"])
        #expect(map.links.contains { $0.from == "table:orders" && $0.to == "table:customers" })
        #expect(map.links.contains { $0.from == "table:order_lines" && $0.to == "table:orders" })
        #expect(!map.opens(table, files: Self.paths) && map.opens(map.part("table:customers")!, files: Self.paths))
    }
}
