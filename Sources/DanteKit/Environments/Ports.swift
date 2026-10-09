import Darwin
import Foundation

/// A process listening on a port, with what it is and where it was started.
public struct PortHolder: Equatable, Sendable, Identifiable {
    public var listening: ListeningPort
    /// The full command line, from `ps`.
    public var commandLine: String
    /// Its working directory, from `lsof`.
    public var directory: String?
    /// How long it's been running, as `ps` prints it ("01:16:22", "2-03:00:00").
    public var elapsed: String?
    public var id: String { "\(listening.pid):\(listening.port)" }

    public init(listening: ListeningPort, commandLine: String = "", directory: String? = nil, elapsed: String? = nil) {
        self.listening = listening
        self.commandLine = commandLine
        self.directory = directory
        self.elapsed = elapsed
    }

    public var port: Int { listening.port }
    public var pid: Int32 { listening.pid }

    /// Started from inside the project, or running a program that lives there.
    public func belongs(to root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        func inside(_ path: String?) -> Bool {
            guard let path, !path.isEmpty else { return false }
            return path == base || path.hasPrefix(base + "/")
        }
        let program = commandLine.split(separator: " ").first.map(String.init)
        return inside(directory) || inside(program)
    }

    /// "notifications (pid 812, up 01:16:22)".
    public var summary: String {
        "\(listening.command) (pid \(pid)\(elapsed.map { ", up \($0)" } ?? ""))"
    }
}

/// Finds who holds a port and frees it.
public enum PortCheck {
    /// `ps -o pid=,etime=,command= -p …`.
    public static func parseProcesses(_ output: String) -> [Int32: (elapsed: String, command: String)] {
        var found: [Int32: (String, String)] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]) else { continue }
            found[pid] = (String(fields[1]), String(fields[2]))
        }
        return found
    }

    /// `lsof -a -d cwd -p … -Fpn`: `p<pid>` then `n<path>`.
    public static func parseDirectories(_ output: String) -> [Int32: String] {
        var found: [Int32: String] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst())
            case "n": if let pid { found[pid] = String(line.dropFirst()) }
            default: continue
            }
        }
        return found
    }

    /// Details for each port that isn't Docker's own.
    public static func holders(_ ports: [ListeningPort]) async -> [PortHolder] {
        let ports = ports.filter { !$0.isDocker }
        guard !ports.isEmpty else { return [] }
        let pids = Set(ports.map(\.pid)).sorted().map(String.init).joined(separator: ",")
        let temp = FileManager.default.temporaryDirectory
        async let ps = Shell.run(["ps", "-o", "pid=,etime=,command=", "-p", pids], in: temp)
        async let lsof = Shell.run(["lsof", "-a", "-d", "cwd", "-p", pids, "-Fpn"], in: temp)
        let processes = parseProcesses(await ps.stdout)
        let directories = parseDirectories(await lsof.stdout)
        return ports.map { port in
            PortHolder(listening: port, commandLine: processes[port.pid]?.command ?? port.command,
                       directory: directories[port.pid], elapsed: processes[port.pid]?.elapsed)
        }
    }

    /// Asks a process to quit (SIGTERM) and waits up to `timeout` for the port to free up.
    /// Nil when it's gone, else why not.
    public static func stop(_ holder: PortHolder, timeout: Duration = .seconds(4)) async -> String? {
        guard kill(holder.pid, SIGTERM) == 0 else {
            return errno == EPERM
                ? "\(holder.listening.command) belongs to another user; Dante can’t stop it."
                : "Couldn’t stop \(holder.listening.command): \(String(cString: strerror(errno)))."
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if PortProbe.isFree(holder.port), kill(holder.pid, 0) != 0 { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return PortProbe.isFree(holder.port) ? nil : "\(holder.listening.command) didn’t quit; port \(holder.port) is still in use."
    }
}

/// A published port of a compose service that something else already holds.
public struct PortConflict: Equatable, Sendable, Identifiable {
    public var service: String
    public var holder: PortHolder
    public var id: String { "\(service):\(holder.port)" }

    public init(service: String, holder: PortHolder) {
        self.service = service
        self.holder = holder
    }

    public var port: Int { holder.port }

    /// The services that aren't running and want a port a non-Docker process holds.
    public static func find(services: [ComposeFile.Service], containers: [ContainerState], holders: [PortHolder]) -> [PortConflict] {
        services.flatMap { service -> [PortConflict] in
            guard containers.first(where: { $0.service == service.name })?.state != "running" else { return [] }
            return service.publishedPorts.compactMap { port in
                holders.first { $0.port == port && !$0.listening.isDocker }.map { PortConflict(service: service.name, holder: $0) }
            }
        }
    }
}

extension ComposeEditing {
    /// Publishes a service's port on another host port, leaving the container port and the
    /// rest of the file alone: `"3000:3000"` becomes `"3001:3000"`. Nil when the mapping
    /// isn't there.
    public static func republishing(service: String, port: Int, to newPort: Int, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "\(service):" && line.hasPrefix(" ")
        }) else { return nil }
        let indent = lines[header].prefix { $0 == " " }.count
        let pattern = try! NSRegularExpression(pattern: #"^(\s*-\s*["']?(?:[0-9.]+:)?)\#(port)(:\d+)"#)
        var index = header + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), line.prefix(while: { $0 == " " }).count <= indent { break }
            let range = NSRange(line.startIndex..., in: line)
            if let match = pattern.firstMatch(in: line, range: range) {
                lines[index] = pattern.replacementString(for: match, in: line, offset: 0, template: "$1\(newPort)$2")
                    + line[Range(match.range, in: line)!.upperBound...]
                return lines.joined(separator: "\n")
            }
            index += 1
        }
        return nil
    }
}
