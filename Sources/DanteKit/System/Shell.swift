import Foundation

/// Runs command-line tools for the areas that read the outside world: git, test runners,
/// docker, gh. Commands go through `/usr/bin/env` with the PATH Claude Code gets, so tools
/// installed by Homebrew or in `~/.local/bin` are found when Dante is opened from Finder.
public enum Shell {
    public struct Output: Sendable, Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public var succeeded: Bool { status == 0 }
        /// stderr when there is any, else stdout: what to show when a command fails.
        public var message: String { stderr.isEmpty ? stdout : stderr }
    }

    /// Runs to completion. Both pipes are drained while the process runs, so large output
    /// can't fill a pipe and stall it. A missing tool comes back as status 127.
    /// `trimming: false` keeps stdout exactly as written, for file contents. `extra` adds
    /// environment variables, for secrets that mustn't appear in the arguments.
    public static func run(_ arguments: [String], in directory: URL, trimming: Bool = true, extra: [String: String] = [:]) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/env")
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.environment = environment().merging(extra) { $1 }
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(status: 127, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let errors = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errors.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: trimming ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : String(decoding: data, as: UTF8.self),
                    stderr: String(decoding: errors.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
    }

    /// A long-running command whose output arrives line by line (stdout and stderr merged),
    /// for test runs and `docker compose logs -f`.
    public final class Running: @unchecked Sendable {
        public let lines: AsyncStream<String>
        private let process: Process

        init(process: Process, lines: AsyncStream<String>) {
            self.process = process
            self.lines = lines
        }

        public var isRunning: Bool { process.isRunning }
        /// Only meaningful once `lines` has finished.
        public var status: Int32 { process.isRunning ? 0 : process.terminationStatus }

        public func terminate() {
            if process.isRunning { process.terminate() }
        }
    }

    public static func stream(_ arguments: [String], in directory: URL) throws -> Running {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let lines = ClaudeSession.lines(from: pipe.fileHandleForReading)
        try process.run()
        return Running(process: process, lines: lines)
    }

    /// The full path of a tool, or nil when it isn't installed.
    public static func which(_ name: String) -> String? {
        SystemStatus.findExecutable(name, environment: environment())
    }

    public static func environment() -> [String: String] {
        var environment = ClaudeSession.environment()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Plain output: no colour codes or progress bars in what Dante parses.
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        return environment
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }
}
