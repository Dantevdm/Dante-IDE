import Foundation

/// What Claude said and used when asked for a second opinion.
public struct ClaudeReply: Equatable, Sendable {
    public var text: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var seconds: Double
    /// At API prices; on a Pro or Max plan it's a measure of the plan's allowance, not a bill.
    public var costUSD: Double?

    public init(text: String, inputTokens: Int = 0, outputTokens: Int = 0, seconds: Double = 0, costUSD: Double? = nil) {
        self.text = text
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.seconds = seconds
        self.costUSD = costUSD
    }

    /// Reads `claude -p --output-format json`: one result object.
    public static func parse(_ output: String) throws -> ClaudeReply {
        let line = output.split(separator: "\n").last { $0.contains("\"type\":\"result\"") }.map(String.init) ?? output
        guard let json = JSONValue(line: line) else {
            throw ClaudeOpinion.Failure(message: output.isEmpty ? "Claude didn’t answer." : String(output.prefix(300)))
        }
        let text = json["result"]?.string ?? ""
        if json["is_error"]?.bool == true || text.isEmpty {
            throw ClaudeOpinion.Failure(message: text.isEmpty ? "Claude finished without an answer." : text)
        }
        let usage = json["usage"]
        let input = (usage?["input_tokens"]?.int ?? 0) + (usage?["cache_read_input_tokens"]?.int ?? 0) + (usage?["cache_creation_input_tokens"]?.int ?? 0)
        return ClaudeReply(text: text, inputTokens: input, outputTokens: usage?["output_tokens"]?.int ?? 0,
                           seconds: Double(json["duration_ms"]?.int ?? 0) / 1000, costUSD: json["total_cost_usd"]?.double)
    }
}

/// Claude Code asked one question, read-only, for Codex's second opinions: it can read and
/// search the project but not change it or run commands, and nothing is saved as a session.
public struct ClaudeOpinion: Sendable {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public var executable: String

    public init(executable: String) {
        self.executable = executable
    }

    /// The prompt goes on stdin. `tools` are the only tools it has; `allowed` are rules for the
    /// ones that would otherwise ask (and, with `dontAsk`, be refused), such as `Write(docs/**)`.
    public static func arguments(model: String?, tools: [String] = ["Read", "Grep", "Glob"], allowed: [String] = [], system: String? = nil, settings: String? = nil) -> [String] {
        var arguments = ["-p", "--output-format", "json", "--tools", tools.joined(separator: ","), "--permission-mode", "dontAsk", "--no-session-persistence"]
        if !allowed.isEmpty { arguments += ["--allowedTools"] + allowed }
        // The project's `never` paths, denied as they are for the main conversation.
        if let settings { arguments += ["--settings", settings] }
        if let system, !system.isEmpty { arguments += ["--append-system-prompt", system] }
        if let model, !model.isEmpty { arguments += ["--model", model] }
        return arguments
    }

    public func ask(_ prompt: String, in project: String, model: String? = nil, timeout: TimeInterval = 600) async throws -> ClaudeReply {
        try await run(prompt, in: project, arguments: Self.arguments(model: model, settings: Self.settings(project)), timeout: timeout)
    }

    static func settings(_ project: String) -> String? {
        ClaudeRules.load(projectRoot: URL(filePath: project)).settingsJSON
    }

    /// A team member working for Codex: the role's tools and prompt, on the role's model.
    public func team(_ role: TeamRole, brief: String, in project: String, model: String?, timeout: TimeInterval = 900) async throws -> ClaudeReply {
        let access = role.forCodex
        return try await run(brief, in: project, arguments: Self.arguments(model: model, tools: access.tools, allowed: access.allowed, system: role.prompt, settings: Self.settings(project)), timeout: timeout)
    }

    private func run(_ prompt: String, in project: String, arguments: [String], timeout: TimeInterval) async throws -> ClaudeReply {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: project)
        process.environment = ClaudeSession.environment()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw Failure(message: "Couldn’t start Claude Code: \(error.localizedDescription)")
        }
        // The watchdog starts first and the prompt is written off this task: a child that
        // never reads a long prompt can't hang the call.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        }
        let writer = input.fileHandleForWriting
        Task.detached {
            try? writer.write(contentsOf: Data(prompt.utf8))
            try? writer.close()
        }
        // Drain stderr so a chatty run can't fill the pipe and stall.
        let drain = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
        // A cancelled call (the MCP client gave up) stops the child rather than leaving it running.
        let data = await withTaskCancellationHandler {
            await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        watchdog.cancel()
        let stderr = String(decoding: await drain.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationReason == .uncaughtSignal { throw Failure(message: "Claude took too long and was stopped.") }
        let text = String(decoding: data, as: UTF8.self)
        if text.isEmpty, !stderr.isEmpty { throw Failure(message: String(stderr.suffix(300))) }
        return try ClaudeReply.parse(text)
    }
}
