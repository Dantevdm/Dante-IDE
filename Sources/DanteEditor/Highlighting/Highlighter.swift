import DanteKit
import Foundation

public enum TokenKind: Sendable, Equatable {
    case keyword, string, comment, number, type, function
}

public struct Token: Sendable, Equatable {
    public let range: NSRange
    public let kind: TokenKind

    public init(range: NSRange, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Turns source text into coloured tokens. `TreeSitterHighlighter` handles the
/// languages Dante bundles a grammar for; `RegexHighlighter` covers the rest.
public protocol Highlighter: Sendable {
    func tokens(in text: String) -> [Token]
}

public enum Highlighters {
    public static func make(for language: Language) -> any Highlighter {
        TreeSitterHighlighter.make(for: language) ?? RegexHighlighter(spec: .for(language))
    }
}

/// Lexical highlighting from regular expressions.
///
/// Comments and strings are found in one left-to-right pass, so whichever
/// starts first wins (a `//` inside a string stays part of the string). Other
/// rules never colour text inside those ranges.
public struct RegexHighlighter: Highlighter {
    private let compiled: Compiled

    public init(spec: LanguageSpec) {
        compiled = Compiled(spec: spec)
    }

    public func tokens(in text: String) -> [Token] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var tokens: [Token] = []
        var protected = IndexSet()

        if let regex = compiled.protectedRegex {
            for match in regex.matches(in: text, range: full) {
                let comment = match.range(withName: "comment")
                let kind: TokenKind = comment.location != NSNotFound ? .comment : .string
                tokens.append(Token(range: match.range, kind: kind))
                protected.insert(integersIn: Range(match.range)!)
            }
        }

        for (regex, kind, group) in compiled.rules {
            for match in regex.matches(in: text, range: full) {
                let range = group == 0 ? match.range : match.range(at: group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                if protected.intersects(integersIn: Range(range)!) { continue }
                tokens.append(Token(range: range, kind: kind))
                protected.insert(integersIn: Range(range)!)
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    /// NSRegularExpression is immutable and safe to share across threads.
    private final class Compiled: @unchecked Sendable {
        let protectedRegex: NSRegularExpression?
        /// Applied in order; earlier rules win where they overlap.
        let rules: [(NSRegularExpression, TokenKind, Int)]

        init(spec: LanguageSpec) {
            var protectedParts: [String] = []
            var commentParts: [String] = []
            if let (open, close) = spec.blockComment {
                commentParts.append(NSRegularExpression.escapedPattern(for: open) + "[\\s\\S]*?(?:" + NSRegularExpression.escapedPattern(for: close) + "|$(?![\\s\\S]))")
            }
            for prefix in spec.lineComments {
                commentParts.append(NSRegularExpression.escapedPattern(for: prefix) + "[^\\n]*")
            }
            if !commentParts.isEmpty {
                protectedParts.append("(?<comment>" + commentParts.joined(separator: "|") + ")")
            }
            var stringParts: [String] = []
            for delimiter in spec.multilineStrings {
                let d = NSRegularExpression.escapedPattern(for: delimiter)
                stringParts.append(d + "[\\s\\S]*?" + d)
            }
            for quote in spec.strings {
                let q = NSRegularExpression.escapedPattern(for: String(quote))
                let newline = quote == "`" ? "" : "\\n"
                stringParts.append(q + "(?:\\\\.|[^" + q + "\\\\" + newline + "])*" + q)
            }
            if !stringParts.isEmpty {
                protectedParts.append("(?<string>" + stringParts.joined(separator: "|") + ")")
            }
            protectedRegex = protectedParts.isEmpty ? nil : try? NSRegularExpression(
                pattern: protectedParts.joined(separator: "|"),
                options: [.anchorsMatchLines]
            )

            var rules: [(NSRegularExpression, TokenKind, Int)] = []
            func add(_ pattern: String, _ kind: TokenKind, group: Int = 0, options: NSRegularExpression.Options = [.anchorsMatchLines]) {
                if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
                    rules.append((regex, kind, group))
                }
            }
            for (pattern, kind) in spec.extraRules { add(pattern, kind, group: 1) }
            if !spec.keywords.isEmpty {
                let words = spec.keywords.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
                add("(?<![\\w$.])(" + words.joined(separator: "|") + ")(?![\\w$])", .keyword, group: 1,
                    options: spec.caseInsensitiveKeywords ? [.anchorsMatchLines, .caseInsensitive] : [.anchorsMatchLines])
            }
            if spec.highlightsCode {
                add("(?<![\\w$])(0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d[\\d_]*)?(?:[eE][+-]?\\d+)?)(?![\\w$])", .number, group: 1)
                add("(?<![\\w$])([A-Z][A-Za-z0-9_]*)(?![\\w$])", .type, group: 1)
                add("(?<![\\w$])([a-z_$][A-Za-z0-9_$]*)(?=\\s*\\()", .function, group: 1)
            }
            self.rules = rules
        }
    }
}
