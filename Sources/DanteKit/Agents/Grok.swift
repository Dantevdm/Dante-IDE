import Foundation

/// One answer from Grok, with what it used.
public struct GrokReply: Equatable, Sendable {
    public var text: String
    public var model: String
    public var promptTokens: Int
    public var outputTokens: Int
    public var seconds: Double

    public init(text: String, model: String, promptTokens: Int = 0, outputTokens: Int = 0, seconds: Double = 0) {
        self.text = text
        self.model = model
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.seconds = seconds
    }

    /// Reads a chat completion (OpenAI's shape, which xAI follows).
    public static func parse(_ data: Data, seconds: Double = 0) throws -> GrokReply {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Grok.Failure(message: "Grok sent something that isn’t JSON.")
        }
        if let message = Grok.errorMessage(root) { throw Grok.Failure(message: message) }
        guard let message = root["choices"]?.array?.first?["message"] else {
            throw Grok.Failure(message: "Grok’s reply had no message.")
        }
        let text = message["content"]?.string ?? ""
        return GrokReply(text: OllamaReply.withoutThinking(text), model: root["model"]?.string ?? "grok",
                         promptTokens: root["usage"]?["prompt_tokens"]?.int ?? 0,
                         outputTokens: root["usage"]?["completion_tokens"]?.int ?? 0,
                         seconds: seconds)
    }
}

/// xAI's API, which follows OpenAI's: models and one-shot chats with the user's key.
public struct Grok: Sendable {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static let base = URL(string: "https://api.x.ai/v1")!

    public var key: String
    public var base: URL

    public init(key: String, base: URL = Grok.base) {
        self.key = key
        self.base = base
    }

    /// The models the key can use, newest-looking first.
    public func models() async throws -> [String] {
        var request = URLRequest(url: base.appending(path: "models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await send(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: Self.explain(response, data)) }
        return Self.parseModels(data)
    }

    public func chat(model: String, system: String?, prompt: String, maxTokens: Int = 4096) async throws -> GrokReply {
        var request = URLRequest(url: base.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = Self.chatBody(model: model, system: system, prompt: prompt, maxTokens: maxTokens)
        let started = Date()
        let (data, response) = try await send(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: Self.explain(response, data)) }
        return try GrokReply.parse(data, seconds: Date().timeIntervalSince(started))
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(message: "Couldn’t reach xAI: \(error.localizedDescription)")
        }
    }

    static func chatBody(model: String, system: String?, prompt: String, maxTokens: Int) -> Data {
        var messages: [JSONValue] = []
        if let system { messages.append(["role": "system", "content": .string(system)]) }
        messages.append(["role": "user", "content": .string(prompt)])
        let body: JSONValue = ["model": .string(model), "messages": .array(messages), "stream": false,
                               "max_tokens": .number(Double(maxTokens)), "temperature": .number(0.3)]
        return Data(body.jsonLine.utf8)
    }

    /// Model ids from `/v1/models`, chat models only, best first.
    public static func parseModels(_ data: Data) -> [String] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        let ids = (root["data"]?.array ?? root["models"]?.array ?? []).compactMap { $0["id"]?.string }
        return ids.filter(isChatModel).sorted { rank($0) > rank($1) }
    }

    /// Image, video and embedding models can't answer a text prompt.
    static func isChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.contains("grok") && !["image", "imagine", "video", "vision", "embed", "tts", "voice"].contains { lower.contains($0) }
    }

    /// Higher for newer and bigger: the version number first, then full models before mini
    /// and fast ones, then the name.
    static func rank(_ id: String) -> (Double, Int, String) {
        let lower = id.lowercased()
        let version = lower.split(separator: "-").lazy.compactMap { Double($0) }.first ?? 0
        let light = ["mini", "fast", "nano", "lite"].contains { lower.contains($0) } ? 0 : 1
        return (version, light, lower)
    }

    /// The model to use: the chosen one if the key has it, else the best.
    public static func model(chosen: String?, available: [String]) -> String? {
        if let chosen, !chosen.isEmpty, available.isEmpty || available.contains(chosen) { return chosen }
        return available.first
    }

    static func errorMessage(_ root: JSONValue) -> String? {
        if let message = root["error"]?.string { return message }
        if let message = root["error"]?["message"]?.string { return message }
        return nil
    }

    static func explain(_ response: URLResponse?, _ data: Data) -> String {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let detail = (try? JSONDecoder().decode(JSONValue.self, from: data)).flatMap(errorMessage)
        let reason = switch status {
        case 400: "xAI couldn’t use the request"
        case 401, 403: "xAI didn’t accept the API key"
        case 404: "xAI doesn’t have that model"
        case 429: "xAI’s rate limit or credit ran out"
        default: "xAI answered \(status)"
        }
        return detail.map { "\(reason): \($0)" } ?? "\(reason)."
    }
}
