import Foundation

/// A table the planner reads end to end while filtering on some of its columns, and the
/// index that would let it look rows up instead.
public struct PlanFinding: Equatable, Sendable, Identifiable {
    /// The table's name as the schema has it, or as the plan names it.
    public var table: String
    /// Filtered columns, equality comparisons first.
    public var columns: [String]
    /// The table's row count or estimate, when known.
    public var rows: Int?
    /// `create index …`, or nil when there's nothing to index.
    public var suggestion: String?

    public var id: String { table + ":" + columns.joined(separator: ",") }

    /// Small tables are cheap to scan; the index matters as they grow.
    public var isSmall: Bool { (rows ?? .max) < 1_000 }
}

/// Reads EXPLAIN output: Postgres text plans, MySQL's tree format and SQLite's query plan.
public enum QueryPlan {
    /// The plan as text: the plan column of each row, or SQLite's `detail` column.
    public static func text(from results: [QueryResult]) -> String {
        results.filter(\.hasRows).map { result in
            let column = result.columns.firstIndex { $0.lowercased() == "detail" } ?? 0
            return result.rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Full scans of tables the query filters, with an index for each.
    public static func findings(plan: String, query: String, engine: DatabaseEngine, schema: DatabaseSchema) -> [PlanFinding] {
        let aliases = tableAliases(in: query)
        let queryFilters = filteredColumns(in: whereClause(of: query))
        var findings: [PlanFinding] = []
        for scan in scans(in: plan, engine: engine) {
            let name = aliases[scan.name.lowercased()] ?? scan.name
            let table = schema.tables.first { $0.qualifiedName == name || $0.name == name || $0.name.lowercased() == name.lowercased() }
            let filters = scan.filter.map(filteredColumns(in:)) ?? queryFilters
            var columns: [(name: String, equality: Bool)] = []
            for column in filters {
                if let qualifier = column.qualifier, (aliases[qualifier.lowercased()] ?? qualifier).lowercased() != (table?.name ?? name).lowercased(),
                   qualifier.lowercased() != scan.alias?.lowercased() { continue }
                let real = table?.columns.first { $0.name.lowercased() == column.name.lowercased() }?.name
                guard let resolved = real ?? (table == nil ? column.name : nil), !columns.contains(where: { $0.name == resolved }) else { continue }
                columns.append((resolved, column.equality))
            }
            // Equality first, then ranges; three columns is plenty.
            let ordered = (columns.filter(\.equality) + columns.filter { !$0.equality }).prefix(3).map(\.name)
            guard !ordered.isEmpty, ordered != table?.primaryKey, !findings.contains(where: { $0.table == (table?.qualifiedName ?? name) && $0.columns == ordered }) else { continue }
            let tableSQL = table?.sqlName(for: engine) ?? name
            let indexName = ([table?.name ?? name] + ordered + ["idx"]).joined(separator: "_").lowercased()
                .replacingOccurrences(of: "[^a-z0-9_]", with: "_", options: .regularExpression)
            let suggestion = "create index \(indexName) on \(tableSQL) (\(ordered.map { quoteIfNeeded($0, engine: engine) }.joined(separator: ", ")))"
            findings.append(PlanFinding(table: table?.qualifiedName ?? name, columns: ordered, rows: table?.rows, suggestion: suggestion))
        }
        return findings
    }

    struct Scan: Equatable {
        var name: String
        var alias: String?
        /// The filter the plan shows for this scan, when it shows one.
        var filter: String?
    }

    /// Sequential and table scans, with the Filter line that goes with each.
    static func scans(in plan: String, engine: DatabaseEngine) -> [Scan] {
        let lines = plan.components(separatedBy: "\n")
        var scans: [Scan] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "->", with: "").trimmingCharacters(in: .whitespaces)
            switch engine {
            case .postgres:
                guard let range = trimmed.range(of: "Seq Scan on ") else { continue }
                let words = trimmed[range.upperBound...].split(separator: " ").map(String.init)
                guard let name = words.first else { continue }
                let alias = words.count > 1 && !words[1].hasPrefix("(") ? words[1] : nil
                // The Filter line is indented under the scan, before the next node.
                let indent = line.prefix { $0 == " " }.count
                var filter: String?
                for next in lines[(index + 1)...] {
                    let nextIndent = next.prefix { $0 == " " }.count
                    let text = next.trimmingCharacters(in: .whitespaces)
                    if text.hasPrefix("->") || nextIndent <= indent { break }
                    if text.hasPrefix("Filter:") { filter = String(text.dropFirst(7)); break }
                }
                scans.append(Scan(name: unqualified(name), alias: alias, filter: filter))
            case .mysql:
                guard let range = trimmed.range(of: "Table scan on ") else { continue }
                guard let name = trimmed[range.upperBound...].split(separator: " ").first.map(String.init) else { continue }
                // The filter is the parent node, on the line above.
                var filter: String?
                if index > 0 {
                    let above = lines[index - 1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "->", with: "").trimmingCharacters(in: .whitespaces)
                    if above.hasPrefix("Filter:") { filter = String(above.dropFirst(7)) }
                }
                scans.append(Scan(name: unqualified(name), alias: nil, filter: filter))
            case .sqlite:
                // "SCAN orders", "SCAN TABLE orders AS o"; "SCAN … USING INDEX" already uses one.
                guard trimmed.hasPrefix("SCAN "), !trimmed.contains("USING") else { continue }
                var words = trimmed.split(separator: " ").map(String.init).dropFirst()
                if words.first == "TABLE" { words = words.dropFirst() }
                guard let name = words.first else { continue }
                let rest = Array(words.dropFirst())
                let alias = rest.count >= 2 && rest[0] == "AS" ? rest[1] : nil
                scans.append(Scan(name: name, alias: alias, filter: nil))
            }
        }
        return scans
    }

    struct FilteredColumn: Equatable {
        var qualifier: String?
        var name: String
        var equality: Bool
    }

    private static let comparisons: Set<String> = ["=", "<", ">", "<=", ">=", "<>", "!=", "~~", "like", "ilike", "in", "between", "is", "not"]
    private static let equalities: Set<String> = ["=", "in", "is"]

    /// Names compared with something: `a = 1`, `o.total > 10`, `name like 'x%'`, `(id)::text = …`.
    static func filteredColumns(in text: String) -> [FilteredColumn] {
        let tokens = SQLToken.tokens(text)
        var result: [FilteredColumn] = []
        var i = 0
        while i < tokens.count {
            guard tokens[i].isName, !["and", "or", "not", "null", "true", "false"].contains(tokens[i].keyword) else { i += 1; continue }
            // A cast's type, or a function's argument: lower(email) can't use a plain index.
            if i > 0, tokens[i - 1].text == "::" { i += 1; continue }
            if i > 1, tokens[i - 1].text == "(", tokens[i - 2].kind == .word,
               !["and", "or", "not", "where", "on", "when", "then", "else", "in"].contains(tokens[i - 2].keyword) { i += 1; continue }
            var parts = [tokens[i].text]
            var j = i + 1
            while j + 1 < tokens.count, tokens[j].text == ".", tokens[j].kind == .symbol, tokens[j + 1].isName {
                parts.append(tokens[j + 1].text)
                j += 2
            }
            // Skip a closing parenthesis and a cast: (customer_id)::text.
            var k = j
            while k < tokens.count, tokens[k].text == ")" { k += 1 }
            if k + 1 < tokens.count, tokens[k].text == "::" { k += 2 }
            // A function call isn't a column.
            let isCall = j < tokens.count && tokens[j].text == "("
            if !isCall, k < tokens.count {
                let op = tokens[k].kind == .symbol ? tokens[k].text : tokens[k].keyword
                if comparisons.contains(op) {
                    result.append(FilteredColumn(qualifier: parts.count > 1 ? parts[parts.count - 2] : nil, name: parts.last!, equality: equalities.contains(op)))
                }
            }
            i = j
        }
        return result
    }

    /// The WHERE clauses of a query, joined.
    static func whereClause(of query: String) -> String {
        let tokens = SQLToken.tokens(query)
        var parts: [String] = []
        var inside = false
        for token in tokens {
            if token.keyword == "where" { inside = true; continue }
            if ["group", "order", "limit", "having", "union", "returning", "window", "offset", "from", "join", "select"].contains(token.keyword) { inside = false }
            if inside { parts.append(token.kind == .string ? "'\(token.text)'" : token.kind == .quotedName ? "\"\(token.text)\"" : token.text) }
        }
        return parts.joined(separator: " ")
    }

    /// Lowercased alias (and table name) → table name, from FROM and JOIN.
    static func tableAliases(in query: String) -> [String: String] {
        let tokens = SQLToken.tokens(query)
        var aliases: [String: String] = [:]
        var i = 0
        while i < tokens.count {
            guard ["from", "join", "update", "into"].contains(tokens[i].keyword) else { i += 1; continue }
            var reader = SQLTokenReader(tokens: tokens, index: i + 1)
            guard let parts = reader.name() else { i += 1; continue }
            let table = parts.last!
            aliases[table.lowercased()] = table
            _ = reader.accept("as")
            if let alias = reader.current, alias.isName, !reservedAfterTable.contains(alias.keyword) {
                aliases[alias.text.lowercased()] = table
            }
            i = reader.index
        }
        return aliases
    }

    private static let reservedAfterTable: Set<String> = ["where", "join", "on", "inner", "left", "right", "full", "cross", "group", "order", "limit",
                                                          "set", "values", "using", "natural", "union", "having", "select", "returning", "window", "offset"]

    private static func unqualified(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }

    private static func quoteIfNeeded(_ name: String, engine: DatabaseEngine) -> String {
        name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil ? name : SQLScript.quote(name, for: engine)
    }

    /// What to ask Claude about a plan.
    public static func explainPrompt(query: String, plan: String, engine: DatabaseEngine) -> String {
        """
        Explain this \(engine.name) query plan in plain language: what the database does step by step, \
        where the time goes, and what would make it faster (indexes, rewrites). Be concrete and short.

        ```sql
        \(query)
        ```

        Plan:

        ```
        \(plan)
        ```
        """
    }
}

extension SQLTokenReader {
    init(tokens: [SQLToken], index: Int) {
        self.tokens = tokens
        self.index = index
    }
}
