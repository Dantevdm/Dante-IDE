import Foundation

/// Claude editing code in place (⌘I): the selection, widened to whole lines, is replaced by
/// what Claude writes. With nothing selected Claude writes code to insert at the caret.
public enum InlineEdit {
    public static let system = """
        You edit code inside an editor. Reply with only the code that replaces the selection, or \
        that goes at the cursor: no explanation, no markdown, no code fences. Match the file's \
        indentation and style, and keep anything in the selection the instruction doesn't ask to change.
        """

    /// Whole lines covering `range`, without the last newline's line when the range ends at a
    /// line start. An empty range stays where it is (an insertion).
    public static func lineRange(for range: NSRange, in text: NSString) -> NSRange {
        guard range.length > 0 else { return range }
        var end = NSMaxRange(range)
        if end > range.location, end <= text.length, text.character(at: end - 1) == 0x0A { end -= 1 }
        let lines = text.lineRange(for: NSRange(location: range.location, length: max(end - range.location, 0)))
        return lines
    }

    /// The request: the instruction, the file around the selection, and the selection itself.
    /// `previous` is an earlier attempt being refined.
    public static func prompt(instruction: String, path: String, language: Language, text: NSString,
                              range: NSRange, previous: String? = nil) -> String {
        let before = text.substring(to: range.location)
        let after = text.substring(from: NSMaxRange(range))
        let beforeLines = before.components(separatedBy: "\n").suffix(80).joined(separator: "\n")
        let afterLines = after.components(separatedBy: "\n").prefix(40).joined(separator: "\n")
        var parts = ["File: \(path) (\(language.displayName))"]
        if range.length > 0 {
            parts.append("Code before the selection:\n\(beforeLines)")
            parts.append("The selection:\n<selection>\n\(text.substring(with: range))</selection>")
            parts.append("Code after the selection:\n\(afterLines)")
            parts.append("Instruction: \(instruction)\n\nReply with the code that replaces the selection.")
        } else {
            parts.append("The file around the cursor, which is marked <cursor/>:\n\(beforeLines)<cursor/>\(afterLines)")
            parts.append("Instruction: \(instruction)\n\nReply with the code to insert at the cursor.")
        }
        if let previous {
            parts.insert("Your previous attempt, to change as the instruction says:\n\(previous)", at: parts.count - 1)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Strips a code fence or lead-in, and keeps the selection's trailing newline.
    public static func clean(_ answer: String, replacing original: String) -> String {
        var lines = answer.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first, first.lowercased().hasPrefix("here"), first.hasSuffix(":") { lines.removeFirst() }
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
            if let close = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
                lines.removeSubrange(close...)
            }
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        var code = lines.joined(separator: "\n")
        if original.hasSuffix("\n"), !code.isEmpty { code += "\n" }
        return code
    }
}
