import Foundation

/// One statement from a SQL script, and what running it would do.
public struct SQLStatement: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Returns rows and changes nothing: SELECT, WITH … SELECT, EXPLAIN, SHOW, VALUES.
        case read
        /// Changes rows: INSERT, UPDATE, DELETE, MERGE, COPY.
        case write
        /// Changes the schema or the server: CREATE, ALTER, DROP, GRANT…
        case schema
        /// Transaction control and session settings: BEGIN, COMMIT, SET.
        case control
    }

    public var text: String
    public var kind: Kind
    /// Whether the statement returns rows (a SELECT, or a write with RETURNING).
    public var returnsRows: Bool
    /// Why it deserves a second look before it runs: dropping or emptying tables, or
    /// updating and deleting with no WHERE.
    public var danger: String?

    public init(_ text: String) {
        self.text = text
        let words = SQLScript.words(text)
        let first = words.first ?? ""
        let kind: Kind
        switch first {
        case "select", "with", "explain", "show", "values", "table", "describe", "desc", "pragma": kind = .read
        case "insert", "update", "delete", "merge", "copy", "replace", "upsert", "call": kind = .write
        case "begin", "commit", "rollback", "start", "set", "savepoint", "release", "use", "reset", "end": kind = .control
        default: kind = .schema
        }
        // A WITH whose body writes, or an EXPLAIN ANALYZE of a write, is a write.
        var resolved = kind
        if first == "with" || first == "explain", words.contains(where: { ["insert", "update", "delete", "merge"].contains($0) }) {
            resolved = first == "explain" && !words.contains("analyze") ? .read : .write
        }
        // PRAGMA name = value changes settings.
        if first == "pragma", text.contains("=") { resolved = .control }
        self.kind = resolved
        self.returnsRows = resolved == .read || words.contains("returning")

        switch first {
        case "drop": danger = "drops \(words.dropFirst().first ?? "something")"
        case "truncate": danger = "empties the table"
        case "delete" where !words.contains("where"): danger = "deletes every row"
        case "update" where !words.contains("where"): danger = "updates every row"
        case "alter" where words.contains("drop"): danger = "drops part of a table"
        default: danger = nil
        }
    }

    public var changesData: Bool { kind == .write || kind == .schema }
}

/// Splits SQL scripts into statements without breaking strings, quoted names, comments
/// or Postgres dollar-quoted bodies.
public enum SQLScript {
    public static func statements(_ script: String) -> [SQLStatement] {
        split(script).map(SQLStatement.init)
    }

    public static func split(_ script: String) -> [String] {
        let chars = Array(script)
        var result: [String] = []
        var current = ""
        var i = 0
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !strippingComments(trimmed).isEmpty { result.append(trimmed) }
            current = ""
        }
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "-", next == "-" {
                while i < chars.count, chars[i] != "\n" { current.append(chars[i]); i += 1 }
                continue
            }
            if c == "/", next == "*" {
                current.append("/*"); i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") { current.append(chars[i]); i += 1 }
                if i < chars.count { current.append("*/"); i += 2 }
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                current.append(c); i += 1
                while i < chars.count {
                    current.append(chars[i])
                    if chars[i] == c {
                        // A doubled quote is an escaped one.
                        if i + 1 < chars.count, chars[i + 1] == c { current.append(c); i += 2; continue }
                        i += 1
                        break
                    }
                    if chars[i] == "\\", c == "'", i + 1 < chars.count { current.append(chars[i + 1]); i += 2; continue }
                    i += 1
                }
                continue
            }
            if c == "$", let tag = dollarTag(chars, at: i) {
                current += tag; i += tag.count
                let tagChars = Array(tag)
                while i < chars.count {
                    if chars[i] == "$", i + tagChars.count <= chars.count, Array(chars[i..<i + tagChars.count]) == tagChars {
                        current += tag; i += tagChars.count
                        break
                    }
                    current.append(chars[i]); i += 1
                }
                continue
            }
            if c == ";" { flush(); i += 1; continue }
            current.append(c); i += 1
        }
        flush()
        return result
    }

    /// `$$` or `$tag$` starting at `index`.
    private static func dollarTag(_ chars: [Character], at index: Int) -> String? {
        var j = index + 1
        while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
        guard j < chars.count, chars[j] == "$" else { return nil }
        // $1 is a parameter, not a tag.
        if j > index + 1, chars[index + 1].isNumber { return nil }
        return String(chars[index...j])
    }

    static func strippingComments(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            if let range = line.range(of: "--") { return String(line[..<range.lowerBound]) }
            return line
        }.joined(separator: "\n")
        while let start = lines.range(of: "/*") {
            if let end = lines.range(of: "*/", range: start.upperBound..<lines.endIndex) {
                lines.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                lines.removeSubrange(start.lowerBound..<lines.endIndex)
            }
        }
        return lines.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased keywords and names outside strings and comments.
    static func words(_ text: String) -> [String] {
        var clean = ""
        var quote: Character?
        for c in strippingComments(text) {
            if let open = quote {
                if c == open { quote = nil }
                continue
            }
            if c == "'" || c == "\"" || c == "`" { quote = c; clean.append(" "); continue }
            clean.append(c.isLetter || c.isNumber || c == "_" ? Character(c.lowercased()) : " ")
        }
        return clean.split(separator: " ").map(String.init)
    }

    /// Quotes a name for the engine: "name" for Postgres and SQLite, `name` for MySQL.
    public static func quote(_ name: String, for engine: DatabaseEngine) -> String {
        switch engine {
        case .mysql: "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
        case .postgres, .sqlite: "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    /// A string literal.
    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
