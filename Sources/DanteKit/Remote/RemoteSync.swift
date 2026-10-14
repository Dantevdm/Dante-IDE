import Foundation
import Observation

/// Keeps a remote project's mirror and the host in step with rsync over the shared ssh
/// connection. Each sync:
///
/// 1. deletes on the host the files deleted here since the last sync (`rm`, and `rmdir` for
///    empty folders), unless there are so many it looks like an accident;
/// 2. asks rsync (a dry run) what the host no longer has, and removes those here, but only
///    files that existed at the last sync and haven't changed here since: a file made or
///    edited here in the meantime is kept, and goes across next;
/// 3. pushes the files made or changed here since the last sync (and only those, so a stale
///    copy never overwrites the host's; `-u` keeps the host's when it's newer still);
/// 4. pulls what changed there.
///
/// The files and their modification times after each sync are saved beside the mirror, so
/// the next launch knows what changed while Dante was closed. When both sides changed a
/// file, the newer wins.
@MainActor @Observable
public final class RemoteSync {
    public enum State: Equatable, Sendable {
        case idle
        case syncing
        case failed(String)
    }

    public let project: RemoteProject
    public private(set) var state: State = .idle
    public private(set) var lastSynced: Date?
    /// Local deletions not sent, because there were too many at once to be someone's doing.
    public private(set) var heldDeletions = 0

    /// Relative path to modification time (folders end in "/") after the last sync.
    @ObservationIgnored private var snapshot: [String: Double]?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?

    /// The host's published ports, forwarded to the same ports here.
    public private(set) var forwarded: Set<Int> = []
    /// Ports that couldn't be forwarded (taken on this Mac, mostly), with ssh's reason.
    public private(set) var unforwarded: [Int: String] = [:]

    public init(project: RemoteProject) {
        self.project = project
        snapshot = Self.loadSnapshot(for: project)
    }

    // MARK: Scheduling

    /// Syncs soon; requests made meanwhile are gathered into one sync.
    public func request(after delay: Duration = .milliseconds(400)) {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            pending = nil
            await sync()
        }
    }

    /// Syncs on a timer, more often while Dante is in front.
    public func startPolling(interval: @escaping @MainActor () -> Duration) {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self.map({ _ in interval() }) else { return }
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled else { return }
                await sync()
            }
        }
    }

    public func stop() {
        polling?.cancel()
        pending?.cancel()
        polling = nil
        pending = nil
        let ports = forwarded, host = project.host
        forwarded = []
        // The shared connection outlives the window by a few minutes; its forwards shouldn't.
        if !ports.isEmpty { Task.detached { for port in ports { await SSH.forward(port, host: host, cancel: true) } } }
    }

    // MARK: Ports

    /// Forwards the ports not yet forwarded or tried, so `localhost:<port>` on this Mac reaches
    /// the host's service: browsers, health checks, database tools.
    public func forward(_ ports: Set<Int>) async {
        for port in ports.subtracting(forwarded).subtracting(unforwarded.keys).sorted() {
            if let problem = await SSH.forward(port, host: project.host) {
                unforwarded[port] = problem
            } else {
                forwarded.insert(port)
            }
        }
    }

    // MARK: Syncing

    public func sync() async {
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            state = .syncing
            do {
                try await performSync()
                lastSynced = Date()
                state = .idle
            } catch {
                state = .failed((error as? Failure)?.message ?? error.localizedDescription)
            }
        } while again
    }

    /// The first copy of the project: the host's files, deleting anything else in the mirror.
    public func pullAll() async throws {
        state = .syncing
        do {
            try FileManager.default.createDirectory(at: project.mirrorURL, withIntermediateDirectories: true)
            try await run(Self.rsyncArguments(for: project, direction: .pull, deleting: true))
            snapshot = Self.listing(project.mirrorURL)
            saveSnapshot()
            lastSynced = Date()
            state = .idle
        } catch {
            state = .failed((error as? Failure)?.message ?? error.localizedDescription)
            throw error
        }
    }

    private func performSync() async throws {
        let mirror = project.mirrorURL
        guard FileManager.default.fileExists(atPath: mirror.path) else {
            // Without the mirror there's nothing to compare, so start again from the host.
            snapshot = nil
            try await pullAll()
            return
        }
        let before = Self.listing(mirror)

        if let snapshot {
            let gone = Set(snapshot.keys).subtracting(before.keys)
            if gone.count > Self.deletionLimit(snapshotCount: snapshot.count) {
                heldDeletions = gone.count { !$0.hasSuffix("/") }
            } else if !gone.isEmpty {
                heldDeletions = 0
                try await deleteOnHost(gone)
            }
        }

        let deletedThere = Self.deletions(in: try await run(Self.rsyncArguments(for: project, direction: .pull, deleting: true, dryRun: true)))
        Self.remove(Self.removable(deletedThere, before: before, snapshot: snapshot), in: mirror)

        let changedHere = Self.changed(before, since: snapshot)
        if !changedHere.isEmpty {
            let list = FileManager.default.temporaryDirectory.appending(path: "dante-push-\(UUID().uuidString).txt")
            try changedHere.sorted().joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: list) }
            try await run(Self.rsyncArguments(for: project, direction: .push, filesFrom: list.path))
        }
        try await run(Self.rsyncArguments(for: project, direction: .pull))
        snapshot = Self.listing(mirror)
        saveSnapshot()
    }

    private func deleteOnHost(_ paths: Set<String>) async throws {
        let safe = paths.filter(Self.isSafeRelative)
        let files = safe.filter { !$0.hasSuffix("/") }.sorted()
        let folders = safe.filter { $0.hasSuffix("/") }.sorted { $0.count > $1.count }
        for chunk in stride(from: 0, to: files.count, by: 200).map({ Array(files[$0..<min($0 + 200, files.count)]) }) {
            try await runOnHost("rm -f -- " + chunk.map(Shell.quote).joined(separator: " "))
        }
        if !folders.isEmpty {
            // rmdir only removes empty folders, so a folder that gained files there survives.
            try await runOnHost("rmdir -- " + folders.map(Shell.quote).joined(separator: " ") + " 2>/dev/null; true")
        }
    }

    private func runOnHost(_ script: String) async throws {
        let command = SSH.remoteCommand(["sh", "-c", script], in: project.path)
        try await run([SSH.program] + SSH.arguments(host: project.host, command: command))
    }

    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        let output = await Shell.run(arguments, in: FileManager.default.homeDirectoryForCurrentUser)
        guard output.succeeded else { throw Failure(message: Self.explain(output, host: project.host)) }
        return output.stdout
    }

    public struct Failure: LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Checks that a folder exists on a host and that the host has rsync. Nil when it's fine.
    public nonisolated static func check(host: String, path: String) async -> String? {
        let script = "command -v rsync >/dev/null 2>&1 || echo DANTE_NO_RSYNC"
        let command = SSH.remoteCommand(["sh", "-c", script], in: path)
        let output = await Shell.run([SSH.program] + SSH.arguments(host: host, command: command), in: FileManager.default.homeDirectoryForCurrentUser)
        if output.stdout.contains("DANTE_NO_RSYNC") {
            return "\(host) needs rsync to sync files. Install it there (apt install rsync, or dnf install rsync)."
        }
        guard !output.succeeded else { return nil }
        let lower = output.stderr.lowercased()
        if lower.contains("no such file") || lower.contains("can't cd") || lower.contains("not a directory") {
            return "There’s no folder \(path) on \(host)."
        }
        return explain(output, host: host)
    }

    // MARK: Pure parts

    enum Direction: Sendable { case push, pull }

    /// Folders never synced: dependencies and build output, which the host rebuilds itself.
    nonisolated static let skippedFolders = [
        "node_modules", ".build", "DerivedData", ".swiftpm", "__pycache__", ".venv", "venv", ".pytest_cache", ".mypy_cache",
        ".next", ".turbo", "build", "dist", "target", "Pods", ".gradle", ".idea", "vendor", ".hg", ".svn",
    ]

    nonisolated static func filters(_ direction: Direction) -> [String] {
        // Only .git/HEAD comes across, so the branch shows without copying the repository.
        let git = direction == .pull ? ["--include=/.git/", "--include=/.git/HEAD", "--exclude=/.git/*"] : ["--exclude=/.git/"]
        return git + skippedFolders.map { "--exclude=\($0)/" } + ["--exclude=.DS_Store", "--max-size=20m"]
    }

    nonisolated static func rsyncArguments(for project: RemoteProject, direction: Direction, deleting: Bool = false, dryRun: Bool = false,
                                           filesFrom: String? = nil) -> [String] {
        var arguments = ["rsync", "-az", "-u"]
        if let filesFrom { arguments.append("--files-from=\(filesFrom)") }
        if deleting { arguments.append("--delete") }
        if dryRun { arguments += ["--dry-run", "--itemize-changes"] }
        arguments += filters(direction)
        arguments += ["-e", SSH.rsyncShell]
        // The host's shell reads the path, so it's quoted for it.
        let remote = "\(project.host):\(Shell.quote(project.path + "/"))"
        let local = project.mirror + "/"
        arguments += direction == .pull ? [remote, local] : [local, remote]
        return arguments
    }

    /// Paths from `*deleting` lines; folders keep their trailing slash.
    nonisolated static func deletions(in itemized: String) -> Set<String> {
        Set(itemized.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("*deleting ") else { return nil }
            let path = line.dropFirst("*deleting ".count).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        })
    }

    nonisolated static func deletionLimit(snapshotCount: Int) -> Int { max(50, snapshotCount / 4) }

    /// Files made or changed here since the last sync. Without a record of it, none: the
    /// host decides.
    nonisolated static func changed(_ now: [String: Double], since snapshot: [String: Double]?) -> Set<String> {
        guard let snapshot else { return [] }
        return Set(now.filter { !$0.key.hasSuffix("/") && snapshot[$0.key] != $0.value }.keys)
    }

    /// What the host deleted that can go here too: unchanged since the last sync. Without a
    /// record of the last sync, the host decides.
    nonisolated static func removable(_ deleted: Set<String>, before: [String: Double], snapshot: [String: Double]?) -> Set<String> {
        guard let snapshot else { return deleted }
        return deleted.filter { path in
            guard let synced = snapshot[path] else { return false }
            return path.hasSuffix("/") || before[path] == synced
        }
    }

    nonisolated static func isSafeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    /// Files and folders (with a trailing slash) under the mirror, with their modification
    /// times, skipping what isn't synced.
    nonisolated static func listing(_ root: URL) -> [String: Double] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [:] }
        var paths: [String: Double] = [:]
        var prefix: String?
        for case let url as URL in enumerator {
            if prefix == nil { prefix = url.deletingLastPathComponent().path + "/" }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let name = url.lastPathComponent
            if name == ".DS_Store" { continue }
            if isDirectory, name == ".git" || skippedFolders.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            guard let prefix, url.path.hasPrefix(prefix) else { continue }
            let relative = String(url.path.dropFirst(prefix.count))
            paths[isDirectory ? relative + "/" : relative] = isDirectory ? 0 : values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
        return paths
    }

    /// Deletes files, then folders that are empty, deepest first.
    nonisolated static func remove(_ paths: Set<String>, in root: URL) {
        let manager = FileManager.default
        for path in paths.filter(isSafeRelative).sorted(by: { $0.count > $1.count }) {
            let url = root.appending(path: path)
            if path.hasSuffix("/") {
                if (try? manager.contentsOfDirectory(atPath: url.path))?.isEmpty == true { try? manager.removeItem(at: url) }
            } else {
                try? manager.removeItem(at: url)
            }
        }
    }

    /// A sentence for a failed ssh or rsync run.
    public nonisolated static func explain(_ output: Shell.Output, host: String) -> String {
        let text = output.message
        let lower = text.lowercased()
        if lower.contains("permission denied") {
            return "\(host) didn’t accept this Mac’s ssh key. Dante doesn’t ask for passwords: add your key to the host (ssh-copy-id) or to the ssh agent."
        }
        if lower.contains("could not resolve hostname") || lower.contains("nodename nor servname") {
            return "There’s no host called \(host). Check the name, or add it to ~/.ssh/config."
        }
        if lower.contains("connection refused") || lower.contains("timed out") || lower.contains("no route to host") {
            return "Couldn’t reach \(host): \(text.components(separatedBy: "\n").last ?? text)"
        }
        if lower.contains("host key verification failed") {
            return "\(host) isn’t a known host yet. Connect once with ssh in the terminal to check and accept its key."
        }
        if lower.contains("rsync: command not found") || lower.contains("rsync: not found") || (output.status == 127 && lower.contains("rsync")) {
            return "\(host) needs rsync to sync files. Install it there (apt install rsync, or dnf install rsync)."
        }
        return text.isEmpty ? "ssh exited with status \(output.status)." : text
    }

    // MARK: Snapshot on disk

    private static func snapshotURL(for project: RemoteProject) -> URL {
        URL(filePath: project.mirror + ".synced.json")
    }

    private static func loadSnapshot(for project: RemoteProject) -> [String: Double]? {
        guard let data = try? Data(contentsOf: snapshotURL(for: project)) else { return nil }
        return try? JSONDecoder().decode([String: Double].self, from: data)
    }

    private func saveSnapshot() {
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.snapshotURL(for: project), options: .atomic)
    }
}
