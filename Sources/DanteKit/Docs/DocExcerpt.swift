import Foundation

/// A line or two that says what a doc is about, for the Docs library: the front matter's
/// `description:` when there is one, else the first real paragraph, with markdown taken out.
public enum DocExcerpt {
    public static let length = 180

    public static func of(_ markdown: String) -> String? {
        if let description = frontMatterDescription(markdown) { return shortened(description) }
        for block in MarkdownDocument(markdown).blocks {
            let text: String
            switch block {
            case .paragraph(let paragraph), .quote(let paragraph): text = plain(paragraph)
            default: continue
            }
            // Badges, a lone link, "Status: draft": not what the doc is about.
            guard text.filter(\.isLetter).count >= 24 else { continue }
            return shortened(text)
        }
        return nil
    }

    static func frontMatterDescription(_ markdown: String) -> String? {
        let lines = markdown.prefix(4000).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        for line in lines[1..<end] where line.hasPrefix("description:") {
            var value = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static let images = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]*\)"#)
    private static let links = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)
    private static let tags = try! NSRegularExpression(pattern: #"</?[A-Za-z][^>]*>"#)
    private static let emphasis = try! NSRegularExpression(pattern: #"(\*\*|__|\*|`|~~)"#)
    private static let spaces = try! NSRegularExpression(pattern: #"\s+"#)

    /// The text a reader sees: images and tags gone, links as their words, no emphasis marks.
    static func plain(_ text: String) -> String {
        var result = text
        for (pattern, template) in [(images, ""), (links, "$1"), (tags, ""), (emphasis, ""), (spaces, " ")] {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Up to `length` characters, cut at a word with an ellipsis.
    static func shortened(_ text: String) -> String {
        guard text.count > length else { return text }
        let cut = text.prefix(length)
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return word.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}
