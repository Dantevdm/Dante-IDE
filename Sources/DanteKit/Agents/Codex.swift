import Foundation

/// What Codex said and used in one `codex exec` run.
public struct CodexReply: Equatable, Sendable {
    /// Its last message: the answer.
    public var text: String
    /// Commands it ran to look around (read-only).
    public var commands: [String]
    public var inputTokens: Int
    public var cachedTokens: Int
    public var outputTokens: Int
    public var seconds: Double

    public init(text: String, commands: [String] = [], inputTokens: Int = 0, cachedTokens: Int = 0, outputTokens: Int = 0, seconds: Double = 0) {
        self.text = text
        self.commands = commands
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
        self.seconds = seconds
    }

    /// Reads `codex exec --json` output: one event per line. Throws the turn's error when it failed.
    public static func parse(_ output: String, seconds: Double = 0) throws -> CodexReply {
        var reply = CodexReply(text: "", seconds: seconds)
        var failure: String?
        for line in output.split(separator: "\n") {
            guard let event = JSONValue(line: String(line)) else { continue }
            switch event["type"]?.string {
            case "item.completed":
                let item = event["item"]
                switch item?["type"]?.string {
                case "agent_message":
                    if let text = item?["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { reply.text = text }
                case "command_execution":
                    if let command = item?["command"]?.string { reply.commands.append(Codex.shown(command)) }
                default:
                    break
                }
            case "turn.completed":
                let usage = event["usage"]
                reply.inputTokens = usage?["input_tokens"]?.int ?? 0
                reply.cachedTokens = usage?["cached_input_tokens"]?.int ?? 0
                reply.outputTokens = usage?["output_tokens"]?.int ?? 0
            case "turn.failed":
                failure = Codex.message(event["error"]?["message"]?.string ?? "Codex stopped.")
            case "error":
                if failure == nil { failure = Codex.message(event["message"]?.string ?? "Codex stopped.") }
            default:
                break
            }
        }
        if let failure, reply.text.isEmpty { throw Codex.Failure(message: failure) }
        return reply
    }
}

/// OpenAI's Codex CLI, signed in with the user's ChatGPT account: a second agent that can read
/// the project itself. Dante only ever runs it read-only, without the user's Codex config, and
/// without saving a session.
public struct Codex: Sendable {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public var executable: String

    public init(executable: String) {
        self.executable = executable
    }

    /// Where Codex is: `DANTE_CODEX` when set, else the usual install places, including the copy
    /// inside the ChatGPT and Codex apps.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if let path = environment["DANTE_CODEX"], !path.isEmpty, isExecutable(path) { return path }
        let candidates = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            home.appending(path: ".local/bin/codex").path, home.appending(path: ".npm-global/bin/codex").path,
            home.appending(path: ".bun/bin/codex").path,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        return candidates.first(where: isExecutable)
    }

    /// `codex exec` reading the prompt from stdin: JSON events, read-only, no session saved, and
    /// the user's own config left out (its model may not work with a ChatGPT sign-in). Images
    /// go last, since `--image` takes every value after it.
    public static func arguments(project: String, model: String?, images: [String] = []) -> [String] {
        var arguments = ["exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
                         "--ignore-user-config", "--color", "never", "-C", project]
        if let model, !model.isEmpty { arguments += ["-m", model] }
        return arguments + ["-"] + (images.isEmpty ? [] : ["--image"] + images)
    }

    public func ask(_ prompt: String, in project: String, model: String? = nil, images: [String] = [], timeout: TimeInterval = 600) async throws -> CodexReply {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = Self.arguments(project: project, model: model, images: images)
        process.currentDirectoryURL = URL(filePath: project)
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDECODE"] = nil
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let started = Date()
        do {
            try process.run()
        } catch {
            throw Failure(message: "Couldn’t start Codex: \(error.localizedDescription)")
        }
        try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
        // Drain stderr so a chatty run can't fill the pipe and stall.
        let drain = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        }
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        watchdog.cancel()
        _ = await drain.value
        let reply = try CodexReply.parse(String(decoding: data, as: UTF8.self), seconds: Date().timeIntervalSince(started))
        guard !reply.text.isEmpty else {
            throw Failure(message: process.terminationReason == .uncaughtSignal ? "Codex took too long and was stopped." : "Codex finished without an answer.")
        }
        return reply
    }

    /// Codex wraps API errors as JSON in its message; this digs out the sentence.
    static func message(_ raw: String) -> String {
        if let inner = JSONValue(line: raw), let message = inner["error"]?["message"]?.string ?? inner["message"]?.string {
            return message
        }
        return raw
    }

    /// `/bin/zsh -lc 'rg -n startup NOTES.md'` → `rg -n startup NOTES.md`.
    static func shown(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where command.hasPrefix(prefix) {
            var rest = String(command.dropFirst(prefix.count))
            if rest.count >= 2, let first = rest.first, first == rest.last, first == "'" || first == "\"" {
                rest = String(rest.dropFirst().dropLast())
            }
            return rest
        }
        return command
    }
}
