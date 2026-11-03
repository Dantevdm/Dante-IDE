import Foundation

/// Suggestions for the Data area's SQL editor, from the connection's schema (pure, tested):
/// tables after FROM, JOIN, INTO and UPDATE; a table's or alias's columns after a dot; the
/// columns of the statement's tables elsewhere; then keywords and common functions.
public enum SQLCompletion {
    public struct Suggestion: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case table, view, column, schema, keyword, function }
        public var label: String
        public var insert: String
        public var detail: String?
        public var kind: Kind
        /// Lower comes first before anything is typed.
        public var rank: Int

        public init(label: String, insert: String, detail: String? = nil, kind: Kind, rank: Int) {
            self.label = label
            self.insert = insert
            self.detail = detail
            self.kind = kind
            self.rank = rank
        }
    }

    /// What the caret is in: the word typed so far and what it's qualified by (`o.` → "o").
    struct Place: Equatable {
        var word: String
        var qualifier: String?
        var statement: String
        /// The statement's text before the word.
        var before: String
    }

    public static func suggestions(in text: String, at offset: Int, schema: DatabaseSchema?, engine: DatabaseEngine) -> [Suggestion] {
        let place = place(in: text as NSString, at: offset)
        let tables = schema?.tables ?? []
        let named = referencedTables(in: place.statement, tables: tables)
        let lowercase = place.word.first.map { $0.isLowercase } ?? false

        if let qualifier = place.qualifier {
            let key = qualifier.lowercased()
            if let table = named[key] ?? tables.first(where: { $0.name.lowercased() == key || $0.qualifiedName.lowercased() == key }) {
                return table.columns.enumerated().map { index, column in
                    Suggestion(label: column.name, insert: name(column.name, engine), detail: columnDetail(column), kind: .column, rank: index)
                }
            }
            // A schema: its tables.
            return tables.filter { $0.schema?.lowercased() == key }.enumerated().map { index, table in
                Suggestion(label: table.name, insert: name(table.name, engine), detail: tableDetail(table), kind: table.isView ? .view : .table, rank: index)
            }
        }

        let words = SQLToken.tokens(place.before)
        let last = words.last
        let lastKeyword = words.last { $0.kind == .word && clauseWords.contains($0.keyword) }?.keyword
        var result: [Suggestion] = []

        if let lastKeyword, tableClauses.contains(lastKeyword) {
            // Right after a table's name comes an alias or the next clause, not another table.
            let afterName = last.map { $0.isName && !clauseWords.contains($0.keyword) && $0.keyword != "as" } ?? false
            if !afterName || last?.text == "," {
                result += tables.enumerated().map { index, table in
                    Suggestion(label: table.qualifiedName, insert: qualified(table, engine), detail: tableDetail(table), kind: table.isView ? .view : .table, rank: index)
                }
                result += (schema?.schemas ?? []).filter { $0 != "public" }.map {
                    Suggestion(label: $0, insert: name($0, engine), detail: "schema", kind: .schema, rank: 500)
                }
                return result
            }
            return keywords(after: lastKeyword, lowercase: lowercase, rank: 0)
        }

        // Columns of the tables this statement names; every table's when it names none yet.
        let inScope = Array(Set(named.values.map(\.qualifiedName))).sorted().compactMap { name in tables.first { $0.qualifiedName == name } }
        let sources = inScope.isEmpty ? tables : inScope
        var seen = Set<String>()
        for table in sources {
            for column in table.columns where seen.insert(column.name.lowercased() + (inScope.isEmpty ? "" : table.qualifiedName)).inserted {
                result.append(Suggestion(label: column.name, insert: name(column.name, engine), detail: "\(table.name) · \(column.type)",
                                         kind: .column, rank: inScope.isEmpty ? 300 : 0))
            }
        }
        result += keywords(after: lastKeyword, lowercase: lowercase, rank: 100)
        result += functions(for: engine).map {
            Suggestion(label: $0 + "()", insert: (lowercase ? $0.lowercased() : $0) + "(", detail: "function", kind: .function, rank: 200)
        }
        result += tables.map {
            Suggestion(label: $0.qualifiedName, insert: qualified($0, engine), detail: tableDetail($0), kind: $0.isView ? .view : .table, rank: 400)
        }
        return result
    }

    /// After a space, the list opens only where a table's name comes next (`FROM `, `JOIN `).
    public static func opensAfterSpace(in text: String, at offset: Int) -> Bool {
        let head = (text as NSString).substring(to: min(max(0, offset), (text as NSString).length))
        return SQLToken.tokens(head).last.map { tableClauses.contains($0.keyword) } ?? false
    }

    // MARK: Reading the statement

    static func place(in text: NSString, at offset: Int) -> Place {
        let offset = min(max(0, offset), text.length)
        var start = offset
        while start > 0, isNameChar(text.character(at: start - 1)) { start -= 1 }
        let word = text.substring(with: NSRange(location: start, length: offset - start))
        var qualifier: String?
        if start > 0, text.character(at: start - 1) == 0x2E {
            var end = start - 1
            var begin = end
            if end > 0, text.character(at: end - 1) == 0x22 || text.character(at: end - 1) == 0x60 {
                // "Quoted".
                let quote = text.character(at: end - 1)
                end -= 1
                begin = end
                while begin > 0, text.character(at: begin - 1) != quote { begin -= 1 }
                qualifier = text.substring(with: NSRange(location: begin, length: end - begin))
            } else {
                while begin > 0, isNameChar(text.character(at: begin - 1)) { begin -= 1 }
                if begin < end { qualifier = text.substring(with: NSRange(location: begin, length: end - begin)) }
            }
        }
        // The statement the caret is in, from the semicolon before it to the one after.
        let head = text.substring(to: offset)
        let tail = text.substring(from: offset)
        let from = head.range(of: ";", options: .backwards).map { head[$0.upperBound...] } ?? Substring(head)
        let to = tail.range(of: ";").map { tail[..<$0.lowerBound] } ?? Substring(tail)
        let statement = String(from) + String(to)
        let before = String(from.dropLast(word.count))
        return Place(word: word, qualifier: qualifier, statement: statement, before: qualifier == nil ? before : "")
    }

    /// Tables named after FROM, JOIN, UPDATE and INTO, keyed by alias and by name (lowercased).
    static func referencedTables(in statement: String, tables: [DatabaseSchema.Table]) -> [String: DatabaseSchema.Table] {
        let tokens = SQLToken.tokens(statement)
        var found: [String: DatabaseSchema.Table] = [:]
        var i = 0
        func lookup(_ name: String) -> DatabaseSchema.Table? {
            let key = name.lowercased()
            return tables.first { $0.qualifiedName.lowercased() == key }
                ?? tables.first { $0.name.lowercased() == key }
        }
        while i < tokens.count {
            guard tableClauses.contains(tokens[i].keyword) else { i += 1; continue }
            i += 1
            // FROM a x, b AS y JOIN …
            while i < tokens.count, tokens[i].isName, !clauseWords.contains(tokens[i].keyword) {
                var name = tokens[i].text
                i += 1
                if i + 1 < tokens.count, tokens[i].text == ".", tokens[i + 1].isName {
                    name += "." + tokens[i + 1].text
                    i += 2
                }
                guard let table = lookup(name) else { break }
                found[table.name.lowercased()] = table
                found[table.qualifiedName.lowercased()] = table
                if i < tokens.count, tokens[i].keyword == "as" { i += 1 }
                if i < tokens.count, tokens[i].isName, !clauseWords.contains(tokens[i].keyword), !aliasStoppers.contains(tokens[i].keyword) {
                    found[tokens[i].text.lowercased()] = table
                    i += 1
                }
                guard i < tokens.count, tokens[i].text == "," else { break }
                i += 1
            }
        }
        return found
    }

    // MARK: Words

    private static let tableClauses: Set<String> = ["from", "join", "into", "update", "table", "truncate"]
    private static let clauseWords: Set<String> = [
        "select", "from", "join", "where", "on", "and", "or", "group", "order", "by", "having", "limit", "offset",
        "set", "into", "update", "values", "table", "truncate", "insert", "delete", "returning", "union", "inner",
        "left", "right", "full", "outer", "cross", "with", "as", "not", "in", "is", "like", "between", "case", "when",
        "then", "else", "end", "distinct", "using", "natural",
    ]
    private static let aliasStoppers: Set<String> = ["natural", "lateral", "only"]

    private static func keywords(after keyword: String?, lowercase: Bool, rank: Int) -> [Suggestion] {
        let likely: [String] = switch keyword {
        case nil: ["SELECT", "WITH", "INSERT INTO", "UPDATE", "DELETE FROM", "EXPLAIN", "CREATE TABLE", "ALTER TABLE"]
        case "from", "join", "into", "update", "table": ["WHERE", "JOIN", "LEFT JOIN", "INNER JOIN", "ON", "AS", "GROUP BY", "ORDER BY", "LIMIT", "SET", "VALUES"]
        case "where", "and", "or", "on", "having": ["AND", "OR", "NOT", "IN", "IS NULL", "IS NOT NULL", "LIKE", "ILIKE", "BETWEEN", "EXISTS", "ORDER BY", "GROUP BY", "LIMIT"]
        case "select", "distinct": ["DISTINCT", "FROM", "AS", "CASE", "WHEN", "COUNT(*)"]
        case "by": ["ASC", "DESC", "LIMIT", "NULLS LAST", "HAVING"]
        default: ["FROM", "WHERE", "AND", "OR", "ORDER BY", "GROUP BY", "LIMIT", "JOIN", "AS"]
        }
        let rest = ["SELECT", "FROM", "WHERE", "JOIN", "LEFT JOIN", "INNER JOIN", "ON", "AND", "OR", "NOT", "NULL", "IN", "AS",
                    "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "DISTINCT", "INSERT INTO", "VALUES", "UPDATE", "SET",
                    "DELETE FROM", "RETURNING", "UNION", "CASE", "WHEN", "THEN", "ELSE", "END", "EXISTS", "BETWEEN", "LIKE",
                    "ASC", "DESC", "WITH", "EXPLAIN", "CREATE TABLE", "ALTER TABLE", "TRUE", "FALSE"]
        var seen = Set<String>()
        return (likely + rest).enumerated().compactMap { index, word in
            guard seen.insert(word).inserted else { return nil }
            let text = lowercase ? word.lowercased() : word
            return Suggestion(label: text, insert: text, detail: "keyword", kind: .keyword, rank: rank + (index < likely.count ? 0 : 50) + index)
        }
    }

    private static func functions(for engine: DatabaseEngine) -> [String] {
        let common = ["COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "LOWER", "UPPER", "LENGTH", "ROUND", "CAST", "NULLIF"]
        return switch engine {
        case .postgres: common + ["NOW", "DATE_TRUNC", "TO_CHAR", "STRING_AGG", "ARRAY_AGG", "JSONB_EXTRACT_PATH_TEXT", "GEN_RANDOM_UUID", "EXTRACT"]
        case .mysql: common + ["NOW", "DATE_FORMAT", "GROUP_CONCAT", "IFNULL", "CONCAT", "JSON_EXTRACT"]
        case .sqlite: common + ["DATETIME", "STRFTIME", "GROUP_CONCAT", "IFNULL", "JSON_EXTRACT"]
        }
    }

    private static func isNameChar(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c > 0x7F
    }

    /// A name as typed into SQL: quoted only when it has to be.
    static func name(_ name: String, _ engine: DatabaseEngine) -> String {
        let plain = name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
            && !(name.first?.isNumber ?? true)
        // Postgres folds unquoted names to lowercase, so mixed case needs quotes there.
        let folds = engine == .postgres && name != name.lowercased()
        return plain && !folds ? name : SQLScript.quote(name, for: engine)
    }

    private static func qualified(_ table: DatabaseSchema.Table, _ engine: DatabaseEngine) -> String {
        let base = name(table.name, engine)
        guard let schema = table.schema, !(engine == .postgres && schema == "public") else { return base }
        return name(schema, engine) + "." + base
    }

    private static func tableDetail(_ table: DatabaseSchema.Table) -> String {
        let kind = table.isView ? "view" : "table"
        return "\(kind) · \(table.columns.count) column\(table.columns.count == 1 ? "" : "s")"
    }

    private static func columnDetail(_ column: DatabaseSchema.Column) -> String {
        var parts = [column.type]
        if column.isPrimaryKey { parts.append("PK") }
        if let ref = column.references { parts.append("→ \(ref.table)") }
        return parts.joined(separator: " · ")
    }
}
