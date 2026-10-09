import Foundation

/// A TCP port something on this Mac is listening on, from `lsof`.
public struct ListeningPort: Equatable, Sendable {
    public var port: Int
    public var pid: Int32
    public var command: String

    public init(port: Int, pid: Int32, command: String) {
        self.port = port
        self.pid = pid
        self.command = command
    }

    /// Docker Desktop, OrbStack and friends hold published ports for running containers.
    public var isDocker: Bool {
        let name = command.lowercased()
        return ["com.docker", "docker", "vpnkit", "orbstack", "colima", "limactl", "podman", "rancher"].contains { name.contains($0) }
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN -F pcn`: `p<pid>`, `c<command>`, then `n<address>:<port>`
    /// for each socket.
    public static func parse(_ output: String) -> [ListeningPort] {
        var found: [ListeningPort] = []
        var pid: Int32 = 0
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let port = value.split(separator: ":").last.flatMap({ Int($0) }),
                      !found.contains(where: { $0.port == port && $0.pid == pid }) else { continue }
                found.append(ListeningPort(port: port, pid: pid, command: command))
            default: continue
            }
        }
        return found
    }

    public static func load() async -> [ListeningPort] {
        let output = await Shell.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], in: FileManager.default.temporaryDirectory)
        return parse(output.stdout)
    }
}

/// Why a compose service isn't up, in words: waiting on an unhealthy dependency, a port
/// already taken on this Mac, a failing health check.
public enum ComposeDiagnosis {
    /// One note per service that needs one, by service name. `healthOutput` is the last
    /// health check's output for unhealthy containers, by service name.
    public static func notes(
        services: [ComposeFile.Service],
        containers: [ContainerState],
        listening: [ListeningPort],
        healthOutput: [String: String] = [:]
    ) -> [String: String] {
        var notes: [String: String] = [:]
        func container(_ name: String) -> ContainerState? { containers.first { $0.service == name } }
        for service in services {
            let state = container(service.name)
            if state?.health == "unhealthy" {
                notes[service.name] = healthOutput[service.name].map { "Its health check fails: \($0)" }
                    ?? "Its health check fails."
                continue
            }
            guard state?.state != "running" else { continue }
            let taken = service.publishedPorts.compactMap { port in
                listening.first { $0.port == port && !$0.isDocker }
            }
            if let taken = taken.first {
                notes[service.name] = "Port \(taken.port) is already in use by \(taken.command) (pid \(taken.pid)). Stop it, or publish the service on another port."
                continue
            }
            if state?.state == "created" {
                let blocking = service.dependsOn.compactMap { name -> String? in
                    guard let dependency = container(name) else { return "\(name), which hasn’t been created" }
                    if dependency.health == "unhealthy" { return "\(name), which is unhealthy" }
                    if dependency.health == "starting" { return "\(name), whose health check hasn’t passed yet" }
                    if dependency.state != "running" { return "\(name), which is \(dependency.state)" }
                    return nil
                }
                notes[service.name] = blocking.isEmpty
                    ? "Created but never started."
                    : "Hasn’t started: it waits for \(blocking.joined(separator: " and "))."
            }
        }
        return notes
    }

    /// The last failing check from `docker inspect --format '{{json .State.Health}}'`.
    public static func lastHealthFailure(_ json: String) -> String? {
        guard let log = JSONValue(line: json.trimmingCharacters(in: .whitespacesAndNewlines))?["Log"]?.array,
              let last = log.last(where: { ($0["ExitCode"]?.int ?? 0) != 0 }),
              let output = last["Output"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else { return nil }
        // OCI errors are long; the part after the last "exec: " says what was missing.
        if let range = output.range(of: "exec: ", options: .backwards) {
            return String(output[range.upperBound...]).replacingOccurrences(of: ": unknown", with: "")
        }
        return output.count > 300 ? String(output.prefix(300)) + "…" : output
    }

    public static func lastHealthFailure(container: String, in root: URL) async -> String? {
        let output = await Shell.run(["docker", "inspect", "--format", "{{json .State.Health}}", container], in: root)
        return output.succeeded ? lastHealthFailure(output.stdout) : nil
    }
}

extension ComposeFile.Service {
    /// Host ports from `ports:`, like 3000 in "3000:3000" or "127.0.0.1:5432:5432".
    /// A bare container port gets a random host port, so it can't clash.
    public var publishedPorts: [Int] {
        ports.compactMap { entry in
            let parts = entry.split(separator: "/").first.map { $0.split(separator: ":") } ?? []
            guard parts.count >= 2 else { return nil }
            let published = parts[parts.count - 2]
            return Int(published.split(separator: "-").first ?? published)
        }
    }
}
