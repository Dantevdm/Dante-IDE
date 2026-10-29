import Foundation

/// Completion without a language server: the declarations in the file and across the project,
/// the other words in the file, and the language's keywords, as editors do when no server is
/// installed (TypeScript, Python and Java often have none). The editor ranks what comes back
/// against what's typed, so this only gathers candidates that could match.
public enum WordCompletion {
    /// Where a suggestion came from, best first; it orders equally good matches.
    public enum Source: Int, Comparable, Sendable {
        case here, project, word, keyword

        public static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Item: Equatable, Sendable {
        public var label: String
        public var source: Source
        public var kind: CodeSymbol.Kind?
        /// The file a project declaration is in, or its container.
        public var detail: String?
        /// Times the word appears in the file.
        public var count: Int
    }

    /// The identifier being typed before `offset` (UTF-16).
    public static func prefixRange(in text: NSString, before offset: Int) -> NSRange {
        var start = min(max(0, offset), text.length)
        while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)), isIdentifier(scalar) { start -= 1 }
        return NSRange(location: start, length: min(max(0, offset), text.length) - start)
    }

    public static func suggestions(in text: String, at offset: Int, keywords: [String] = [], here: [CodeSymbol] = [],
                                   project: [CodeSymbol] = [], limit: Int = 80) -> [Item] {
        let ns = text as NSString
        let typed = prefixRange(in: ns, before: offset)
        let prefix = ns.substring(with: typed)
        guard let first = prefix.first, !first.isNumber else { return [] }

        var items: [String: Item] = [:]
        func offer(_ label: String, _ source: Source, kind: CodeSymbol.Kind? = nil, detail: String? = nil, count: Int = 0) {
            guard label != prefix, label.count > 1, matches(prefix, label) else { return }
            if var existing = items[label] {
                if source < existing.source { existing.source = source; existing.kind = kind ?? existing.kind; existing.detail = detail ?? existing.detail }
                existing.count += count
                items[label] = existing
            } else {
                items[label] = Item(label: label, source: source, kind: kind, detail: detail, count: count)
            }
        }

        for symbol in here { offer(symbol.name, .here, kind: symbol.kind, detail: symbol.container) }
        for symbol in project {
            offer(symbol.name, .project, kind: symbol.kind, detail: symbol.container ?? symbol.url.lastPathComponent)
        }
        for (word, count) in words(in: ns, skipping: typed) where word.count >= 3 { offer(word, .word, count: count) }
        for keyword in keywords { offer(keyword, .keyword) }

        return items.values.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.label < $1.label
        }
        .prefix(limit).map { $0 }
    }

    /// Words a typed prefix could be heading for: the same first letter (either case) and the
    /// rest of the prefix in order, so "usrSvc" finds "userService".
    static func matches(_ prefix: String, _ label: String) -> Bool {
        guard let p = prefix.first, let l = label.first, p.lowercased() == l.lowercased() else { return false }
        var rest = label.lowercased()[...]
        for character in prefix.lowercased() {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }

    private static let wordPattern = try! NSRegularExpression(pattern: "[A-Za-z_$][A-Za-z0-9_$]*")

    /// Identifiers in the text with their counts, leaving out the one being typed. Very long
    /// files are read around the caret.
    static func words(in text: NSString, skipping typed: NSRange, window: Int = 400_000) -> [String: Int] {
        let start = max(0, min(typed.location - window / 2, text.length - window))
        let range = NSRange(location: start, length: min(window, text.length - start))
        var counts: [String: Int] = [:]
        wordPattern.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match, match.range.location != typed.location || typed.length == 0 else { return }
            counts[text.substring(with: match.range), default: 0] += 1
        }
        return counts
    }

    private static func isIdentifier(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
    }
}
