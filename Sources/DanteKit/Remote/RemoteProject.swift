import Foundation

/// A project on another machine, worked on through a local mirror: files are synced with
/// rsync (`RemoteSync`), and commands (git, tests, Claude Code, the terminal) run on the
/// host over ssh. Everything that only reads files works on the mirror unchanged.
public struct RemoteProject: Codable, Hashable, Sendable {
    /// An ssh destination: a `Host` alias from `~/.ssh/config` or `user@host`.
    public var host: String
    /// The project folder on the host, absolute.
    public var path: String
    /// The local mirror folder.
    public var mirror: String

    public init(host: String, path: String, mirror: String) {
        self.host = host
        self.path = Self.trimmed(path)
        self.mirror = Self.trimmed(mirror)
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var label: String { "\(host):\(path)" }
    public var mirrorURL: URL { URL(filePath: mirror, directoryHint: .isDirectory) }

    /// Where a host's folder is mirrored: a folder named like the project (which names the
    /// window), inside one per host and a short hash of the full path, so two `app` folders
    /// don't collide.
    public static func mirrorFolder(host: String, path: String, in base: URL) -> URL {
        let safeHost = String(host.map { $0.isLetter || $0.isNumber || "-._".contains($0) ? $0 : "_" })
        let name = (trimmed(path) as NSString).lastPathComponent
        return base.appending(path: safeHost).appending(path: shortHash(trimmed(path))).appending(path: name.isEmpty ? "root" : name)
    }

    /// `~/Library/Application Support/Dante/Remote`: not a cache, so macOS never clears it
    /// while a project is open.
    public static var mirrorsBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Dante/Remote")
    }

    /// The host's path for a local file or folder inside the mirror.
    public func remotePath(forLocal local: String) -> String? {
        guard let relative = Self.relative(local, under: mirror) else { return nil }
        return relative.isEmpty ? path : path + "/" + relative
    }

    /// The mirror's path for a path Claude Code or a tool reported on the host.
    public func localPath(forRemote remote: String) -> String? {
        guard let relative = Self.relative(remote, under: path) else { return nil }
        return relative.isEmpty ? mirror : mirror + "/" + relative
    }

    static func relative(_ path: String, under root: String) -> String? {
        let path = trimmed(path)
        if path == root { return "" }
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    static func trimmed(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// FNV-1a: stable across launches, unlike `hashValue`.
    static func shortHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(String(hash, radix: 16).suffix(8))
    }
}

// MARK: - ssh

/// Command lines for the host. Every connection uses `BatchMode`, so ssh never asks for a
/// password: keys and the ssh agent work, anything else fails with a message to act on.
public enum SSH {
    /// `DANTE_SSH` swaps in another ssh program; the tests use one that runs commands locally.
    public static var program: String { ProcessInfo.processInfo.environment["DANTE_SSH"] ?? "/usr/bin/ssh" }

    /// Sockets for shared connections. Short and without spaces: a socket path is limited to
    /// about 100 bytes, and rsync splits its `-e` command on spaces.
    public static var controlFolder: String { "/tmp/dante-ssh-\(getuid())" }

    /// Options for every connection. Commands reuse the window's shared connection when it's
    /// up (`ControlMaster=no` never makes them the master, whose output pipe would stay open).
    public static func options(master: Bool = false, terminal: Bool = false) -> [String] {
        var options = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-o", "ControlPath=\(controlFolder)/%C",
            "-o", master ? "ControlMaster=yes" : "ControlMaster=no",
        ]
        if master { options += ["-o", "ControlPersist=600", "-N", "-f"] }
        options.append(terminal ? "-t" : "-T")
        return options
    }

    /// The command line the host runs: the user's login shell (so PATH matches their own
    /// sessions), in `directory`, with `environment` set for the command only.
    public static func remoteCommand(_ arguments: [String], in directory: String, environment: [String: String] = [:]) -> String {
        var inner = "cd \(Shell.quote(directory)) && exec "
        if !environment.isEmpty {
            inner += "env " + environment.sorted { $0.key < $1.key }.map { Shell.quote("\($0.key)=\($0.value)") }.joined(separator: " ") + " "
        }
        inner += arguments.map(Shell.quote).joined(separator: " ")
        return "exec \"$SHELL\" -lc \(Shell.quote(inner))"
    }

    /// Full arguments for ssh: options, the host, then the command.
    public static func arguments(host: String, command: String, terminal: Bool = false) -> [String] {
        options(terminal: terminal) + [host, command]
    }

    /// Starts the shared connection to a host unless one is up. Returns nil when connected,
    /// else what went wrong. The master runs in the background for ten idle minutes; its
    /// output goes to a file, not a pipe, since a pipe would stay open as long as it runs.
    public static func connect(host: String) async -> String? {
        try? FileManager.default.createDirectory(atPath: controlFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if await runDetached(["-o", "ControlPath=\(controlFolder)/%C", "-O", "check", host]).status == 0 { return nil }
        let result = await runDetached(options(master: true) + [host])
        guard result.status != 0 else { return nil }
        return RemoteSync.explain(Shell.Output(status: result.status, stdout: "", stderr: result.errors), host: host)
    }

    private static func runDetached(_ arguments: [String]) async -> (status: Int32, errors: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let log = FileManager.default.temporaryDirectory.appending(path: "dante-ssh-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: log.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: log) }
                let process = Process()
                process.executableURL = URL(filePath: program)
                process.arguments = arguments
                process.environment = Shell.environment()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = try? FileHandle(forWritingTo: log)
                do { try process.run() } catch {
                    continuation.resume(returning: (127, error.localizedDescription))
                    return
                }
                process.waitUntilExit()
                let errors = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: (process.terminationStatus, errors))
            }
        }
    }

    /// rsync's `-e`: ssh and its options as one line.
    public static var rsyncShell: String {
        ([program] + options()).joined(separator: " ")
    }
}

// MARK: - Registry

/// The remote projects open in this app, by mirror folder. `Shell` looks here to send a
/// command for a mirror folder to its host instead.
public enum RemoteRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var open: [String: RemoteProject] = [:]
    nonisolated(unsafe) private static var listeners: [String: @Sendable () -> Void] = [:]

    /// `afterCommand` runs (on any thread) when a command for the project finishes on the
    /// host, since it may have changed files there.
    public static func register(_ project: RemoteProject, afterCommand: @escaping @Sendable () -> Void) {
        lock.withLock {
            open[project.mirror] = project
            listeners[project.mirror] = afterCommand
        }
    }

    public static func unregister(mirror: String) {
        lock.withLock {
            open[RemoteProject.trimmed(mirror)] = nil
            listeners[RemoteProject.trimmed(mirror)] = nil
            hostServers[RemoteProject.trimmed(mirror)] = nil
        }
    }

    /// The open remote project a local folder belongs to, and that folder's path on the host.
    public static func project(containing directory: URL) -> (project: RemoteProject, path: String)? {
        let local = directory.standardizedFileURL.path
        return lock.withLock {
            for project in open.values {
                if let remote = project.remotePath(forLocal: local) { return (project, remote) }
            }
            return nil
        }
    }

    nonisolated(unsafe) private static var hostServers: [String: [String: [String]]] = [:]

    /// Language servers found on a project's host, by name, with the command to start each.
    /// Nil until the host has been asked.
    public static func hostServers(for project: RemoteProject) -> [String: [String]]? {
        lock.withLock { hostServers[project.mirror] }
    }

    public static func setHostServers(_ servers: [String: [String]], for project: RemoteProject) {
        lock.withLock { hostServers[project.mirror] = servers }
    }

    static func commandFinished(for project: RemoteProject) {
        let listener = lock.withLock { listeners[project.mirror] }
        listener?()
    }

    // MARK: Known mirrors, remembered on this Mac

    private static let knownKey = "remoteProjects"

    /// Every remote project opened on this Mac, newest first.
    public static func known(defaults: UserDefaults = .standard) -> [RemoteProject] {
        guard let data = defaults.data(forKey: knownKey) else { return [] }
        return (try? JSONDecoder().decode([RemoteProject].self, from: data)) ?? []
    }

    /// The remote project a local folder mirrors, if it's one.
    public static func known(mirror: URL, defaults: UserDefaults = .standard) -> RemoteProject? {
        let path = mirror.standardizedFileURL.path
        return known(defaults: defaults).first { $0.mirror == RemoteProject.trimmed(path) }
    }

    public static func remember(_ project: RemoteProject, defaults: UserDefaults = .standard) {
        let list = [project] + known(defaults: defaults).filter { $0.mirror != project.mirror }
        if let data = try? JSONEncoder().encode(Array(list.prefix(20))) { defaults.set(data, forKey: knownKey) }
    }
}

// MARK: - ~/.ssh/config

public enum SSHConfig {
    /// `Host` aliases a person can type, without wildcards, in file order.
    public static func hosts(in text: String) -> [String] {
        var hosts: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard words.count > 1, words[0].lowercased() == "host" else { continue }
            for alias in words.dropFirst() where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") && !hosts.contains(alias) {
                hosts.append(alias)
            }
        }
        return hosts
    }

    public static func hosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config")
        return hosts(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }
}
