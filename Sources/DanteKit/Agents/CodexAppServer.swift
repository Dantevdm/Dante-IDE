import Foundation

/// Which agent runs a window's conversation: Claude Code, or OpenAI's Codex. Either one is in
/// charge and can ask the other for a second opinion.
public enum AgentEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    case claude, codex

    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "Codex" }
    /// The other one, for second opinions.
    public var partner: AgentEngine { self == .claude ? .codex : .claude }
}

/// How much of the ChatGPT plan's Codex allowance is used, from `account/rateLimits/updated`.
public struct CodexLimits: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// 0…100.
        public var usedPercent: Double
        public var minutes: Int
        public var resetsAt: Date?
    }

    /// The five-hour window.
    public var primary: Window?
    /// The week.
    public var secondary: Window?
    public var plan: String?

    init?(_ json: JSONValue?) {
        guard let json else { return nil }
        primary = Self.window(json["primary"])
        secondary = Self.window(json["secondary"])
        plan = json["planType"]?.string
        if primary == nil, secondary == nil { return nil }
    }

    public init(primary: Window? = nil, secondary: Window? = nil, plan: String? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.plan = plan
    }

    private static func window(_ json: JSONValue?) -> Window? {
        guard let json, let used = json["usedPercent"]?.double else { return nil }
        return Window(usedPercent: used, minutes: json["windowDurationMins"]?.int ?? 0,
                      resetsAt: json["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0) })
    }
}

/// One model Codex offers on the user's account (`model/list`).
public struct CodexModel: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var isDefault: Bool
    public var efforts: [String]

    public init(id: String, name: String, summary: String = "", isDefault: Bool = false, efforts: [String] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isDefault = isDefault
        self.efforts = efforts
    }

    /// The visible models in a `model/list` result, in Codex's order.
    public static func parse(_ result: JSONValue?) -> [CodexModel] {
        (result?["data"]?.array ?? []).compactMap { model in
            guard let id = model["id"]?.string, model["hidden"]?.bool != true else { return nil }
            return CodexModel(id: id, name: model["displayName"]?.string ?? id, summary: model["description"]?.string ?? "",
                              isDefault: model["isDefault"]?.bool ?? false,
                              efforts: (model["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string })
        }
    }
}

/// What a line from `codex app-server` means for the conversation.
public enum CodexIncoming: Equatable, Sendable {
    /// Something the transcript shows, in the same shape as Claude Code's events.
    case event(ClaudeEvent)
    /// A reply to one of Dante's requests.
    case response(id: Int, result: JSONValue?, error: String?)
    case turnStarted(String)
    case limits(CodexLimits)
    /// A message to send straight back: the refusal of a request Dante can't answer.
    case reply(JSONValue)
}

/// Turns `codex app-server` JSON-RPC (one JSON object per line) into the events Dante already
/// shows for Claude Code: messages, tool calls, approvals, usage and turn results. Codex runs
/// commands and patches where Claude Code has Bash and Edit, so they arrive as those tools.
/// Keeps what it needs between lines: which approval belongs to which call, and patch details.
public struct CodexTranslator: Sendable {
    /// Server requests waiting for an answer, by the id Dante gives the permission request.
    private(set) var pending: [String: Pending] = [:]
    /// Each patch's files, from `item/started`, for its approval request.
    private var patches: [String: JSONValue] = [:]
    /// The running MCP call per `server/tool`, so its approval lands on its row.
    private var mcpCalls: [String: String] = [:]
    private var usageCount = 0

    enum Pending: Equatable, Sendable {
        /// A command or patch approval: answered with a decision.
        case decision(id: JSONValue)
        /// Questions for the user: answered with labels, keyed by question id.
        case questions(id: JSONValue, ids: [String: String])
        /// An MCP elicitation, which is how Codex asks before an MCP tool call.
        case elicitation(id: JSONValue)
    }

    public init() {}

    public mutating func translate(_ line: String) -> [CodexIncoming] {
        guard let message = JSONValue(line: line) else { return [] }
        return translate(message)
    }

    public mutating func translate(_ message: JSONValue) -> [CodexIncoming] {
        guard let method = message["method"]?.string else {
            guard let id = message["id"]?.int else { return [] }
            let error = message["error"].flatMap { $0["message"]?.string ?? $0.string }
            return [.response(id: id, result: message["result"], error: error.map(Codex.message))]
        }
        let params = message["params"] ?? [:]
        if let id = message["id"] {
            return serverRequest(method, id: id, params: params)
        }
        switch method {
        case "turn/started":
            return params["turn"]?["id"]?.string.map { [.turnStarted($0)] } ?? []
        case "item/started":
            return started(params["item"] ?? [:])
        case "item/agentMessage/delta":
            return [.event(.textDelta(params["delta"]?.string ?? ""))]
        case "item/completed":
            return completed(params["item"] ?? [:])
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"]
            guard let last = usage?["last"] else { return [] }
            usageCount += 1
            let cached = last["cachedInputTokens"]?.int ?? 0
            // The context is the whole thread so far, as of the latest call.
            let tokens = TokenUsage(input: max(0, (last["inputTokens"]?.int ?? 0) - cached), output: last["outputTokens"]?.int ?? 0,
                                    cacheRead: cached)
            return [.event(.assistant(messageID: "usage-\(usageCount)", blocks: [], usage: tokens))]
        case "account/rateLimits/updated":
            return CodexLimits(params["rateLimits"]).map { [.limits($0)] } ?? []
        case "turn/completed":
            let turn = params["turn"]
            let status = turn?["status"]?.string
            let error = turn?["error"]?["message"]?.string.map(Codex.message)
            return [.event(.result(ClaudeEvent.TurnResult(isError: status == "failed", text: error ?? "",
                                                          durationMS: turn?["durationMs"]?.int)))]
        default:
            return []
        }
    }

    /// The context window, when a usage update carries it.
    public static func contextWindow(_ line: String) -> Int? {
        guard line.contains("\"thread/tokenUsage/updated\""), let message = JSONValue(line: line) else { return nil }
        return message["params"]?["tokenUsage"]?["modelContextWindow"]?.int
    }

    private mutating func started(_ item: JSONValue) -> [CodexIncoming] {
        guard let id = item["id"]?.string else { return [] }
        switch item["type"]?.string {
        case "agentMessage":
            return [.event(.messageStarted(messageID: id)), .event(.blockStarted(isText: true))]
        case "commandExecution":
            return [toolUse(id, "Bash", ["command": .string(Codex.shown(item["command"]?.string ?? ""))])]
        case "fileChange":
            let changes = item["changes"] ?? []
            patches[id] = changes
            return [toolUse(id, Self.patchTool, Self.patchInput(changes))]
        case "mcpToolCall":
            let server = item["server"]?.string ?? "server", tool = item["tool"]?.string ?? "tool"
            mcpCalls["\(server)/\(tool)"] = id
            return [toolUse(id, "mcp__\(server)__\(tool)", item["arguments"] ?? [:])]
        case "webSearch":
            return [toolUse(id, "WebSearch", ["query": .string(item["query"]?.string ?? "")])]
        default:
            return []
        }
    }

    private mutating func completed(_ item: JSONValue) -> [CodexIncoming] {
        guard let id = item["id"]?.string else { return [] }
        switch item["type"]?.string {
        case "agentMessage":
            return [.event(.assistant(messageID: id, blocks: [.text(item["text"]?.string ?? "")]))]
        case "commandExecution":
            let status = item["status"]?.string
            let failed = status == "failed" || status == "declined" || (item["exitCode"]?.int).map { $0 != 0 } == true
            return [result(id, isError: failed, item["aggregatedOutput"]?.string ?? "")]
        case "fileChange":
            patches[id] = nil
            let status = item["status"]?.string
            return [result(id, isError: status == "failed" || status == "declined", status ?? "")]
        case "mcpToolCall":
            mcpCalls = mcpCalls.filter { $0.value != id }
            let error = item["error"]?["message"]?.string
            return [result(id, isError: error != nil || item["status"]?.string == "failed", error ?? "")]
        case "webSearch":
            return [result(id, isError: false, "")]
        default:
            return []
        }
    }

    private mutating func serverRequest(_ method: String, id: JSONValue, params: JSONValue) -> [CodexIncoming] {
        let requestID = "codex-\(id.int.map(String.init) ?? id.string ?? UUID().uuidString)"
        let itemID = params["itemId"]?.string
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            pending[requestID] = .decision(id: id)
            let command = params["command"]?.string ?? params["command"]?.array?.compactMap(\.string).joined(separator: " ") ?? ""
            return [.event(.permissionRequest(.init(requestID: requestID, toolName: "Bash",
                                                    input: ["command": .string(Codex.shown(command))], toolUseID: itemID)))]
        case "item/fileChange/requestApproval", "applyPatchApproval":
            pending[requestID] = .decision(id: id)
            let input = Self.patchInput(itemID.flatMap { patches[$0] } ?? params["changes"] ?? [])
            return [.event(.permissionRequest(.init(requestID: requestID, toolName: Self.patchTool, input: input, toolUseID: itemID)))]
        case "item/tool/requestUserInput":
            var ids: [String: String] = [:]
            let questions: [JSONValue] = (params["questions"]?.array ?? []).map { question in
                let text = question["question"]?.string ?? ""
                ids[text] = question["id"]?.string ?? text
                return ["question": .string(text), "header": .string(question["header"]?.string ?? ""), "multiSelect": false,
                        "options": .array((question["options"]?.array ?? []).map {
                            ["label": .string($0["label"]?.string ?? ""), "description": .string($0["description"]?.string ?? "")]
                        })]
            }
            pending[requestID] = .questions(id: id, ids: ids)
            return [.event(.permissionRequest(.init(requestID: requestID, toolName: "AskUserQuestion",
                                                    input: ["questions": .array(questions)], toolUseID: itemID)))]
        case "mcpServer/elicitation/request" where params["_meta"]?["codex_approval_kind"]?.string == "mcp_tool_call":
            // Codex asks before each MCP tool call: it goes through Dante's approvals like any
            // other tool (Dante's own local tools are approved without asking).
            let server = params["serverName"]?.string ?? "server"
            let tool = Self.toolName(inApproval: params["message"]?.string ?? "") ?? "tool"
            pending[requestID] = .elicitation(id: id)
            return [.event(.permissionRequest(.init(requestID: requestID, toolName: "mcp__\(server)__\(tool)",
                                                    input: params["_meta"]?["tool_params"] ?? [:], toolUseID: mcpCalls["\(server)/\(tool)"])))]
        case "mcpServer/elicitation/request":
            // A form or link Dante can't show: declined, so Codex carries on.
            return [.reply(["id": id, "result": ["action": "decline"]])]
        default:
            // Anything else Dante can't answer (auth refresh) is turned down, so Codex doesn't
            // wait forever.
            return [.reply(["id": id, "error": ["code": -32601, "message": .string("Dante doesn’t handle \(method).")]])]
        }
    }

    /// The answer to a waiting request: accept or decline, or the user's answers.
    public mutating func reply(to requestID: String, accept: Bool, answers: [String: String] = [:]) -> JSONValue? {
        guard let waiting = pending.removeValue(forKey: requestID) else { return nil }
        switch waiting {
        case .decision(let id):
            return ["id": id, "result": ["decision": .string(accept ? "accept" : "decline")]]
        case .elicitation(let id):
            return accept ? ["id": id, "result": ["action": "accept", "content": [:]]] : ["id": id, "result": ["action": "decline"]]
        case .questions(let id, let ids):
            var result: [String: JSONValue] = [:]
            if accept {
                for (question, answer) in answers {
                    let labels = answer.components(separatedBy: ", ").map { JSONValue.string($0) }
                    result[ids[question] ?? question] = ["answers": .array(labels)]
                }
            }
            return ["id": id, "result": ["answers": .object(result)]]
        }
    }

    /// The tool in Codex's approval message: `Allow the dante MCP server to run tool "look"?`.
    static func toolName(inApproval message: String) -> String? {
        guard let range = message.range(of: "run tool \""), let end = message[range.upperBound...].firstIndex(of: "\"") else { return nil }
        let name = String(message[range.upperBound..<end])
        return name.isEmpty ? nil : name
    }

    /// Codex's patches show as this tool, with a diff per file.
    public static let patchTool = "apply_patch"

    /// `file_path` names the first file, for the row and the approval label; `changes` holds
    /// each file's path, kind and unified diff.
    static func patchInput(_ changes: JSONValue) -> JSONValue {
        let list: [JSONValue] = (changes.array ?? []).map { change in
            let kind = change["kind"]?["type"]?.string ?? change["kind"]?.string ?? "update"
            return ["path": .string(change["path"]?.string ?? ""), "kind": .string(kind), "diff": .string(change["diff"]?.string ?? "")]
        }
        var input: [String: JSONValue] = ["changes": .array(list)]
        if let first = list.first?["path"] { input["file_path"] = first }
        return .object(input)
    }

    private func toolUse(_ id: String, _ name: String, _ input: JSONValue) -> CodexIncoming {
        .event(.assistant(messageID: id, blocks: [.toolUse(id: id, name: name, input: input)]))
    }

    private func result(_ id: String, isError: Bool, _ text: String) -> CodexIncoming {
        .event(.toolResults([.init(toolUseID: id, isError: isError, text: text)]))
    }
}

/// Requests Dante sends to `codex app-server`.
public enum CodexRequest {
    public static func initialize(id: Int) -> JSONValue {
        ["id": .number(Double(id)), "method": "initialize", "params": ["clientInfo": ["name": "dante", "title": "Dante", "version": "1.0"]]]
    }

    public static let initialized: JSONValue = ["method": "initialized"]

    public static func models(id: Int) -> JSONValue {
        ["id": .number(Double(id)), "method": "model/list", "params": [:]]
    }

    /// A new thread, or `resume` an earlier one. Codex asks before every command it doesn't
    /// trust and every patch, and only writes inside the project; Dante decides what's asked.
    public static func thread(id: Int, resume: String?, cwd: String, model: String?, instructions: String, mcp: JSONValue?) -> JSONValue {
        var params: [String: JSONValue] = [
            "cwd": .string(cwd),
            "approvalPolicy": "untrusted",
            "sandbox": "workspace-write",
            "developerInstructions": .string(instructions),
        ]
        if let model, !model.isEmpty { params["model"] = .string(model) }
        if let mcp { params["config"] = ["mcp_servers": ["dante": mcp]] }
        if let resume { params["threadId"] = .string(resume) }
        return ["id": .number(Double(id)), "method": resume == nil ? "thread/start" : "thread/resume", "params": .object(params)]
    }

    /// A message: text, with images by path.
    public static func turn(id: Int, thread: String, text: String, images: [String], model: String?, effort: String?) -> JSONValue {
        var input: [JSONValue] = images.map { ["type": "localImage", "path": .string($0)] }
        input.append(["type": "text", "text": .string(text)])
        var params: [String: JSONValue] = ["threadId": .string(thread), "input": .array(input)]
        if let model, !model.isEmpty { params["model"] = .string(model) }
        if let effort, !effort.isEmpty { params["effort"] = .string(effort) }
        return ["id": .number(Double(id)), "method": "turn/start", "params": .object(params)]
    }

    public static func interrupt(id: Int, thread: String, turn: String) -> JSONValue {
        ["id": .number(Double(id)), "method": "turn/interrupt", "params": ["threadId": .string(thread), "turnId": .string(turn)]]
    }

    public static func compact(id: Int, thread: String) -> JSONValue {
        ["id": .number(Double(id)), "method": "thread/compact/start", "params": ["threadId": .string(thread)]]
    }

    /// The `dante mcp` server for Codex's config: local models, and Claude for second opinions.
    public static func mcpServer(command: String, environment: [String: String]) -> JSONValue {
        // Team members and second opinions take minutes; Codex's default gives up after 60 s.
        var server: [String: JSONValue] = ["command": .string(command), "args": ["mcp"], "tool_timeout_sec": 900, "startup_timeout_sec": 30]
        if !environment.isEmpty { server["env"] = .object(environment.mapValues { .string($0) }) }
        return .object(server)
    }
}

extension Codex {
    /// The models Codex offers this account, asked of a short-lived app server.
    public func models(timeout: TimeInterval = 20) async -> [CodexModel] {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDECODE"] = nil
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let requests = [CodexRequest.initialize(id: 1), CodexRequest.initialized, CodexRequest.models(id: 2)]
        try? input.fileHandleForWriting.write(contentsOf: Data(requests.map { $0.jsonLine + "\n" }.joined().utf8))
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            process.terminate()
        }
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
        }
        for await line in ClaudeSession.lines(from: output.fileHandleForReading) {
            guard let message = JSONValue(line: line), message["id"]?.int == 2 else { continue }
            return CodexModel.parse(message["result"])
        }
        return []
    }
}
