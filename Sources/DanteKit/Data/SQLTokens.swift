import Foundation

/// A light SQL tokenizer for reading DDL and WHERE clauses: names keep their case,
/// quoted names lose their quotes, comments go away.
public struct SQLToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case word
        /// A "quoted" or `quoted` name.
        case quotedName
        case string
        case number
        case symbol
    }

    public var kind: Kind
    public var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    /// A word or quoted name.
    public var isName: Bool { kind == .word || kind == .quotedName }
    /// Lowercased, for keyword checks; quoted names never match keywords.
    public var keyword: String { kind == .word ? text.lowercased() : "" }

    public static func tokens(_ sql: String) -> [SQLToken] {
        let chars = Array(sql)
        var result: [SQLToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c.isWhitespace { i += 1; continue }
            if c == "-", next == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", next == "*" {
                i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                let close = c
                var text = ""
                i += 1
                while i < chars.count {
                    if chars[i] == close {
                        if i + 1 < chars.count, chars[i + 1] == close { text.append(close); i += 2; continue }
                        i += 1
                        break
                    }
                    text.append(chars[i]); i += 1
                }
                result.append(SQLToken(c == "'" ? .string : .quotedName, text))
                continue
            }
            if c.isLetter || c == "_" {
                var text = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "$" { text.append(chars[i]); i += 1 }
                result.append(SQLToken(.word, text))
                continue
            }
            if c.isNumber {
                var text = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." { text.append(chars[i]); i += 1 }
                result.append(SQLToken(.number, text))
                continue
            }
            // Two-character operators.
            if let next, ["<=", ">=", "<>", "!=", "::", "~~"].contains(String([c, next])) {
                result.append(SQLToken(.symbol, String([c, next])))
                i += 2
                continue
            }
            result.append(SQLToken(.symbol, String(c)))
            i += 1
        }
        return result
    }
}

/// Walks a token list, for small recursive-descent readers.
struct SQLTokenReader {
    let tokens: [SQLToken]
    var index = 0

    init(_ sql: String) {
        tokens = SQLToken.tokens(sql)
    }

    var isAtEnd: Bool { index >= tokens.count }
    var current: SQLToken? { index < tokens.count ? tokens[index] : nil }
    func peek(_ offset: Int = 0) -> SQLToken? { index + offset < tokens.count ? tokens[index + offset] : nil }

    /// Consumes the keywords if they come next, in order.
    mutating func accept(_ keywords: String...) -> Bool {
        for (offset, word) in keywords.enumerated() where peek(offset)?.keyword != word { return false }
        index += keywords.count
        return true
    }

    mutating func acceptSymbol(_ symbol: String) -> Bool {
        guard current?.kind == .symbol, current?.text == symbol else { return false }
        index += 1
        return true
    }

    /// A possibly qualified name: a, a.b, "a"."b". Returns the parts.
    mutating func name() -> [String]? {
        guard let first = current, first.isName else { return nil }
        var parts = [first.text]
        index += 1
        while current?.text == ".", current?.kind == .symbol, let part = peek(1), part.isName {
            parts.append(part.text)
            index += 2
        }
        return parts
    }

    /// Skips to just past the parenthesis that closes the one just consumed.
    mutating func skipParenthesised() {
        var depth = 1
        while let token = current, depth > 0 {
            if token.kind == .symbol, token.text == "(" { depth += 1 }
            if token.kind == .symbol, token.text == ")" { depth -= 1 }
            index += 1
        }
    }

    /// The tokens up to the next top-level comma or closing parenthesis, which isn't consumed.
    mutating func element() -> [SQLToken] {
        var depth = 0
        var result: [SQLToken] = []
        while let token = current {
            if token.kind == .symbol {
                if token.text == "(" { depth += 1 }
                if token.text == ")" { if depth == 0 { break }; depth -= 1 }
                if token.text == ",", depth == 0 { break }
            }
            result.append(token)
            index += 1
        }
        return result
    }
}
