import Foundation

/// Options Claude listed in prose and then asked about ("Which of these would you like me
/// to write?"), so the panel can offer them as chips instead of making you type the answer.
/// Claude is asked to use AskUserQuestion for this; this catches the times it doesn't.
public struct ReplyChoices: Equatable, Sendable {
    public struct Option: Equatable, Sendable, Identifiable {
        /// The number Claude gave it, or its place in a bulleted list.
        public var number: Int
        /// The bold lead-in, or the item's first words.
        public var title: String
        public var id: Int { number }
    }

    public var options: [Option]
    public var question: String

    static let titleLength = 60

    /// The last list in a reply, when the reply ends by asking about it.
    public static func parse(_ text: String) -> ReplyChoices? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Each list in the reply, with the index of its last line. Lines under an item, or
        // straight after it, continue it; a paragraph after a blank line ends the list.
        var lists: [(items: [(marker: Int?, text: String)], last: Int)] = []
        var items: [(marker: Int?, text: String)] = []
        var last = -1
        var blank = false
        var fence = false
        func endList() {
            if !items.isEmpty { lists.append((items, last)) }
            items = []
        }
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indented = raw.prefix(while: \.isWhitespace).count >= 2
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence.toggle()
                if !items.isEmpty { last = index }
                continue
            }
            if fence {
                if !items.isEmpty { last = index }
                continue
            }
            if line.isEmpty { blank = true; continue }
            if !indented, let item = listItem(line) {
                items.append(item)
                last = index
            } else if !items.isEmpty, indented || (!blank && !line.hasSuffix("?")) {
                items[items.count - 1].text += " " + line
                last = index
            } else {
                endList()
            }
            blank = false
        }
        endList()
        guard let list = lists.last, list.items.count >= 2, list.items.count <= 12 else { return nil }
        let found = list.items

        // Numbered lists must count up from 1; bullets count only if each starts in bold.
        if found.allSatisfy({ $0.marker != nil }) {
            guard found.enumerated().allSatisfy({ $0.element.marker == $0.offset + 1 }) else { return nil }
        } else {
            guard found.allSatisfy({ $0.marker == nil && $0.text.hasPrefix("**") }) else { return nil }
        }

        // What follows the list must be a short question.
        let after = lines[(list.last + 1)...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard after.contains("?"), after.count <= 300 else { return nil }

        let options = found.enumerated().map { offset, item in
            Option(number: item.marker ?? offset + 1, title: title(of: item.text))
        }
        return ReplyChoices(options: options, question: after)
    }

    /// The message that answers with the chosen options.
    public func reply(choosing numbers: [Int]) -> String {
        let chosen = options.filter { numbers.contains($0.number) }
        switch chosen.count {
        case 0: return ""
        case 1: return "\(chosen[0].number). \(chosen[0].title)"
        default: return chosen.map { "\($0.number). \($0.title)" }.joined(separator: "\n")
        }
    }

    private static func listItem(_ line: String) -> (marker: Int?, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            return (nil, String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    static func title(of text: String) -> String {
        if text.hasPrefix("**"), let end = text.dropFirst(2).range(of: "**") {
            return clean(String(text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound]))
        }
        var title = text
        for separator in [" — ", " – ", " - ", ": ", ". "] {
            if let range = title.range(of: separator) { title = String(title[..<range.lowerBound]) }
        }
        title = clean(title)
        guard title.count > titleLength else { return title }
        let cut = title.prefix(titleLength)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".:—")))
    }
}
