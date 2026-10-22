import Foundation
import Testing
@testable import DanteKit

/// Who may call each endpoint, and why an open one is open.
struct MapAccessTests {
    static let java = "api/src/main/java/com/example/shop"
    static let spring: [String: String] = [
        "api/pom.xml": "<dependency><artifactId>spring-boot-starter-security</artifactId></dependency>",
        "\(java)/SecurityConfig.java": """
        @Configuration
        public class SecurityConfig {
            @Bean
            SecurityFilterChain chain(HttpSecurity http) throws Exception {
                http.authorizeHttpRequests(auth -> auth
                    .requestMatchers("/ping", "/actuator/health").permitAll()
                    .requestMatchers(HttpMethod.POST, "/auth/login").permitAll()
                    .requestMatchers("/public/**").permitAll()
                    .anyRequest().authenticated());
                return http.build();
            }
        }
        """,
        "\(java)/PingController.java": """
        @RestController
        public class PingController {
            @GetMapping("/ping")
            public String ping() { return "ok"; }
        }
        """,
        "\(java)/OrderController.java": """
        @RestController
        @RequestMapping("/api/orders")
        public class OrderController {
            @GetMapping
            public List<Order> list() { return List.of(); }

            @PreAuthorize("hasRole('ADMIN')")
            @DeleteMapping("/{id}")
            public void delete(@PathVariable long id) {}
        }
        """,
        "\(java)/PublicController.java": """
        @RestController
        public class PublicController {
            @GetMapping("/public/prices/{id}")
            public String price() { return ""; }
            @PostMapping("/auth/login")
            public String login() { return ""; }
        }
        """,
    ]

    static func access(_ files: [String: String], _ route: String) throws -> SystemMap.Access {
        let map = SystemMap.build(files: Array(files.keys), read: { files[$0] })
        let item = try #require(map.parts.flatMap(\.items).first { $0.text == route }, "\(route)")
        return try #require(item.access)
    }

    @Test func springRulesAndAnnotations() throws {
        let ping = try Self.access(Self.spring, "GET /ping")
        #expect(ping.level == .open && ping.reason == .health && !ping.isConcern)
        #expect(ping.file?.hasSuffix("SecurityConfig.java") == true && ping.line == 6)
        let list = try Self.access(Self.spring, "GET /api/orders")
        #expect(list.level == .secured && list.note.contains("anyRequest().authenticated()"))
        let delete = try Self.access(Self.spring, "DELETE /api/orders/{id}")
        #expect(delete.level == .secured && delete.note.contains("@PreAuthorize"))
        let price = try Self.access(Self.spring, "GET /public/prices/{id}")
        #expect(price.level == .open && price.reason == .permitted && price.isConcern)
        let login = try Self.access(Self.spring, "POST /auth/login")
        #expect(login.reason == .signIn && !login.isConcern)
        // The group says how many are open without a reason.
        let map = SystemMap.build(files: Array(Self.spring.keys), read: { Self.spring[$0] })
        #expect(map.parts.first { $0.name == "/public/prices" }?.detail.hasSuffix("· 1 open") == true)
    }

    @Test func withoutSpringSecurityEverythingIsOpen() throws {
        var files = Self.spring
        files["api/pom.xml"] = "<dependency><artifactId>spring-boot-starter-web</artifactId></dependency>"
        files["\(Self.java)/SecurityConfig.java"] = nil
        let list = try Self.access(files, "GET /api/orders")
        #expect(list.level == .open && list.reason == .unchecked && list.note.hasPrefix("The project has no Spring Security"))
        // The method annotation still counts.
        #expect(try Self.access(files, "DELETE /api/orders/{id}").level == .secured)
    }

    @Test func controllerFolderKeepsProjectSecurity() throws {
        // Configuration is a sibling of controllers; the build file is higher still.
        let controllers = "\(Self.java)/controllers"
        var files: [String: String] = [:]
        for (path, text) in Self.spring {
            let target = path.hasSuffix("Controller.java")
                ? "\(controllers)/\((path as NSString).lastPathComponent)"
                : path.replacingOccurrences(of: "/SecurityConfig.java", with: "/configuration/SecurityConfig.java")
            files[target] = text
        }
        let paths = Array(files.keys).sorted()
        let folder = SystemMap.Part(id: "controllers", name: "controllers", lane: .backend,
                                    kind: .package, path: controllers)
        func check(_ files: [String: String]) throws {
            let whole = SystemMap.build(files: paths, read: { files[$0] })
            let inside = try #require(SystemMap.inside(folder, files: paths, read: { files[$0] }))
            let routes = inside.parts.filter { $0.lane == .api }.flatMap(\.items)
            #expect(routes.count == 5)
            for route in routes {
                let original = try #require(whole.parts.flatMap(\.items).first { $0.text == route.text })
                #expect(route.access == original.access)
            }
            let orders = try #require(routes.first { $0.text == "GET /api/orders" })
            #expect(orders.access?.level == .secured)
            let ping = try #require(routes.first { $0.text == "GET /ping" })
            #expect(ping.access?.level == (files.keys.contains { $0.hasSuffix("SecurityConfig.java") } ? .open : .secured))
            #expect(inside.parts.allSatisfy { $0.path?.contains("configuration") != true })
        }
        try check(files)
        // A dependency alone still supplies Spring's default authentication policy.
        files["\(Self.java)/configuration/SecurityConfig.java"] = nil
        try check(files)
    }

    @Test func middlewareAndDependencies() throws {
        let files = [
            "server/package.json": #"{"dependencies":{"express":"4"}}"#,
            "server/routes.js": """
            const router = express.Router();
            router.get('/health', (req, res) => res.send('ok'));
            router.post('/webhooks/stripe', handler);
            router.get('/orders', requireAuth, listOrders);
            router.get('/prices', listPrices);
            router.use(requireAuth);
            router.delete('/orders/:id', deleteOrder);
            """,
            "app/main.py": """
            from fastapi import FastAPI, Depends
            app = FastAPI()
            @app.get("/me")
            def me(user = Depends(get_current_user)):
                return user
            @app.get("/metrics")
            def metrics():
                return {}
            """,
        ]
        #expect(try Self.access(files, "GET /health").reason == .health)
        let hook = try Self.access(files, "POST /webhooks/stripe")
        #expect(hook.reason == .webhook && hook.note.contains("none found"))
        #expect(try Self.access(files, "GET /orders").level == .secured)
        #expect(try Self.access(files, "GET /prices").reason == .unchecked)
        #expect(try Self.access(files, "DELETE /orders/:id").note.contains("for the router"))
        #expect(try Self.access(files, "GET /me").note.contains("Depends(get_current_user)"))
        let metrics = try Self.access(files, "GET /metrics")
        #expect(metrics.reason == .internals && metrics.isConcern)
    }

    @Test func antPatterns() {
        let matches = SystemMap.AccessRules.matches
        #expect(matches("/public/**", "/public/prices/{id}"))
        #expect(matches("/public/**", "/public"))
        #expect(matches("/api/*/items", "/api/v1/items"))
        #expect(!matches("/api/*/items", "/api/v1/x/items"))
        #expect(matches("/orders/{id}", "/orders/{orderId}"))
        #expect(!matches("/ping", "/pings"))
    }
}
