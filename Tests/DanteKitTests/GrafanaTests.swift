import Foundation
import Testing
@testable import DanteKit

struct GrafanaTests {
    private let app = """
    services:
      api:
        build: .
        ports: ["8080:8080"]
    """

    private let monitoring = """
    services:
      prometheus:
        image: prom/prometheus:v3.0.0
        ports: ["127.0.0.1:9091:9090"]
      node-exporter:
        image: quay.io/prometheus/node-exporter:v1.8.0
        ports: ["9100:9100"]
      grafana:
        image: grafana/grafana:12.0.0
        environment:
          GF_AUTH_ANONYMOUS_ENABLED: "false"
        ports:
          - "127.0.0.1:${SHOP_GRAFANA_PORT:-3000}:3000"
        volumes:
          - grafana-data:/var/lib/grafana
          - ./monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
          - ./monitoring/grafana/dashboards:/var/lib/grafana/dashboards:ro
    """

    private let mise = """
    [tools]
    java = "21"

    [tasks.monitoring]
    description = "Grafana and Prometheus"
    run = "docker compose -f compose.monitoring.yaml up -d --wait"
    """

    private func dashboards(_ folder: String) -> [(path: String, text: String)] {
        guard folder == "monitoring/grafana/dashboards" else { return [] }
        return [
            ("monitoring/grafana/dashboards/orders.json", #"{"uid":"shop-orders","title":"Orders","panels":[]}"#),
            ("monitoring/grafana/dashboards/api.json", #"{"dashboard":{"uid":"shop-api","title":"API"}}"#),
            ("monitoring/grafana/dashboards/broken.json", "{not json"),
        ]
    }

    @Test func findsGrafanaInANamedComposeFile() throws {
        let found = GrafanaSetup.detect(composeFiles: [("docker-compose.yml", app), ("compose.monitoring.yaml", monitoring)],
                                        env: [:], jsonFiles: dashboards, mise: mise)
        let grafana = try #require(found.first)
        #expect(found.count == 1)
        #expect(grafana.composeFile == "compose.monitoring.yaml")
        #expect(grafana.service == "grafana")
        #expect(grafana.port == 3000)
        #expect(grafana.anonymous == false)
        #expect(grafana.prometheusPort == 9091)
        #expect(grafana.dashboards.map(\.title) == ["API", "Orders"])
        #expect(grafana.startCommand == "mise run monitoring")
    }

    @Test func thePortComesFromTheEnvironment() {
        let found = GrafanaSetup.detect(composeFiles: [("compose.monitoring.yaml", monitoring)], env: ["SHOP_GRAFANA_PORT": "3300"],
                                        jsonFiles: { _ in [] }, mise: nil)
        #expect(found.first?.port == 3300)
        #expect(found.first?.startCommand == "docker compose -f compose.monitoring.yaml up -d")
    }

    @Test func oneEntryPerPortWithDevelopmentFilesFirst() {
        let found = GrafanaSetup.detect(composeFiles: [("compose.monitoring.yaml", monitoring), ("compose.dev-monitoring.yaml", monitoring)],
                                        env: [:], jsonFiles: { _ in [] }, mise: nil)
        #expect(found.map(\.composeFile) == ["compose.dev-monitoring.yaml"])
    }

    @Test func unpublishedGrafanaIsNotOffered() {
        let hidden = """
        services:
          grafana:
            image: grafana/grafana:12.0.0
            expose: ["3000"]
        """
        #expect(GrafanaSetup.detect(composeFiles: [("compose.yaml", hidden)], env: [:], jsonFiles: { _ in [] }, mise: nil).isEmpty)
    }

    @Test func composeFileNames() {
        #expect(GrafanaSetup.isComposeFile("compose.yaml"))
        #expect(GrafanaSetup.isComposeFile("docker-compose.dev.yml"))
        #expect(GrafanaSetup.isComposeFile("compose.dev-monitoring.yaml"))
        #expect(!GrafanaSetup.isComposeFile("composer.json"))
        #expect(!GrafanaSetup.isComposeFile("compose.yaml.bak"))
    }

    @Test func urlsKeepToThisGrafana() throws {
        let grafana = GrafanaSetup(composeFile: "compose.yaml", service: "grafana", port: 3000,
                                   dashboards: [.init(uid: "shop-api", title: "API", file: "api.json")], startCommand: "")
        #expect(grafana.url(for: grafana.dashboards[0], dark: false).absoluteString == "http://127.0.0.1:3000/d/shop-api?theme=light")
        #expect(grafana.url(for: grafana.dashboards[0], dark: true, focused: true).absoluteString == "http://127.0.0.1:3000/d/shop-api?theme=dark&kiosk")
        #expect(grafana.url(for: nil, dark: false).absoluteString == "http://127.0.0.1:3000/dashboards?theme=light")
        #expect(grafana.owns(try #require(URL(string: "http://localhost:3000/login"))))
        #expect(!grafana.owns(try #require(URL(string: "http://127.0.0.1:3001/"))))
        #expect(!grafana.owns(try #require(URL(string: "https://grafana.com/docs"))))
    }
}
