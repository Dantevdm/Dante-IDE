import Foundation

/// Where a running compose service opens: a database in Data's explorer, anything published on
/// a port that serves pages in the browser, and nothing for caches, queues and brokers.
public enum ServiceOpening: Equatable, Sendable {
    case data
    case browser(URL)

    /// Engines Data can browse.
    static let databases = ["postgres", "postgis", "timescale", "mysql", "mariadb", "mongo", "mssql", "sqlserver", "azure-sql-edge", "cockroach"]
    /// Services that listen on a port but don't serve pages there.
    static let notWeb = ["redis", "valkey", "memcached", "kafka", "zookeeper", "nats", "rabbitmq", "localstack", "mailhog-smtp", "otel", "jaeger-agent"]
    /// Admin consoles some of those publish beside their own port.
    static let consoles: [String: Int] = ["rabbitmq": 15672, "minio": 9001, "mailhog": 8025, "mailpit": 8025, "jaeger": 16686, "kafka-ui": 8080]

    /// `ports` are the published ones (`:4317`), as `ContainerState` keeps them.
    public static func target(service: ComposeFile.Service, ports: [String]) -> ServiceOpening? {
        let what = (service.image ?? service.name).lowercased()
        if databases.contains(where: { what.contains($0) }) { return .data }
        let published = ports.compactMap { Int($0.split(separator: ":").last ?? "") }
        guard !published.isEmpty else { return nil }
        if let console = consoles.first(where: { what.contains($0.key) }) {
            return published.contains(console.value) ? url(console.value) : nil
        }
        if notWeb.contains(where: { what.contains($0) }) { return nil }
        // Several ports: the one most likely to serve pages.
        let web = [80, 3000, 5173, 4200, 8080, 8000, 5000, 4321, 8081, 443]
        return url(published.first(where: web.contains) ?? published[0])
    }

    static func url(_ port: Int) -> ServiceOpening {
        .browser(URL(string: port == 443 ? "https://localhost" : "http://localhost:\(port)")!)
    }
}
