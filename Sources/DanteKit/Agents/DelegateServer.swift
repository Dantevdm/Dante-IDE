import Foundation

/// The MCP server `dante mcp` runs for Claude Code: a `delegate` tool that hands a job to a
/// model in Ollama on this Mac and returns its answer for Claude to check, and, when the user
/// has added their keys, `decide` (Jev's typed decisions) and `ask_grok` (xAI's Grok). Each
/// job goes in the `AgentLedger`. Speaks MCP's stdio transport: one JSON-RPC message per line.
public struct DelegateServer: Sendable {
    /// Runs a job on a local model: the model's name and its reply.
    public typealias Runner = @Sendable (DelegateKind, _ prompt: String) async throws -> (model: String, reply: OllamaReply)
    public typealias Decider = @Sendable (_ state: JSONValue, _ questions: [(name: String, question: JevQuestion)]) async throws -> JevDecision
    public typealias Asker = @Sendable (_ system: String?, _ prompt: String) async throws -> GrokReply

    public var project: String
    public var ledger: AgentLedger?
    public var models: @Sendable () async -> [OllamaModel]?
    public var run: Runner
    /// Off when the user has turned delegation to local models off but has a cloud agent.
    public var offersLocal = true
    public var decide: Decider?
    public var askGrok: Asker?

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
        var server = DelegateServer(project: project, ledger: .standard, models: { await ollama.models() }) { kind, prompt in
            let installed = await ollama.models() ?? []
            let chosen = environment["DANTE_MODEL_\(kind.rawValue.uppercased())"]
            guard let model = ModelRouting.model(for: kind, installed: installed, chosen: chosen) else {
                throw Ollama.Failure(message: "No local model for \(kind.title.lowercased()). Pull one with ollama, or do this yourself.")
            }
            return (model, try await ollama.chat(model: model, system: system(for: kind), prompt: prompt))
        }
        server.offersLocal = environment[DelegateEnvironment.local] != "0"
        if let key = environment[CloudAgent.jev.environmentVariable], !key.isEmpty {
            let jev = Jev(key: key)
            server.decide = { state, questions in try await jev.decide(state: state, questions: questions) }
        }
        if let key = environment[CloudAgent.grok.environmentVariable], !key.isEmpty {
            let grok = Grok(key: key)
            let chosen = environment[DelegateEnvironment.grokModel]
            server.askGrok = { system, prompt in
                let available = (try? await grok.models()) ?? []
                guard let model = Grok.model(chosen: chosen, available: available) else {
                    throw Grok.Failure(message: "The xAI key has no chat models.")
                }
                return try await grok.chat(model: model, system: system, prompt: prompt)
            }
        }
        return server
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
                "instructions": .string(instructions),
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(tools)]
        case "tools/call":
            result = await call(message["params"]?["name"]?.string ?? "", arguments: message["params"]?["arguments"] ?? [:])
        default:
            return JSONValue.object(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Unknown method \(method)")]]).jsonLine
        }
        return JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).jsonLine
    }

    var instructions: String {
        var parts: [String] = []
        if offersLocal { parts.append("Local models on this Mac: delegate small, checkable jobs to save the user's Claude usage, and review what comes back.") }
        if decide != nil { parts.append("Jev answers typed questions (pick one, rate, yes or no) about some material in well under a second.") }
        if askGrok != nil { parts.append("Grok (xAI) gives an independent second opinion or draft.") }
        return parts.joined(separator: " ")
    }

    var tools: [JSONValue] {
        var tools: [JSONValue] = []
        if offersLocal { tools += Self.localTools }
        if decide != nil { tools.append(Self.decideTool) }
        if askGrok != nil { tools.append(Self.grokTool) }
        return tools
    }

    static let decideTool: JSONValue = [
        "name": "decide",
        "description": "Ask Jev, a fast decision model, typed questions about some material: which of several options fits (choice), where it sits on a scale (score) or how likely something is (yes_no). Good for routing and triage at scale: which area a failure belongs to, how risky a command or diff is, whether a log line is an error worth reading. It answers in under a second for a fraction of a cent, but it judges only the material you pass, so include what it needs. Runs on Jev's servers with the user's key: never send secrets.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "material": ["type": "string", "description": "What to judge: a command, diff, log, message or description."],
                "title": ["type": "string", "description": "A few words saying what the decision is, for the user's stats."],
                "questions": [
                    "type": "array",
                    "description": "Up to eight questions, each answered separately.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["type": "string", "description": "A short id for the answer, like route or risk."],
                            "type": ["type": "string", "enum": ["choice", "score", "yes_no"]],
                            "instructions": ["type": "string", "description": "The question, in a sentence."],
                            "options": ["type": "object", "description": "For choice: each label and what it means.", "additionalProperties": ["type": "string"]],
                            "levels": ["type": "array", "items": ["type": "string"], "description": "For score: 2–10 levels, low to high."],
                        ],
                        "required": ["name", "type", "instructions"],
                    ],
                ],
            ],
            "required": ["material", "questions"],
        ],
    ]

    static let grokTool: JSONValue = [
        "name": "ask_grok",
        "description": "Ask xAI's Grok for an independent second opinion: a review of a plan or diff, another way to solve a problem, or a draft to compare with yours. It can't see files or run tools, so put everything it needs in the prompt. Runs on xAI's servers with the user's key and is billed to them: use it when a second view is worth it, never send secrets, and weigh its answer rather than adopting it.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "The question and all the material it needs."],
                "system": ["type": "string", "description": "Optional instructions on how to answer."],
                "title": ["type": "string", "description": "A few words saying what you asked, for the user's stats."],
            ],
            "required": ["prompt"],
        ],
    ]

    static var localTools: [JSONValue] {
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
        case "decide":
            return await callDecide(arguments)
        case "ask_grok":
            return await callGrok(arguments)
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

    func callDecide(_ arguments: JSONValue) async -> JSONValue {
        guard let decide else { return Self.text("Jev isn’t set up: the user can add a key in Dante’s Settings.", isError: true) }
        let material = arguments["material"] ?? arguments["state"] ?? .null
        let questions = (arguments["questions"]?.array ?? []).compactMap { value -> (name: String, question: JevQuestion)? in
            guard let name = value["name"]?.string, !name.isEmpty, let question = JevQuestion.parse(value) else { return nil }
            return (name, question)
        }
        guard material.string.map({ !$0.isEmpty }) ?? !material.isNull, !questions.isEmpty else {
            return Self.text("decide needs material and at least one question with a name, a type (choice with two or more options, score with 2–10 levels, or yes_no) and instructions.", isError: true)
        }
        let title = arguments["title"]?.string ?? questions.map(\.name).joined(separator: ", ")
        let started = Date()
        do {
            let decision = try await decide(material, questions)
            let seconds = Date().timeIntervalSince(started)
            ledger?.append(AgentJob(kind: "decision", provider: .jev, model: decision.model, project: project,
                                    promptTokens: decision.inputTokens, seconds: seconds, requestedBy: "claude",
                                    title: title, costUSD: decision.costUSD))
            let header = "[Jev · \(decision.model) · \(decision.inputTokens) tokens · $\(String(format: "%.6f", decision.costUSD)) · \(String(format: "%.2f", seconds))s]"
            return Self.text(header + "\n\n" + decision.summary(questions))
        } catch {
            ledger?.append(AgentJob(kind: "decision", provider: .jev, model: "jev", project: project,
                                    seconds: Date().timeIntervalSince(started), outcome: .failed, requestedBy: "claude", title: title))
            return Self.text("Jev couldn’t decide: \(error.localizedDescription) Decide yourself.", isError: true)
        }
    }

    func callGrok(_ arguments: JSONValue) async -> JSONValue {
        guard let askGrok else { return Self.text("Grok isn’t set up: the user can add an xAI key in Dante’s Settings.", isError: true) }
        guard let prompt = arguments["prompt"]?.string, !prompt.isEmpty else {
            return Self.text("ask_grok needs a prompt.", isError: true)
        }
        let title = arguments["title"]?.string ?? String(prompt.prefix(60))
        let started = Date()
        do {
            let reply = try await askGrok(arguments["system"]?.string, prompt)
            ledger?.append(AgentJob(kind: "opinion", provider: .grok, model: reply.model, project: project,
                                    promptTokens: reply.promptTokens, outputTokens: reply.outputTokens, seconds: reply.seconds,
                                    requestedBy: "claude", title: title))
            let header = "[Grok · \(reply.model) · \(reply.promptTokens)→\(reply.outputTokens) tokens · \(String(format: "%.1f", reply.seconds))s] A second opinion: weigh it, don’t just adopt it."
            return Self.text(header + "\n\n" + reply.text)
        } catch {
            ledger?.append(AgentJob(kind: "opinion", provider: .grok, model: "grok", project: project,
                                    seconds: Date().timeIntervalSince(started), outcome: .failed, requestedBy: "claude", title: title))
            return Self.text("Grok couldn’t answer: \(error.localizedDescription)", isError: true)
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
