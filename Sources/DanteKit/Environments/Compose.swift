import Foundation
import Yams

/// A project's Docker Compose file and the state of its containers, for the Env area.
public struct ComposeFile: Equatable, Sendable {
    public struct Service: Equatable, Sendable, Identifiable {
        public var name: String
        public var image: String?
        /// The build context, when the service is built from the repo.
        public var build: String?
        public var ports: [String]
        public var dependsOn: [String]
        public var profiles: [String]
        /// `environment:`, from either the map or the KEY=VALUE list form.
        public var environment: [String: String]
        public var id: String { name }

        public init(name: String, image: String? = nil, build: String? = nil, ports: [String] = [], dependsOn: [String] = [], profiles: [String] = [], environment: [String: String] = [:]) {
            self.name = name
            self.environment = environment
            self.image = image
            self.build = build
            self.ports = ports
            self.dependsOn = dependsOn
            self.profiles = profiles
        }

        /// The image, or what it's built from.
        public var source: String { image ?? build.map { "build \($0)" } ?? "—" }
    }

    public var url: URL
    public var services: [Service]
    public var parseError: String?

    public static let fileNames = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]

    public static func find(in root: URL) -> URL? {
        fileNames.lazy.map { root.appending(path: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func load(projectRoot: URL) -> ComposeFile? {
        guard let url = find(in: projectRoot) else { return nil }
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else {
            return ComposeFile(url: url, services: [], parseError: "Couldn’t read \(url.lastPathComponent).")
        }
        do {
            return ComposeFile(url: url, services: try parse(yaml))
        } catch {
            return ComposeFile(url: url, services: [], parseError: "\(url.lastPathComponent) isn’t valid YAML: \(error.localizedDescription)")
        }
    }

    public static func parse(_ yaml: String) throws -> [Service] {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any],
              let services = root["services"] as? [String: Any] else { return [] }
        return services.keys.sorted().map { name in
            let spec = services[name] as? [String: Any] ?? [:]
            var build: String?
            if let context = spec["build"] as? String {
                build = context
            } else if let object = spec["build"] as? [String: Any] {
                build = (object["context"] as? String) ?? "."
            }
            let ports = (spec["ports"] as? [Any] ?? []).map { port -> String in
                if let object = port as? [String: Any] {
                    let published = object["published"].map { "\($0)" }
                    let target = object["target"].map { "\($0)" } ?? ""
                    return published.map { "\($0):\(target)" } ?? target
                }
                return "\(port)"
            }
            var dependsOn: [String] = []
            if let list = spec["depends_on"] as? [Any] {
                dependsOn = list.map { "\($0)" }
            } else if let map = spec["depends_on"] as? [String: Any] {
                dependsOn = map.keys.sorted()
            }
            var environment: [String: String] = [:]
            if let map = spec["environment"] as? [String: Any] {
                for (key, value) in map { environment[key] = (value is NSNull) ? "" : "\(value)" }
            } else if let list = spec["environment"] as? [Any] {
                for entry in list.map({ "\($0)" }) {
                    let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                    if let key = parts.first { environment[key] = parts.count > 1 ? parts[1] : "" }
                }
            }
            return Service(
                name: name,
                image: spec["image"] as? String,
                build: build,
                ports: ports,
                dependsOn: dependsOn,
                profiles: (spec["profiles"] as? [Any] ?? []).map { "\($0)" },
                environment: environment
            )
        }
    }
}

/// One container from `docker compose ps`.
public struct ContainerState: Equatable, Sendable, Identifiable {
    public var service: String
    /// running, exited, restarting, paused, created, dead.
    public var state: String
    /// healthy, unhealthy, starting, or empty.
    public var health: String
    /// Docker's own summary, like "Up 3 hours" or "Exited (1) 2 minutes ago".
    public var status: String
    public var ports: [String]
    public var id: String { service }

    public init(service: String, state: String, health: String = "", status: String = "", ports: [String] = []) {
        self.service = service
        self.state = state
        self.health = health
        self.status = status
        self.ports = ports
    }

    public var isUp: Bool { state == "running" && health != "unhealthy" }

    /// What to show: health when Docker tracks it, else the state.
    public var label: String { health.isEmpty ? state : health }

    /// Reads `docker compose ps --format json`, which is a JSON array in older Compose
    /// releases and one object per line in newer ones.
    public static func parse(_ output: String) -> [ContainerState] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var objects: [JSONValue] = []
        if trimmed.hasPrefix("["), let array = JSONValue(line: trimmed)?.array {
            objects = array
        } else {
            objects = trimmed.split(separator: "\n").compactMap { JSONValue(line: String($0)) }
        }
        return objects.compactMap { object in
            guard let service = object["Service"]?.string else { return nil }
            var ports: [String] = []
            for publisher in object["Publishers"]?.array ?? [] {
                if let published = publisher["PublishedPort"]?.int, published > 0 {
                    let port = ":\(published)"
                    if !ports.contains(port) { ports.append(port) }
                }
            }
            return ContainerState(
                service: service,
                state: object["State"]?.string ?? "unknown",
                health: object["Health"]?.string ?? "",
                status: object["Status"]?.string ?? "",
                ports: ports
            )
        }
    }

    /// The containers for a project, or nil when Docker isn't available or not running.
    public static func load(projectRoot: URL) async -> Result<[ContainerState], DockerUnavailable> {
        guard Shell.which("docker") != nil else { return .failure(.notInstalled) }
        let output = await Shell.run(["docker", "compose", "ps", "--all", "--format", "json"], in: projectRoot)
        guard output.succeeded else {
            let message = output.message
            if message.contains("Cannot connect") || message.contains("daemon") || message.contains("docker.sock") {
                return .failure(.notRunning)
            }
            return .failure(.failed(message))
        }
        return .success(parse(output.stdout))
    }
}

public enum DockerUnavailable: Error, Equatable, Sendable {
    case notInstalled, notRunning
    case failed(String)

    public var message: String {
        switch self {
        case .notInstalled: "Docker isn’t installed. Install Docker Desktop or OrbStack to run this project’s services here."
        case .notRunning: "Docker isn’t running. Start Docker Desktop or OrbStack, then refresh."
        case .failed(let output): output
        }
    }
}
