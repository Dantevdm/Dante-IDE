import Foundation

/// "Reply to Ana that Thursday works": who to answer and what to say, from speech. The Mac
/// finds that person's latest email and opens a reply in Outlook for you to send; nothing is
/// ever sent for you.
public struct MailReply: Equatable, Sendable {
    /// The person as said ("Ana", "Ana Sousa").
    public var who: String
    /// What to say, as said ("Thursday works").
    public var says: String

    public init(who: String, says: String) {
        self.who = who
        self.says = says
    }

    static let openings = ["reply to ", "respond to ", "answer ", "write back to ", "email back ", "mail back ", "reply back to "]
    static let joins = [" that ", " saying ", " and say ", " and tell them ", " and tell him ", " and tell her ", " to say ", " with: ", " with ", ": "]
    static let owned = ["'s email", "'s mail", "'s message", "s email", " email", " mail"]

    /// Reads a spoken request; nil when it isn't one.
    public static func parse(_ utterance: String) -> MailReply? {
        var text = utterance.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "’", with: "'")
        // Greetings and politeness before the request.
        var lowered = text.lowercased()
        var trimmed = true
        while trimmed {
            trimmed = false
            for lead in ["hey dante", "dante", "ok", "okay", "please", "can you", "could you", "would you"] where lowered.hasPrefix(lead + " ") || lowered.hasPrefix(lead + ",") {
                text = String(text.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                lowered = text.lowercased()
                trimmed = true
            }
        }
        guard let opening = openings.first(where: { lowered.hasPrefix($0) }) else { return nil }
        let rest = String(text.dropFirst(opening.count))
        let lowerRest = rest.lowercased()
        // The earliest join splits the person from the message.
        guard let join = joins.compactMap({ join in lowerRest.range(of: join).map { (join, $0) } }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) else { return nil }
        let start = lowerRest.distance(from: lowerRest.startIndex, to: join.1.lowerBound)
        let end = lowerRest.distance(from: lowerRest.startIndex, to: join.1.upperBound)
        var who = String(rest.prefix(start)).trimmingCharacters(in: .whitespaces)
        var says = String(rest.dropFirst(end)).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:")))
        for suffix in owned where who.lowercased().hasSuffix(suffix) { who = String(who.dropLast(suffix.count)) }
        if who.lowercased().hasPrefix("the email from ") { who = String(who.dropFirst("the email from ".count)) }
        if who.lowercased().hasPrefix("the ") { who = String(who.dropFirst(4)) }
        who = who.trimmingCharacters(in: .whitespaces)
        if says.lowercased().hasPrefix("please ") { says = String(says.dropFirst(7)) }
        guard !who.isEmpty, who.split(separator: " ").count <= 3, !says.isEmpty else { return nil }
        return MailReply(who: who, says: says)
    }

    /// The reply's text: a greeting by first name, what was said as a sentence, and your name.
    public func body(firstName: String, signedBy name: String?) -> String {
        var sentence = says.trimmingCharacters(in: .whitespacesAndNewlines)
        sentence = sentence.prefix(1).uppercased() + sentence.dropFirst()
        if let last = sentence.last, !".!?".contains(last) { sentence += "." }
        var lines = ["Hi \(firstName),", "", sentence]
        if let name, !name.isEmpty { lines += ["", name] }
        return lines.joined(separator: "\n")
    }
}
