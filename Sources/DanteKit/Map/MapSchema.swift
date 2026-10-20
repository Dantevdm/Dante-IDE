import Foundation

/// A table as the repo's SQL defines it: its CREATE TABLE, the ALTERs and indexes migrations
/// add later, and the tables whose foreign keys point at it. For the Map's table inspector and
/// its copy menu; never read from a live database.
extension SystemMap {
    public struct TableSchema: Equatable, Sendable {
        public struct Reference: Equatable, Sendable, Hashable {
            public var table: String
            public var column: String
        }

        public var name: String
        /// Where its CREATE TABLE is.
        public var file: String
        public var line: Int
        /// The CREATE TABLE statement as written, then each later ALTER and CREATE INDEX.
        public var statements: [String]
        public var columns: [Column]
        /// Tables with a foreign key to this one, and the column holding it.
        public var referencedBy: [Reference] = []
        /// Indexes, keys and unique constraints, each by its columns in order.
        public var indexes: [Index] = []

        public struct Index: Equatable, Sendable, Hashable {
            public var name: String?
            public var columns: [String]
            public var unique: Bool
        }

        /// An index whose leading columns are these (in any order), so a lookup by them is fast.
        public func isIndexed(_ columns: [String]) -> Bool {
            let wanted = Set(columns.map { $0.lowercased() })
            return indexes.contains { index in
                index.columns.count >= wanted.count && Set(index.columns.prefix(wanted.count).map { $0.lowercased() }) == wanted
            } || (wanted.count == 1 && self.columns.contains { $0.primaryKey && wanted.contains($0.name.lowercased()) } && self.columns.filter(\.primaryKey).count == 1)
        }

        /// The statements, ready to paste.
        public var ddl: String { statements.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n\n") }

        public var markdown: String {
            var lines = ["### \(name)", "", "| Column | Type | Key | References |", "| --- | --- | --- | --- |"]
            for column in columns {
                lines.append("| \(column.name) | \(column.type) | \(column.primaryKey ? "PK" : column.references != nil ? "FK" : "") | \(column.references ?? "") |")
            }
            return lines.joined(separator: "\n")
        }

        public var select: String {
            "SELECT " + (columns.isEmpty ? "*" : columns.map(\.name).joined(separator: ", ")) + "\nFROM \(name)\nLIMIT 100;"
        }
    }

    /// Every table the repo's SQL creates, in migration order (V2 before V10), with later
    /// ALTER TABLE ADD/DROP COLUMN and CREATE INDEX applied.
    public static func schema(files: [String], read: (String) -> String?) -> [TableSchema] {
        let sql = files.filter { ($0 as NSString).pathExtension.lowercased() == "sql" && !isTest($0) }
            .sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
        var tables: [TableSchema] = []
        var index: [String: Int] = [:]
        for file in sql {
            guard let text = read(file) else { continue }
            let lower = text.lowercased()
            guard has(lower, "create table") || has(lower, "alter table") || has(lower, "create index") || has(lower, "create unique index") else { continue }
            for statement in statements(in: text) {
                let flat = statement.text.replacing(/--[^\n]*/, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if let match = flat.firstMatch(of: /(?i)^create\s+(?:temporary\s+|temp\s+)?table\s+(?:if\s+not\s+exists\s+)?(?:[`"\[]?\w+[`"\]]?\.)?[`"\[]?(\w+)/) {
                    let name = String(match.1)
                    guard index[name.lowercased()] == nil else { continue }
                    var columns = columns(of: name, in: statement.text)
                    // PRIMARY KEY (a, b) after the columns.
                    if let keys = flat.firstMatch(of: /(?i)primary\s+key\s*\(([^)]*)\)/) {
                        let names = keys.1.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " `\"[]")).lowercased() }
                        for i in columns.indices where names.contains(columns[i].name.lowercased()) { columns[i].primaryKey = true }
                    }
                    index[name.lowercased()] = tables.count
                    var table = TableSchema(name: name, file: file, line: statement.line, statements: [statement.text], columns: columns)
                    let keys = columns.filter(\.primaryKey).map(\.name)
                    if !keys.isEmpty { table.indexes.append(.init(name: nil, columns: keys, unique: true)) }
                    // UNIQUE on a column, and UNIQUE (a, b) for the table.
                    for definition in topLevel(String(flat.drop { $0 != "(" }.dropFirst().reversed().drop { $0 != ")" }.dropFirst().reversed())) {
                        let lower = definition.lowercased()
                        if let group = definition.firstMatch(of: /(?i)^(?:constraint\s+\w+\s+)?unique\s*(?:key\s*)?\(([^)]*)\)/) {
                            table.indexes.append(.init(name: nil, columns: Self.names(String(group.1)), unique: true))
                        } else if lower.contains(" unique"), let column = definition.split(separator: " ").first {
                            table.indexes.append(.init(name: nil, columns: [column.trimmingCharacters(in: CharacterSet(charactersIn: "`\"[]"))], unique: true))
                        }
                    }
                    tables.append(table)
                } else if let match = flat.firstMatch(of: /(?i)^alter\s+table\s+(?:only\s+)?(?:if\s+exists\s+)?(?:[`"\[]?\w+[`"\]]?\.)?[`"\[]?(\w+)[`"\]]?\s+(.*)$/),
                          let at = index[String(match.1).lowercased()] {
                    tables[at].statements.append(statement.text)
                    // Each ADD/DROP in a comma-separated list.
                    for action in topLevel(String(match.2)) {
                        if let add = action.firstMatch(of: /(?i)^add\s+(?:column\s+)?(?:if\s+not\s+exists\s+)?[`"\[]?(\w+)[`"\]]?\s+(.*)$/),
                           !["constraint", "primary", "foreign", "unique", "check", "index", "key"].contains(String(add.1).lowercased()) {
                            let rest = String(add.2)
                            let type = rest.firstMatch(of: /^\w+(?:\s+(?:varying|precision))?(?:\s*\([^)]*\))?(?:\[\])?/).map { String($0.0).lowercased() } ?? ""
                            let reference = rest.firstMatch(of: /(?i)references\s+(?:[`"\[]?\w+[`"\]]?\.)?[`"\[]?(\w+)/).map { String($0.1) }
                            var column = Column(name: String(add.1), type: type, references: reference)
                            column.primaryKey = rest.lowercased().contains("primary key")
                            column.notNull = rest.lowercased().contains("not null") || column.primaryKey
                            tables[at].columns.removeAll { $0.name.lowercased() == column.name.lowercased() }
                            tables[at].columns.append(column)
                        } else if let drop = action.firstMatch(of: /(?i)^drop\s+(?:column\s+)?(?:if\s+exists\s+)?[`"\[]?(\w+)/),
                                  !["constraint", "index", "key"].contains(String(drop.1).lowercased()) {
                            tables[at].columns.removeAll { $0.name.lowercased() == String(drop.1).lowercased() }
                        } else if let foreign = action.firstMatch(of: /(?i)foreign\s+key\s*\(\s*[`"\[]?(\w+)[^)]*\)\s*references\s+(?:[`"\[]?\w+[`"\]]?\.)?[`"\[]?(\w+)/),
                                  let column = tables[at].columns.firstIndex(where: { $0.name.lowercased() == String(foreign.1).lowercased() }) {
                            tables[at].columns[column].references = String(foreign.2)
                        } else if let key = action.firstMatch(of: /(?i)^add\s+(?:constraint\s+\w+\s+)?(primary\s+key|unique)\s*\(([^)]*)\)/) {
                            let columns = Self.names(String(key.2))
                            tables[at].indexes.append(.init(name: nil, columns: columns, unique: true))
                            if key.1.lowercased().hasPrefix("primary") {
                                for i in tables[at].columns.indices where columns.contains(where: { $0.lowercased() == tables[at].columns[i].name.lowercased() }) {
                                    tables[at].columns[i].primaryKey = true
                                }
                            }
                        }
                    }
                } else if let match = flat.firstMatch(of: /(?i)^create\s+(unique\s+)?index\s+(?:concurrently\s+)?(?:if\s+not\s+exists\s+)?(\S*)\s*on\s+(?:only\s+)?(?:[`"\[]?\w+[`"\]]?\.)?[`"\[]?(\w+)[`"\]]?\s*(?:using\s+\w+\s*)?\(([^)]*)\)/),
                          let at = index[String(match.3).lowercased()] {
                    tables[at].statements.append(statement.text)
                    tables[at].indexes.append(.init(name: match.2.isEmpty ? nil : String(match.2), columns: Self.names(String(match.4)), unique: match.1 != nil))
                }
            }
        }
        // Who points at whom.
        for table in tables {
            for column in table.columns {
                guard let target = column.references, let at = index[target.lowercased()] else { continue }
                tables[at].referencedBy.append(TableSchema.Reference(table: table.name, column: column.name))
            }
        }
        return tables
    }

    /// One table's schema.
    public static func schema(of table: String, files: [String], read: (String) -> String?) -> TableSchema? {
        schema(files: files, read: read).first { $0.name.lowercased() == table.lowercased() }
    }

    /// The SQL's statements, split at semicolons outside strings, comments and dollar quotes,
    /// each with the line it starts on.
    static func statements(in sql: String) -> [(text: String, line: Int)] {
        var result: [(String, Int)] = []
        var current = ""
        var line = 1
        var start = 1
        var quote: Character?
        var dollar = false
        var comment = false
        var previous: Character = " "
        for character in sql {
            if character == "\n" { line += 1; if comment { comment = false } }
            if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !character.isWhitespace { start = line }
            if comment {
                current.append(character)
                previous = character
                continue
            }
            if quote == nil, !dollar, character == "-", previous == "-" { comment = true }
            if !dollar, character == "'" || character == "\"" { quote = quote == nil ? character : (quote == character ? nil : quote) }
            if quote == nil, character == "$", previous == "$" { dollar.toggle() }
            if character == ";", quote == nil, !dollar {
                let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result.append(Self.withoutLeadingComments(text, start)) }
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(Self.withoutLeadingComments(rest, start)) }
        return result
    }

    private static func withoutLeadingComments(_ text: String, _ start: Int) -> (text: String, line: Int) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var line = start
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("--") || first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
            line += 1
        }
        return (lines.joined(separator: "\n"), line)
    }

    /// Column names in a key or index list: `(a, "b" DESC, lower(c))` gives a, b, c.
    static func names(_ list: String) -> [String] {
        topLevel(list).compactMap { part in
            part.firstMatch(of: /(?:\w+\(\s*)?[`"\[]?(\w+)/).map { String($0.1) }
        }
    }

    /// Splits at commas outside parentheses: `ADD a numeric(10, 2), ADD b int`.
    static func topLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if character == ",", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }

    /// The tables as a Mermaid ER diagram, for docs and the agents.
    public static func mermaidER(_ tables: [TableSchema]) -> String {
        var lines = ["erDiagram"]
        for table in tables {
            lines.append("    \(table.name) {")
            for column in table.columns {
                let type = column.type.isEmpty ? "text" : column.type.replacing(/[(),\[\] ]/, with: "")
                let key = column.primaryKey ? " PK" : column.references != nil ? " FK" : ""
                lines.append("        \(type) \(column.name)\(key)")
            }
            lines.append("    }")
        }
        for table in tables {
            for column in table.columns {
                guard let target = column.references, tables.contains(where: { $0.name.lowercased() == target.lowercased() }) else { continue }
                lines.append("    \(target) ||--o{ \(table.name) : \"\(column.name)\"")
            }
        }
        return lines.joined(separator: "\n")
    }
}
