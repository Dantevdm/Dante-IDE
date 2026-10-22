import Foundation

/// A model Ollama has on this Mac (`/api/tags`).
public struct OllamaModel: Equatable, Sendable, Identifiable, Codable {
    public var name: String
    /// Bytes on disk; 0 for cloud models, which run on Ollama's servers.
    public var size: Int64
    public var family: String
    public var parameterSize: String
    public var id: String { name }

    public init(name: String, size: Int64 = 0, family: String = "", parameterSize: String = "") {
        self.name = name
        self.size = size
        self.family = family
        self.parameterSize = parameterSize
    }

    /// Runs on Ollama's servers rather than this Mac, so it saves nothing and sends code away.
    public var isCloud: Bool { name.hasSuffix("-cloud") || name.contains(":cloud") || (size == 0 && !name.isEmpty) }

    /// Image models (llava, -vl, vision): no good for text jobs.
    public var isVision: Bool {
        let lower = name.lowercased()
        return lower.contains("llava") || lower.contains("vision") || lower.contains("-vl") || lower.contains("vl:")
    }

    public var isEmbedding: Bool { name.lowercased().contains("embed") }

    /// "qwen3:14b" without the tag: "qwen3".
    public var base: String { String(name.split(separator: ":").first ?? Substring(name)) }

    public static func parseList(_ data: Data) throws -> [OllamaModel] {
        struct Tags: Decodable {
            struct Model: Decodable {
                var name: String
                var size: Int64?
                var details: Details?
            }
            struct Details: Decodable {
                var family: String?
                var parameter_size: String?
            }
            var models: [Model]
        }
        return try JSONDecoder().decode(Tags.self, from: data).models.map {
            OllamaModel(name: $0.name, size: $0.size ?? 0, family: $0.details?.family ?? "", parameterSize: $0.details?.parameter_size ?? "")
        }
    }
}

/// One answer from a local model, with what it cost.
public struct OllamaReply: Equatable, Sendable {
    public var text: String
    public var promptTokens: Int
    public var outputTokens: Int
    /// Wall time Ollama reports, including loading the model.
    public var seconds: Double
    /// Output tokens per second while generating.
    public var tokensPerSecond: Double

    public init(text: String, promptTokens: Int = 0, outputTokens: Int = 0, seconds: Double = 0, tokensPerSecond: Double = 0) {
        self.text = text
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.seconds = seconds
        self.tokensPerSecond = tokensPerSecond
    }

    /// Reads a non-streamed `/api/chat` response. Thinking (`<think>…</think>`) is dropped.
    public static func parse(_ data: Data) throws -> OllamaReply {
        struct Response: Decodable {
            struct Message: Decodable { var content: String }
            var message: Message?
            var response: String?
            var prompt_eval_count: Int?
            var eval_count: Int?
            var total_duration: Int64?
            var eval_duration: Int64?
            var error: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let error = response.error { throw Ollama.Failure(message: error) }
        let output = response.eval_count ?? 0
        let evalSeconds = Double(response.eval_duration ?? 0) / 1e9
        return OllamaReply(
            text: withoutThinking(response.message?.content ?? response.response ?? ""),
            promptTokens: response.prompt_eval_count ?? 0,
            outputTokens: output,
            seconds: Double(response.total_duration ?? 0) / 1e9,
            tokensPerSecond: evalSeconds > 0 ? Double(output) / evalSeconds : 0
        )
    }

    static func withoutThinking(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Ollama's HTTP API on this Mac: which models are here, and one-shot chats with them.
public struct Ollama: Sendable {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public var base: URL

    public init(base: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.base = base
    }

    /// The models on this Mac, or nil when Ollama isn't running.
    public func models() async -> [OllamaModel]? {
        var request = URLRequest(url: base.appending(path: "api/tags"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? OllamaModel.parseList(data)
    }

    public func chat(model: String, system: String?, prompt: String, maxTokens: Int = 2048, timeout: TimeInterval = 600) async throws -> OllamaReply {
        var request = URLRequest(url: base.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = Self.chatBody(model: model, system: system, prompt: prompt, maxTokens: maxTokens)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(message: "Ollama isn’t answering at \(base.host() ?? "localhost"): \(error.localizedDescription)")
        }
        return try OllamaReply.parse(data)
    }

    /// The `/api/chat` request: not streamed, thinking off, a context big enough for diffs.
    static func chatBody(model: String, system: String?, prompt: String, maxTokens: Int) -> Data {
        var messages: [[String: String]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": prompt])
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "think": false,
            "keep_alive": "10m",
            "options": ["num_ctx": 16384, "num_predict": maxTokens, "temperature": 0.3],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }
}

