import Foundation

/// One question from Claude's AskUserQuestion tool, with the options it offers.
public struct ClarifyingQuestion: Equatable, Sendable, Identifiable {
    public struct Option: Equatable, Sendable, Identifiable {
        public var label: String
        public var description: String
        public var id: String { label }
    }

    public var question: String
    /// A short tag such as "Auth method".
    public var header: String
    public var options: [Option]
    public var multiSelect: Bool
    public var id: String { question }

    /// The questions in an AskUserQuestion input, in order.
    public static func parse(_ input: JSONValue) -> [ClarifyingQuestion] {
        (input["questions"]?.array ?? []).compactMap { item in
            guard let question = item["question"]?.string else { return nil }
            let options = (item["options"]?.array ?? []).compactMap { option -> Option? in
                guard let label = option["label"]?.string else { return nil }
                return Option(label: label, description: option["description"]?.string ?? "")
            }
            return ClarifyingQuestion(question: question, header: item["header"]?.string ?? "", options: options,
                                      multiSelect: item["multiSelect"]?.bool ?? false)
        }
    }

    /// Answers already given, keyed by question text, once the user has replied.
    public static func answers(in input: JSONValue) -> [String: String] {
        guard case .object(let answers)? = input["answers"] else { return [:] }
        return answers.compactMapValues(\.string)
    }
}
