import Foundation

/// A container on this Mac, from `docker ps --all`: the ones a project's compose file runs,
/// and the ones started by hand (`docker run --name sp-pg postgres`), which the Env and Data
/// areas show too so a database or app run outside compose isn't invisible. Pure parsing;
/// `load` and `environment` ask Docker.
public struct DockerContainer: Equatable, Sendable, Identifiable {
    public struct Port: Equatable, Sendable {
        public var host: Int
        public var container: Int

        public init(host: Int, container: Int) {
            self.host = host
            self.container = container
        }
    }

    public var name: String
    public var image: String
    /// running, exited, created, paused, restarting, dead.
    public var state: String
    /// "Up 5 hours", "Exited (0) 29 hours ago".
    public var status: String
    public var ports: [Port]
    /// The compose project that made it, if one did.
    public var composeProject: String?
    public var id: String { name }

    public init(name: String, image: String, state: String, status: String = "", ports: [Port] = [], composeProject: String? = nil) {
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.ports = ports
        self.composeProject = composeProject
    }

    public var isRunning: Bool { state == "running" }

    /// The database it serves, from its image.
    public var engine: DatabaseEngine? {
        let base = (image.split(separator: "/").last.map(String.init) ?? image).split(separator: ":").first.map { $0.lowercased() } ?? ""
        if ["postgres", "postgis", "timescaledb", "timescaledb-ha", "pgvector", "supabase-postgres"].contains(where: { base == $0 || base.hasPrefix($0 + "-") }) { return .postgres }
        if ["mysql", "mariadb", "percona"].contains(where: { base == $0 || base.hasPrefix($0 + "-") }) { return .mysql }
        return nil
    }

    public func hostPort(for container: Int) -> Int? { ports.first { $0.container == container }?.host }

    /// Reads `docker ps --all --format '{{json .}}'`: one object per line.
    public static func parse(_ output: String) -> [DockerContainer] {
        output.split(separator: "\n").compactMap { line in
            guard let object = JSONValue(line: String(line)), let name = object["Names"]?.string?.split(separator: ",").first.map(String.init) else { return nil }
            let labels = (object["Labels"]?.string ?? "").split(separator: ",")
            let project = labels.first { $0.hasPrefix("com.docker.compose.project=") }.map { String($0.dropFirst("com.docker.compose.project=".count)) }
            return DockerContainer(name: name, image: object["Image"]?.string ?? "", state: object["State"]?.string ?? "",
                                   status: object["Status"]?.string ?? "", ports: ports(object["Ports"]?.string ?? ""), composeProject: project)
        }
    }

    /// "0.0.0.0:55432->5432/tcp, [::]:55432->5432/tcp" → 55432 for 5432, once.
    static func ports(_ text: String) -> [Port] {
        var found: [Port] = []
        for mapping in text.split(separator: ",") {
            let parts = mapping.trimmingCharacters(in: .whitespaces).components(separatedBy: "->")
            guard parts.count == 2, let host = parts[0].split(separator: ":").last.flatMap({ Int($0) }),
                  let container = parts[1].split(separator: "/").first.flatMap({ Int($0) }) else { continue }
            let port = Port(host: host, container: container)
            if !found.contains(port) { found.append(port) }
        }
        return found
    }

    /// Containers that look like this project's but aren't its compose services: named or
    /// built after it ("shop-portal:local"), or by its initials ("sp-pg"). Another compose
    /// project's containers never count.
    public static func related(_ containers: [DockerContainer], project: String) -> [DockerContainer] {
        containers.filter { $0.belonging(to: project) != nil }
    }

    /// Why this container is the project's ("built as shop-portal:local", "named sp-"), or nil
    /// when it isn't: compose's containers are shown with their services, and anything else
    /// on the Mac stays out.
    public func belonging(to project: String) -> String? {
        guard composeProject == nil else { return nil }
        let words = project.lowercased().split(whereSeparator: { "-_ .".contains($0) }).map(String.init)
        let compact = words.joined()
        guard compact.count >= 3 else { return nil }
        let squashed = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let imageName = image.split(separator: "/").last.map(String.init) ?? image
        if squashed(imageName.split(separator: ":").first.map(String.init) ?? "").contains(compact) { return "built as \(imageName)" }
        if squashed(name).contains(compact) { return "named for \(project)" }
        guard words.count > 1 else { return nil }
        let initials = String(words.compactMap(\.first)), lower = name.lowercased()
        if lower == initials { return "named \(initials)" }
        return ["-", "_", "."].first { lower.hasPrefix(initials + $0) }.map { "named \(initials)\($0)" }
    }

    /// A database container as a connection, from its environment (POSTGRES_USER…). The
    /// password is kept as a dev password: in memory, never saved.
    public func connection(environment: [String]) -> DatabaseConnection? {
        guard let engine else { return nil }
        var env: [String: String] = [:]
        for line in environment {
            guard let equals = line.firstIndex(of: "=") else { continue }
            env[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        guard let port = hostPort(for: engine == .postgres ? 5432 : 3306) else { return nil }
        let user: String, database: String, password: String?
        if engine == .postgres {
            user = env["POSTGRES_USER"].flatMap { $0.isEmpty ? nil : $0 } ?? "postgres"
            database = env["POSTGRES_DB"].flatMap { $0.isEmpty ? nil : $0 } ?? user
            password = env["POSTGRES_PASSWORD"]
        } else {
            let named = env["MYSQL_USER"] ?? env["MARIADB_USER"]
            user = named ?? "root"
            database = env["MYSQL_DATABASE"] ?? env["MARIADB_DATABASE"] ?? ""
            password = named != nil ? (env["MYSQL_PASSWORD"] ?? env["MARIADB_PASSWORD"]) : (env["MYSQL_ROOT_PASSWORD"] ?? env["MARIADB_ROOT_PASSWORD"])
        }
        var connection = DatabaseConnection(name: name, engine: engine, host: "localhost", port: port, database: database, user: user,
                                            origin: .detected, note: "Docker container \(name)", devPassword: password)
        connection.container = name
        return connection
    }

    // MARK: Docker

    /// Every container on this Mac, or nil when Docker isn't there or isn't running.
    public static func load() async -> [DockerContainer]? {
        guard Shell.which("docker") != nil else { return nil }
        let output = await Shell.run(["docker", "ps", "--all", "--no-trunc", "--format", "{{json .}}"], in: FileManager.default.homeDirectoryForCurrentUser)
        return output.succeeded ? parse(output.stdout) : nil
    }

    /// `{"5432/tcp":[{"HostIp":"","HostPort":"55432"}]}` from `.HostConfig.PortBindings`: the
    /// ports a container publishes when it runs, which `docker ps` leaves out while it's stopped.
    public static func bindings(_ json: String) -> [Port] {
        guard let object = JSONValue(line: json)?.object else { return [] }
        var found: [Port] = []
        for (key, value) in object.sorted(by: { $0.key < $1.key }) {
            guard let container = key.split(separator: "/").first.flatMap({ Int($0) }) else { continue }
            for binding in value.array ?? [] {
                guard let host = binding["HostPort"]?.string.flatMap({ Int($0) }) else { continue }
                let port = Port(host: host, container: container)
                if !found.contains(port) { found.append(port) }
            }
        }
        return found
    }

    /// The container with its environment, for connecting to the database in it, and its
    /// published ports even while it's stopped.
    public static func inspect(_ container: DockerContainer) async -> (container: DockerContainer, environment: [String]) {
        let output = await Shell.run(["docker", "inspect", "--format", "{{json .Config.Env}}\n{{json .HostConfig.PortBindings}}", container.name],
                                     in: FileManager.default.homeDirectoryForCurrentUser)
        guard output.succeeded else { return (container, []) }
        let lines = output.stdout.split(separator: "\n").map(String.init)
        var container = container
        if container.ports.isEmpty, lines.count > 1 { container.ports = bindings(lines[1]) }
        return (container, lines.first.flatMap { JSONValue(line: $0)?.array?.compactMap(\.string) } ?? [])
    }
}
