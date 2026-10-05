import Foundation

/// One message from `claude --output-format stream-json`, reduced to what Dante shows.
/// See the Claude Agent SDK for the full shapes; anything unrecognised becomes `.ignored`.
public enum ClaudeEvent: Equatable, Sendable {
    /// The session is up. Sent once, after the first user message.
    case started(sessionID: String, model: String)
    /// A new assistant message is streaming in.
    case messageStarted(messageID: String)
    /// A content block opened in the streaming message.
    case blockStarted(isText: Bool)
    /// More text for the streaming message's latest text block.
    case textDelta(String)
    /// A complete assistant message (Claude Code sends one per content block).
    case assistant(messageID: String, blocks: [AssistantBlock])
    /// Results for tools Claude ran.
    case toolResults([ToolResult])
    /// Claude wants to use a tool that needs the user's approval.
    case permissionRequest(PermissionRequest)
    /// The turn finished.
    case result(TurnResult)
    case ignored

    public enum AssistantBlock: Equatable, Sendable {
        case text(String)
        case toolUse(id: String, name: String, input: JSONValue)
    }

    public struct ToolResult: Equatable, Sendable {
        public var toolUseID: String
        public var isError: Bool
        public var text: String
    }

    public struct PermissionRequest: Equatable, Sendable {
        public var requestID: String
        public var toolName: String
        public var input: JSONValue
        public var toolUseID: String?
    }

    public struct TurnResult: Equatable, Sendable {
        public var isError: Bool
        public var text: String
        public var costUSD: Double?
        public var durationMS: Int?
    }

    /// Parses one line of stream-json output. Messages from subagents (those with a
    /// `parent_tool_use_id`) are ignored apart from permission requests, which always surface.
    public init(line: String) {
        guard let json = JSONValue(line: line) else { self = .ignored; return }
        self.init(json: json)
    }

    public init(json: JSONValue) {
        let isSubagent = json["parent_tool_use_id"].map { !$0.isNull } ?? false
        switch json["type"]?.string {
        case "system" where json["subtype"]?.string == "init":
            self = .started(sessionID: json["session_id"]?.string ?? "", model: json["model"]?.string ?? "")

        case "stream_event" where !isSubagent:
            let event = json["event"]
            switch event?["type"]?.string {
            case "message_start":
                self = .messageStarted(messageID: event?["message"]?["id"]?.string ?? "")
            case "content_block_start":
                self = .blockStarted(isText: event?["content_block"]?["type"]?.string == "text")
            case "content_block_delta" where event?["delta"]?["type"]?.string == "text_delta":
                self = .textDelta(event?["delta"]?["text"]?.string ?? "")
            default:
                self = .ignored
            }

        case "assistant" where !isSubagent:
            let message = json["message"]
            let blocks: [AssistantBlock] = (message?["content"]?.array ?? []).compactMap { block in
                switch block["type"]?.string {
                case "text": .text(block["text"]?.string ?? "")
                case "tool_use": .toolUse(id: block["id"]?.string ?? "", name: block["name"]?.string ?? "", input: block["input"] ?? [:])
                default: nil
                }
            }
            self = blocks.isEmpty ? .ignored : .assistant(messageID: message?["id"]?.string ?? "", blocks: blocks)

        case "user" where !isSubagent:
            let results: [ToolResult] = (json["message"]?["content"]?.array ?? []).compactMap { block in
                guard block["type"]?.string == "tool_result", let id = block["tool_use_id"]?.string else { return nil }
                return ToolResult(toolUseID: id, isError: block["is_error"]?.bool ?? false, text: Self.text(of: block["content"]))
            }
            self = results.isEmpty ? .ignored : .toolResults(results)

        case "control_request" where json["request"]?["subtype"]?.string == "can_use_tool":
            let request = json["request"]
            self = .permissionRequest(PermissionRequest(
                requestID: json["request_id"]?.string ?? "",
                toolName: request?["tool_name"]?.string ?? "",
                input: request?["input"] ?? [:],
                toolUseID: request?["tool_use_id"]?.string
            ))

        case "result":
            self = .result(TurnResult(
                isError: json["is_error"]?.bool ?? (json["subtype"]?.string != "success"),
                text: json["result"]?.string ?? "",
                costUSD: json["total_cost_usd"]?.double,
                durationMS: json["duration_ms"]?.int
            ))

        default:
            self = .ignored
        }
    }

    /// Tool result content is a string or a list of content blocks.
    private static func text(of content: JSONValue?) -> String {
        if let string = content?.string { return string }
        return (content?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
    }
}

/// Messages Dante writes to Claude Code's stdin.
public enum ClaudeInput {
    public static func initialize(requestID: String) -> JSONValue {
        ["type": "control_request", "request_id": .string(requestID), "request": ["subtype": "initialize", "hooks": nil]]
    }

    public static func userMessage(_ text: String) -> JSONValue {
        ["type": "user", "message": ["role": "user", "content": .string(text)], "parent_tool_use_id": nil]
    }

    public static func allow(requestID: String, input: JSONValue) -> JSONValue {
        controlResponse(requestID: requestID, ["behavior": "allow", "updatedInput": input])
    }

    public static func deny(requestID: String, message: String) -> JSONValue {
        controlResponse(requestID: requestID, ["behavior": "deny", "message": .string(message)])
    }

    public static func interrupt(requestID: String) -> JSONValue {
        ["type": "control_request", "request_id": .string(requestID), "request": ["subtype": "interrupt"]]
    }

    private static func controlResponse(requestID: String, _ response: JSONValue) -> JSONValue {
        ["type": "control_response", "response": ["subtype": "success", "request_id": .string(requestID), "response": response]]
    }
}
