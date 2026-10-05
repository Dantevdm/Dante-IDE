import Foundation

public enum Git {
    /// The checked-out branch, read from `.git/HEAD` without running git.
    /// Returns a short commit hash for a detached HEAD, or nil outside a repo.
    public static func currentBranch(in root: URL) -> String? {
        var gitDir = root.appending(path: ".git")
        // Worktrees and submodules use a `.git` file that points at the real directory.
        if let pointer = try? String(contentsOf: gitDir, encoding: .utf8), pointer.hasPrefix("gitdir:") {
            let path = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path)
        }
        guard let head = try? String(contentsOf: gitDir.appending(path: "HEAD"), encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
    }

    /// The folder name `git clone` would create for a repository URL.
    public static func cloneFolderName(for repository: String) -> String? {
        var name = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix("/") { name.removeLast() }
        name = String(name.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty ? nil : name
    }

    public struct CommandError: LocalizedError {
        public let output: String
        public var errorDescription: String? { output.isEmpty ? "git failed." : output }
    }

    /// Where a clone has got to, from git's `--progress` lines.
    public struct CloneProgress: Equatable, Sendable {
        /// "Receiving objects", "Resolving deltas"…
        public var phase: String
        /// 0…1 within the phase, when git reports a percentage.
        public var fraction: Double?
        /// The rest of the line: counts, size and speed.
        public var detail: String

        /// Parses one progress line, such as `Receiving objects:  45% (450/1000), 1.20 MiB | 2.40 MiB/s`.
        public static func parse(_ line: String) -> CloneProgress? {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("remote: ") { text.removeFirst(8) }
            guard let match = text.firstMatch(of: /^([A-Z][A-Za-z ]+):\s*(?:(\d+)%\s*)?(.*)$/) else { return nil }
            let phase = String(match.1)
            guard ["Enumerating objects", "Counting objects", "Compressing objects", "Receiving objects", "Resolving deltas", "Updating files", "Total"].contains(phase) else { return nil }
            let detail = String(match.3).replacingOccurrences(of: ", done.", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            return CloneProgress(phase: phase, fraction: match.2.flatMap { Double($0) }.map { $0 / 100 }, detail: detail)
        }

        /// Where this phase sits in the whole clone, for one progress bar: receiving is the bulk.
        public var overall: Double? {
            guard let fraction else { return nil }
            switch phase {
            case "Enumerating objects", "Counting objects", "Compressing objects": return 0.05 * fraction
            case "Receiving objects": return 0.05 + 0.75 * fraction
            case "Resolving deltas": return 0.8 + 0.12 * fraction
            case "Updating files": return 0.92 + 0.08 * fraction
            default: return nil
            }
        }
    }

    /// git asked for a password or token it had no way to get.
    public static func needsCredentials(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("terminal prompts disabled") || lower.contains("could not read username")
            || lower.contains("could not read password") || lower.contains("authentication failed")
            || lower.contains("permission denied (publickey")
    }

    /// The running clone, so it can be cancelled.
    public final class CloneHandle: @unchecked Sendable {
        fileprivate var process: Process?
        public init() {}
        public func cancel() { process?.terminate() }
    }

    /// Clones `repository` into `parent` and returns the new folder, reporting progress as it goes.
    public static func clone(_ repository: String, into parent: URL, handle: CloneHandle? = nil,
                             progress: @escaping @MainActor (CloneProgress) -> Void = { _ in }) async throws -> URL {
        guard let name = cloneFolderName(for: repository) else {
            throw CommandError(output: "That doesn’t look like a repository URL.")
        }
        let destination = parent.appending(path: name)
        let output: String = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["git", "clone", "--progress", repository, destination.path]
            process.currentDirectoryURL = parent
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            // Fail rather than wait on an SSH passphrase or host-key prompt nobody can see.
            environment["GIT_SSH_COMMAND"] = environment["GIT_SSH_COMMAND"] ?? "ssh -o BatchMode=yes"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in buffer.append(data) {
                    if let parsed = CloneProgress.parse(line) { Task { @MainActor in progress(parsed) } }
                }
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                _ = buffer.append(rest)
                let text = buffer.transcript
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: CommandError(output: text))
                }
            }
            handle?.process = process
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        _ = output
        return destination
    }

    /// Splits git's output on both newlines and the carriage returns it redraws progress with,
    /// keeping the lines that aren't progress for error messages.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private var kept: [String] = []

        func append(_ data: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            pending += String(decoding: data, as: UTF8.self)
            var parts = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            pending = parts.removeLast()
            let lines = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            kept += lines.filter { CloneProgress.parse($0) == nil }
            return lines
        }

        var transcript: String {
            lock.lock(); defer { lock.unlock() }
            return (kept + [pending]).filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: CommandError(output: output))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
