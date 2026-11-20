import Foundation
import Testing
@testable import DanteKit

struct LocalHealthTests {
    private let compose = """
    services:
      db:
        image: postgres:16
        ports: ["5436:5432"]
      api:
        build: ./api
        ports: ["8086:8080"]
      web:
        build:
          context: web
        ports: ["3000:3000"]
      worker:
        build: ./worker
    """

    @Test func appServicesAreCheckedOnTheirHealthRoute() throws {
        let file = ComposeFile(url: URL(fileURLWithPath: "/home/me/shop/compose.yaml"), services: try ComposeFile.parse(compose))
        let files: [String: String] = [
            "api/main.py": "@app.get(\"/health\")\ndef health(): return {}\n",
            "api/tests/test_health.py": "client.get('/healthz')\n",
            "web/src/server.ts": "app.get('/ping', ok)\n",
            "worker/run.py": "print('hi')\n",
        ]
        let checks = LocalHealth.checks(compose: file, files: Array(files.keys).sorted()) { files[$0] }
        #expect(checks.map(\.name) == ["api", "web"])
        #expect(checks.map(\.url.absoluteString) == ["http://localhost:8086/health", "http://localhost:3000/ping"])
    }

    @Test func springActuatorAndTheRootAreFallbacks() {
        #expect(LocalHealth.route(in: ["pom.xml"]) { _ in "<artifactId>spring-boot-starter-actuator</artifactId>" } == "/actuator/health")
        #expect(LocalHealth.route(in: ["main.go"]) { _ in "http.HandleFunc(\"/orders\", list)" } == nil)
    }

    @Test func logsFollowTheComposeFile() {
        let file = ComposeFile(url: URL(fileURLWithPath: "/home/me/shop/compose.yaml"), services: [])
        #expect(LocalHealth.logsCommand(compose: file) == "docker compose -f compose.yaml logs -f --no-color --tail 200")
    }
}
