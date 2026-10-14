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

    /// One argument for a command line typed into a shell: single-quoted unless it's plainly safe.
    public static func quote(_ argument: String) -> String {
        if !argument.isEmpty, argument.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+=:,@%".contains($0)) }) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs to completion. Both pipes are drained while the process runs, so large output
    /// can't fill a pipe and stall it. A missing tool comes back as status 127.
    /// `trimming: false` keeps stdout exactly as written, for file contents. `extra` adds
    /// environment variables, for secrets that mustn't appear in the arguments.
    /// In a remote project's mirror the command runs on its host instead, over ssh.
    public static func run(_ arguments: [String], in directory: URL, trimming: Bool = true, extra: [String: String] = [:]) async -> Output {
        let remote = RemoteRegistry.project(containing: directory)
        let output: Output = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let input = configure(process, arguments, in: directory, extra: extra, remote: remote)
                let out = Pipe(), err = Pipe(), inPipe = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(status: 127, stdout: "", stderr: error.localizedDescription))
                    return
                }
                if let input {
                    try? inPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inPipe.fileHandleForWriting.close()
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
        // The command may have changed files there (a checkout, a formatter).
        if let remote { RemoteRegistry.commandFinished(for: remote.project) }
        return output
    }

    /// `/usr/bin/env` with the arguments, or ssh to the host for a folder in a remote mirror.
    /// Returns what to write to the command's stdin: `extra` for a host, which must not go on
    /// the ssh command line.
    @discardableResult
    static func configure(_ process: Process, _ arguments: [String], in directory: URL, extra: [String: String] = [:],
                          remote: (project: RemoteProject, path: String)?) -> Data? {
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.environment = environment().merging(extra) { $1 }
        if let remote {
            let (arguments, input) = readingEnvironment(arguments, extra)
            let command = SSH.remoteCommand(arguments, in: remote.path, environment: remoteEnvironment)
            process.arguments = [SSH.program] + SSH.arguments(host: remote.project.host, command: command)
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            return input
        }
        process.arguments = arguments
        process.currentDirectoryURL = directory
        return nil
    }

    /// For a command on a host: `extra` (passwords, mostly) travels on stdin, where `ps` on
    /// neither machine shows it, and a POSIX sh there reads it into the environment before
    /// starting the command. A value can't hold a newline; one becomes a space.
    static func readingEnvironment(_ arguments: [String], _ extra: [String: String]) -> (arguments: [String], input: Data?) {
        let names = extra.keys.sorted().filter { name in
            name.first.map { $0 == "_" || $0.isLetter } == true && name.allSatisfy { $0.isASCII && ($0 == "_" || $0.isLetter || $0.isNumber) }
        }
        guard !names.isEmpty else { return (arguments, nil) }
        let script = names.map { "IFS= read -r \($0); export \($0)" }.joined(separator: "; ") + #"; exec "$@""#
        let lines = names.map { (extra[$0] ?? "").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ") }
        return (["sh", "-c", script, "sh"] + arguments, Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// What `environment()` sets for parsing, for commands run on a host.
    static let remoteEnvironment = ["GIT_TERMINAL_PROMPT": "0", "NO_COLOR": "1", "TERM": "dumb"]

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

        /// The exit status, once the process has exited (call after `lines` finishes).
        public func exitStatus() async -> Int32 {
            while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            return process.terminationStatus
        }
    }

    public static func stream(_ arguments: [String], in directory: URL) throws -> Running {
        let process = Process()
        let remote = RemoteRegistry.project(containing: directory)
        configure(process, arguments, in: directory, remote: remote)
        if let remote {
            let project = remote.project
            process.terminationHandler = { _ in RemoteRegistry.commandFinished(for: project) }
        }
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
