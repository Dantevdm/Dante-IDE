import Foundation

/// A markdown document split into blocks for the Docs reader. Inline syntax (bold, links,
/// `code`) stays in the text; the view renders it. Covers what specs and READMEs use:
/// headings, paragraphs, lists and checklists, quotes, fenced code, tables and rules.
public struct MarkdownDocument: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String, anchor: String)
        case paragraph(String)
        case list([ListItem], ordered: Bool)
        case quote(String)
        case code(String, language: String?)
        case table(header: [String], rows: [[String]])
        case rule
    }

    public struct ListItem: Equatable, Sendable {
        public var text: String
        public var depth: Int
        /// nil for a plain item; true or false for a `- [x]` checklist item.
        public var checked: Bool?
        /// The number shown for an ordered item.
        public var number: Int?
    }

    public var blocks: [Block]

    /// Level 1 and 2 headings, for the outline.
    public var outline: [(level: Int, text: String, anchor: String)] {
        blocks.compactMap {
            if case .heading(let level, let text, let anchor) = $0, level <= 3 { (level, text, anchor) } else { nil }
        }
    }

    /// The first level-1 heading.
    public var title: String? {
        for case .heading(1, let text, _) in blocks { return text }
        return nil
    }

    public init(_ markdown: String) {
        blocks = Self.parse(markdown)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var anchors: [String: Int] = [:]
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        var paragraph: [String] = []

        func flush() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        // YAML front matter isn't part of the document.
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            index = end + 1
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n"), language: language.isEmpty ? nil : language))
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }

            if let heading = Self.heading(trimmed) {
                flush()
                var anchor = Self.slug(heading.text)
                if let seen = anchors[anchor] {
                    anchors[anchor] = seen + 1
                    anchor += "-\(seen + 1)"
                } else {
                    anchors[anchor] = 0
                }
                blocks.append(.heading(level: heading.level, text: heading.text, anchor: anchor))
                index += 1
                continue
            }

            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1,
               let first = trimmed.first, "-*_".contains(first), paragraph.isEmpty {
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: " ")))
                continue
            }

            if trimmed.hasPrefix("|"), index + 1 < lines.count, Self.isTableDivider(lines[index + 1]) {
                flush()
                let header = Self.cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(Self.cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if Self.listItem(line) != nil {
                flush()
                var items: [ListItem] = []
                let ordered = Self.listItem(line)?.number != nil
                while index < lines.count {
                    if let item = Self.listItem(lines[index]) {
                        items.append(item)
                    } else if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, lines[index].hasPrefix("  "), !items.isEmpty {
                        // A wrapped continuation line.
                        items[items.count - 1].text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(items, ordered: ordered))
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flush()
        return blocks
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        var text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        var number: Int?
        var body: Substring
        if let marker = rest.first, "-*+".contains(marker), rest.dropFirst().first == " " {
            body = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let after = rest.dropFirst(digits.count)
            guard let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
            number = Int(digits)
            body = after.dropFirst(2)
        }
        var checked: Bool?
        if body.hasPrefix("[ ] ") {
            checked = false
            body = body.dropFirst(4)
        } else if body.lowercased().hasPrefix("[x] ") {
            checked = true
            body = body.dropFirst(4)
        }
        return ListItem(text: body.trimmingCharacters(in: .whitespaces), depth: indent / 2, checked: checked, number: number)
    }

    static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ row: String) -> [String] {
        var trimmed = row
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// GitHub-style heading anchors: lower case, punctuation dropped, spaces as dashes.
    public static func slug(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "*", with: "")
        return plain.lowercased().unicodeScalars.reduce(into: "") { slug, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "-" {
                slug.append("-")
            }
        }
    }
}
