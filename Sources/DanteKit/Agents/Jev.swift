import Foundation

/// One question for Jev about the material it's given.
public enum JevQuestion: Equatable, Sendable {
    /// Pick one of the options (label → what it means).
    case choice(instructions: String, options: [String: String])
    /// Rate on levels from low to high (2–10 of them).
    case score(instructions: String, levels: [String])
    /// How likely the answer is yes.
    case yesNo(instructions: String)

    var json: JSONValue {
        switch self {
        case .choice(let instructions, let options):
            ["type": "choice", "instructions": .string(instructions), "criteria": .object(options.mapValues { .string($0) })]
        case .score(let instructions, let levels):
            ["type": "score", "instructions": .string(instructions), "criteria": .array(levels.map { .string($0) })]
        case .yesNo(let instructions):
            ["type": "noul", "instructions": .string(instructions)]
        }
    }

    /// Reads a question as Claude passes it to the `decide` tool: a type, instructions, and
    /// options (an object, or a list of labels) or levels.
    public static func parse(_ value: JSONValue) -> JevQuestion? {
        guard let instructions = value["instructions"]?.string, !instructions.isEmpty else { return nil }
        switch value["type"]?.string?.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "choice":
            var options: [String: String] = [:]
            if let object = value["options"]?.object {
                for (label, meaning) in object { options[label] = meaning.string ?? label }
            } else if let labels = value["options"]?.array?.compactMap(\.string) {
                for label in labels { options[label] = label }
            }
            return options.count >= 2 ? .choice(instructions: instructions, options: options) : nil
        case "score":
            let levels = value["levels"]?.array?.compactMap(\.string) ?? []
            return (2...10).contains(levels.count) ? .score(instructions: instructions, levels: levels) : nil
        case "yes_no", "yesno", "noul", "bool", "boolean":
            return .yesNo(instructions: instructions)
        default:
            return nil
        }
    }
}

/// Jev's answer to one question.
public enum JevAnswer: Equatable, Sendable {
    case choice(String, confidence: Double)
    /// The level's index, low to high (it can fall between levels).
    case score(Double)
    /// The probability of yes.
    case yesNo(Double)
}

/// What Jev decided, and what it cost.
public struct JevDecision: Equatable, Sendable {
    public var model: String
    public var answers: [String: JevAnswer]
    public var inputTokens: Int
    public var costUSD: Double
    public var creditsRemainingUSD: Double?

    public init(model: String, answers: [String: JevAnswer], inputTokens: Int = 0, costUSD: Double = 0, creditsRemainingUSD: Double? = nil) {
        self.model = model
        self.answers = answers
        self.inputTokens = inputTokens
        self.costUSD = costUSD
        self.creditsRemainingUSD = creditsRemainingUSD
    }

    public static func parse(_ data: Data) throws -> JevDecision {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Jev.Failure(message: "Jev sent something that isn’t JSON.")
        }
        if let message = Jev.errorMessage(root) { throw Jev.Failure(message: message) }
        var answers: [String: JevAnswer] = [:]
        for (name, answer) in root["answers"]?.object ?? [:] {
            switch answer["type"]?.string {
            case "choice":
                if let choice = answer["choice"]?.string {
                    answers[name] = .choice(choice, confidence: answer["confidence"]?.double ?? 0)
                }
            case "score":
                if let score = answer["score"]?.double { answers[name] = .score(score) }
            case "noul":
                if let yes = answer["noul"]?.double { answers[name] = .yesNo(yes) }
            default:
                continue
            }
        }
        return JevDecision(model: root["model"]?.string ?? "jev", answers: answers,
                           inputTokens: root["usage"]?["input_tokens"]?.int ?? 0,
                           costUSD: root["usage"]?["cost_usd"]?.double ?? 0,
                           creditsRemainingUSD: root["usage"]?["credits_remaining_usd"]?.double)
    }

    /// One line per question, in the order asked, for Claude.
    public func summary(_ questions: [(name: String, question: JevQuestion)]) -> String {
        questions.map { name, question in
            guard let answer = answers[name] else { return "\(name): no answer" }
            switch answer {
            case .choice(let label, let confidence):
                return "\(name): \(label) (\(Self.percent(confidence)) sure)"
            case .score(let score):
                if case .score(_, let levels) = question, !levels.isEmpty {
                    let index = min(levels.count - 1, max(0, Int(score.rounded())))
                    return "\(name): \(levels[index]) (\(String(format: "%.1f", score)) on 0–\(levels.count - 1))"
                }
                return "\(name): \(String(format: "%.1f", score))"
            case .yesNo(let yes):
                return "\(name): \(yes >= 0.5 ? "yes" : "no") (\(Self.percent(yes)) yes)"
            }
        }.joined(separator: "\n")
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// Jev's decide API: material plus typed questions in, typed answers out in well under a
/// second. Priced by input tokens only.
public struct Jev: Sendable {
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static let endpoint = URL(string: "https://jevtypesafeai.com/api/v1/decide")!
    public static let defaultModel = "jev-latest"

    public var key: String
    public var endpoint: URL

    public init(key: String, endpoint: URL = Jev.endpoint) {
        self.key = key
        self.endpoint = endpoint
    }

    /// The request body. Questions keep their names; `state` is the material to judge.
    public static func body(state: JSONValue, questions: [(name: String, question: JevQuestion)], model: String = defaultModel) -> Data {
        var asked: [String: JSONValue] = [:]
        for (name, question) in questions { asked[name] = question.json }
        let body: JSONValue = ["model": .string(model), "state": state, "questions": .object(asked)]
        return Data(body.jsonLine.utf8)
    }

    public func decide(state: JSONValue, questions: [(name: String, question: JevQuestion)], model: String = defaultModel) async throws -> JevDecision {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = Self.body(state: state, questions: questions, model: model)
        // A 502 is Jev's own hiccup; it asks for a retry with backoff.
        for attempt in 0..<3 {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw Failure(message: "Couldn’t reach Jev: \(error.localizedDescription)")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 502, attempt < 2 {
                try? await Task.sleep(for: .milliseconds(400 << attempt))
                continue
            }
            guard status == 200 else { throw Failure(message: Self.explain(status: status, body: data)) }
            return try JevDecision.parse(data)
        }
        throw Failure(message: "Jev is having trouble (502). Try again shortly.")
    }

    /// Checks a key with the smallest possible question.
    public func check() async throws -> JevDecision {
        try await decide(state: "ok", questions: [("fine", .yesNo(instructions: "Is this text the word ok?"))])
    }

    static func errorMessage(_ root: JSONValue) -> String? {
        if let message = root["error"]?.string { return message }
        if let message = root["error"]?["message"]?.string { return message }
        return nil
    }

    static func explain(status: Int, body: Data) -> String {
        let detail = (try? JSONDecoder().decode(JSONValue.self, from: body)).flatMap(errorMessage)
        let reason = switch status {
        case 400: "Jev couldn’t read the request"
        case 401: "Jev didn’t accept the API key"
        case 402: "The Jev account is out of credit"
        case 403: "The Jev account isn’t active"
        case 413: "That’s too much material for Jev at once"
        case 415: "Jev couldn’t read the encoding"
        default: "Jev answered \(status)"
        }
        return detail.map { "\(reason): \($0)" } ?? "\(reason)."
    }
}
