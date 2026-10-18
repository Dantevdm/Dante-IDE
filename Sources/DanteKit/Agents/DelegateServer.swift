import Foundation

/// The MCP server `dante mcp` runs for Claude Code: a `delegate` tool that hands a job to a
/// model in Ollama on this Mac and returns its answer for Claude to check. Each job goes in
/// the `AgentLedger`. Speaks MCP's stdio transport: one JSON-RPC message per line.
public struct DelegateServer: Sendable {
    /// Runs a job on a local model: the model's name and its reply.
    public typealias Runner = @Sendable (DelegateKind, _ prompt: String) async throws -> (model: String, reply: OllamaReply)

    public var project: String
    public var ledger: AgentLedger?
    public var models: @Sendable () async -> [OllamaModel]?
    public var run: Runner

    public static let protocolVersion = "2025-06-18"

    public init(project: String, ledger: AgentLedger?, models: @escaping @Sendable () async -> [OllamaModel]?, run: @escaping Runner) {
        self.project = project
        self.ledger = ledger
        self.models = models
        self.run = run
    }

    /// The server Dante ships: Ollama on this Mac, the standard ledger, and models chosen
    /// per job in Settings (`DANTE_MODEL_<KIND>` from the app, else the best installed).
    public static func live(project: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> DelegateServer {
        let ollama = Ollama(base: environment["OLLAMA_HOST"].flatMap { URL(string: $0.hasPrefix("http") ? $0 : "http://\($0)") } ?? Ollama().base)
        return DelegateServer(project: project, ledger: .standard, models: { await ollama.models() }) { kind, prompt in
            let installed = await ollama.models() ?? []
            let chosen = environment["DANTE_MODEL_\(kind.rawValue.uppercased())"]
            guard let model = ModelRouting.model(for: kind, installed: installed, chosen: chosen) else {
                throw Ollama.Failure(message: "No local model for \(kind.title.lowercased()). Pull one with ollama, or do this yourself.")
            }
            return (model, try await ollama.chat(model: model, system: system(for: kind), prompt: prompt))
        }
    }

    static func system(for kind: DelegateKind) -> String {
        "You are a focused assistant doing one job for a senior engineer, who will check your work: \(kind.guidance). Be accurate and concise. Don't invent facts, files or APIs; say when you're unsure. Reply with the result only."
    }

    /// Answers one line from Claude Code. Nil for notifications, which get no reply.
    public func handle(_ line: String) async -> String? {
        guard let message = JSONValue(line: line), let method = message["method"]?.string else { return nil }
        let id = message["id"]
        guard let id, !id.isNull else { return nil }
        let result: JSONValue
        switch method {
        case "initialize":
            let version = message["params"]?["protocolVersion"]?.string ?? Self.protocolVersion
            result = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "dante", "version": "1"],
                "instructions": "Local models on this Mac. Delegate small, checkable jobs to save the user's Claude usage; always review what comes back.",
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(Self.tools)]
        case "tools/call":
            result = await call(message["params"]?["name"]?.string ?? "", arguments: message["params"]?["arguments"] ?? [:])
        default:
            return JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Unknown method \(method)")]]).jsonLine
        }
        return JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).jsonLine
    }

    static var tools: [JSONValue] {
        let kinds = DelegateKind.allCases.map { "\($0.rawValue): \($0.guidance)" }.joined(separator: "; ")
        return [
            [
                "name": "delegate",
                "description": .string("Hand a self-contained job to a local model on the user's Mac, saving their Claude usage. Good for: \(kinds). The model can't see files or run tools: put everything it needs in the prompt. It's weaker than you, so check the answer before using it, and do the job yourself when it needs judgement across the codebase."),
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": .array(DelegateKind.allCases.map { .string($0.rawValue) })],
                        "title": ["type": "string", "description": "A few words saying what the job is, for the user's stats."],
                        "prompt": ["type": "string", "description": "The full instructions and material: the file, log or diff to work on."],
                    ],
                    "required": ["kind", "prompt"],
                ],
            ],
            [
                "name": "local_models",
                "description": "List the models in Ollama on the user's Mac and which job each would get.",
                "inputSchema": ["type": "object", "properties": [:]],
            ],
        ]
    }

    func call(_ name: String, arguments: JSONValue) async -> JSONValue {
        switch name {
        case "delegate":
            guard let kind = arguments["kind"]?.string.flatMap(DelegateKind.init(rawValue:)),
                  let prompt = arguments["prompt"]?.string, !prompt.isEmpty else {
                return Self.text("delegate needs a kind (\(DelegateKind.allCases.map(\.rawValue).joined(separator: ", "))) and a prompt.", isError: true)
            }
            let title = arguments["title"]?.string ?? String(prompt.prefix(60))
            do {
                let (model, reply) = try await run(kind, prompt)
                ledger?.append(AgentJob(kind: kind.rawValue, provider: .local, model: model, project: project,
                                        promptTokens: reply.promptTokens, outputTokens: reply.outputTokens, seconds: reply.seconds,
                                        requestedBy: "claude", title: title))
                let header = "[\(kind.agent) · \(model) · \(reply.promptTokens)→\(reply.outputTokens) tokens · \(String(format: "%.1f", reply.seconds))s] Check this before relying on it."
                return Self.text(header + "\n\n" + reply.text)
            } catch {
                ledger?.append(AgentJob(kind: kind.rawValue, provider: .local, model: "unavailable", project: project,
                                        outcome: .failed, requestedBy: "claude", title: title))
                return Self.text("The local model couldn’t do this: \(error.localizedDescription) Do it yourself.", isError: true)
            }
        case "local_models":
            guard let installed = await models() else { return Self.text("Ollama isn’t running on this Mac.", isError: true) }
            let lines = installed.map { model -> String in
                let jobs = DelegateKind.allCases.filter { ModelRouting.model(for: $0, installed: installed) == model.name }.map(\.rawValue)
                let note = model.isCloud ? "cloud, not used" : model.isVision ? "images" : model.isEmbedding ? "embeddings" : (jobs.isEmpty ? "spare" : jobs.joined(separator: ", "))
                return "- \(model.name) (\(model.parameterSize.isEmpty ? "?" : model.parameterSize)): \(note)"
            }
            return Self.text(lines.isEmpty ? "No models installed." : lines.joined(separator: "\n"))
        default:
            return Self.text("Unknown tool \(name).", isError: true)
        }
    }

    static func text(_ text: String, isError: Bool = false) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    /// Reads stdin until it closes, answering each line on stdout.
    public func serve() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let reply = await handle(line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }
}
