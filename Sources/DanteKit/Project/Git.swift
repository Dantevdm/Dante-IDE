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

    /// Clones `repository` into `parent` and returns the new folder.
    public static func clone(_ repository: String, into parent: URL) async throws -> URL {
        guard let name = cloneFolderName(for: repository) else {
            throw CommandError(output: "That doesn’t look like a repository URL.")
        }
        let destination = parent.appending(path: name)
        try await run(["git", "clone", repository, destination.path], in: parent)
        return destination
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
