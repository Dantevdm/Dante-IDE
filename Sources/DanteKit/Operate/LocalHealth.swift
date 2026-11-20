import Foundation

/// Health on this Mac: the project's own compose services, checked on their published ports.
/// Each service built from the repo gets a check on its health route (found in its code), and
/// the logs come from `docker compose logs`. Pure; `read` returns a file's text.
public enum LocalHealth {
    /// Health routes, most specific first. The first one a service's code names is checked.
    public static let routes = ["/actuator/health", "/api/healthz", "/api/health", "/healthz", "/health", "/livez", "/readyz", "/ready", "/ping", "/status"]

    /// A check per compose service that builds from the repo and publishes a port.
    public static func checks(compose: ComposeFile, files: [String], read: (String) -> String?) -> [ProjectInfo.HealthCheck] {
        compose.services.compactMap { service in
            guard let context = service.build, let port = service.publishedPorts.first else { return nil }
            let folder = context.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            let code = files.filter { file in
                (folder.isEmpty || file.hasPrefix(folder + "/")) && !SystemMap.isTest(file)
                    && (SystemMap.isCode(file) || ["pom.xml", "build.gradle", "build.gradle.kts"].contains((file as NSString).lastPathComponent))
            }
            let path = route(in: code, read: read) ?? "/"
            guard let url = URL(string: "http://localhost:\(port)\(path)") else { return nil }
            return ProjectInfo.HealthCheck(name: service.name, url: url)
        }
    }

    /// The health route the code serves: a quoted path (`"/health"`, `'/healthz'`), or Spring
    /// Boot's actuator when the build pulls it in.
    static func route(in files: [String], read: (String) -> String?) -> String? {
        var found: Set<String> = []
        for file in files {
            guard let text = read(file) else { continue }
            if text.contains("spring-boot-starter-actuator") { found.insert("/actuator/health") }
            for route in routes where text.contains("\"\(route)\"") || text.contains("'\(route)'") || text.contains("`\(route)`") {
                found.insert(route)
            }
        }
        return routes.first { found.contains($0) }
    }

    /// Follows the services' logs from now on (the last 200 lines first).
    public static func logsCommand(compose: ComposeFile, services: [String]? = nil) -> String {
        let names = (services ?? []).map(Shell.quote).joined(separator: " ")
        return "docker compose -f \(Shell.quote(compose.url.lastPathComponent)) logs -f --no-color --tail 200" + (names.isEmpty ? "" : " " + names)
    }
}
