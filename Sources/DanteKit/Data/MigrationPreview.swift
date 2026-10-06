import Foundation

/// One thing a migration does to the schema, and what to watch out for.
public struct SchemaChange: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case createTable, dropTable, renameTable, emptyTable
        case addColumn, dropColumn, renameColumn, alterColumn
        case createIndex, dropIndex, addConstraint, dropConstraint
        case other
    }

    public var id: Int
    public var kind: Kind
    public var table: String?
    /// "add column note text", "create table orders (4 columns)".
    public var summary: String
    /// Why it could fail, lose data or lock the table for a while.
    public var warning: String?

    public var isDestructive: Bool { [.dropTable, .emptyTable, .dropColumn].contains(kind) }
}

/// Reads the DDL in a script or migration file and says what it would change, checked
/// against the schema the database has now. Pure: nothing runs.
public enum MigrationPreview {
    /// Above this many rows, a table rewrite or a locking index build is worth a warning.
    static let largeTable = 100_000

    public static func changes(_ script: String, schema: DatabaseSchema, engine: DatabaseEngine) -> [SchemaChange] {
        var state = State(schema: schema, engine: engine)
        for statement in SQLScript.statements(script) where statement.kind == .schema || SQLScript.words(statement.text).first == "truncate" {
            state.read(statement.text)
        }
        return state.changes
    }

    /// Migration files under a folder, oldest first by name: `*.sql`, including Prisma's `*/migration.sql`.
    public static func files(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let urls = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "sql" }
        let prefix = folder.standardizedFileURL.path.count + 1
        return urls.sorted { $0.standardizedFileURL.path.dropFirst(prefix) < $1.standardizedFileURL.path.dropFirst(prefix) }
    }

    /// Down migrations undo; they aren't what someone wants to preview by default.
    public static func isDownMigration(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".down.sql") || name.hasSuffix("_down.sql") || name == "down.sql"
    }

    private struct State {
        let schema: DatabaseSchema
        let engine: DatabaseEngine
        /// Lowercased table name → lowercased columns, as the script leaves them so far.
        var tables: [String: Set<String>]
        var changes: [SchemaChange] = []

        init(schema: DatabaseSchema, engine: DatabaseEngine) {
            self.schema = schema
            self.engine = engine
            tables = Dictionary(schema.tables.map { ($0.name.lowercased(), Set($0.columns.map { $0.name.lowercased() })) }, uniquingKeysWith: { a, _ in a })
        }

        /// Whether the schema is known at all; without one, nothing can be "missing".
        var knowsSchema: Bool { !schema.tables.isEmpty }

        func existing(_ name: String) -> DatabaseSchema.Table? {
            schema.tables.first { $0.name.lowercased() == name.lowercased() || $0.qualifiedName.lowercased() == name.lowercased() }
        }

        func rows(_ name: String) -> Int? { existing(name)?.rows }

        mutating func add(_ kind: SchemaChange.Kind, _ table: String?, _ summary: String, warning: String? = nil) {
            changes.append(SchemaChange(id: changes.count, kind: kind, table: table, summary: summary, warning: warning))
        }

        mutating func read(_ sql: String) {
            var reader = SQLTokenReader(sql)
            if reader.accept("create") {
                _ = reader.accept("or", "replace")
                while reader.accept("temporary") || reader.accept("temp") || reader.accept("unlogged") || reader.accept("global") || reader.accept("local") {}
                if reader.accept("table") { return createTable(&reader) }
                let unique = reader.accept("unique")
                _ = reader.accept("clustered") || reader.accept("nonclustered")
                if reader.accept("index") { return createIndex(&reader, unique: unique) }
                return other(sql)
            }
            if reader.accept("drop") {
                if reader.accept("table") { return dropTables(&reader) }
                if reader.accept("index") {
                    _ = reader.accept("concurrently")
                    _ = reader.accept("if", "exists")
                    let name = reader.name()?.last ?? "?"
                    return add(.dropIndex, nil, "drop index \(name)")
                }
                return other(sql)
            }
            if reader.accept("alter", "table") { return alterTable(&reader) }
            if reader.accept("rename", "table") {
                guard let from = reader.name()?.last, reader.accept("to"), let to = reader.name()?.last else { return other(sql) }
                return renameTable(from, to)
            }
            if reader.accept("truncate") {
                _ = reader.accept("table")
                repeat {
                    guard let name = reader.name()?.last else { break }
                    add(.emptyTable, name, "empty \(name)", warning: deletesRows(name))
                } while reader.acceptSymbol(",")
                return
            }
            other(sql)
        }

        mutating func other(_ sql: String) {
            let words = SQLToken.tokens(sql).prefix(4).map(\.text).joined(separator: " ")
            add(.other, nil, words)
        }

        func deletesRows(_ table: String) -> String {
            guard let rows = rows(table) else { return "Deletes the table’s rows." }
            return rows == 0 ? "The table is empty now." : "Deletes \(rows == 1 ? "1 row" : "about \(rows) rows")."
        }

        mutating func createTable(_ reader: inout SQLTokenReader) {
            let ifNotExists = reader.accept("if", "not", "exists")
            guard let name = reader.name()?.last else { return }
            var columns: [String] = []
            var references: [String] = []
            if reader.acceptSymbol("(") {
                while !reader.isAtEnd {
                    let element = reader.element()
                    if let first = element.first, !["constraint", "primary", "foreign", "unique", "check", "key", "index", "exclude", "fulltext"].contains(first.keyword), first.isName {
                        columns.append(first.text)
                    }
                    for (index, token) in element.enumerated() where token.keyword == "references" && index + 1 < element.count {
                        references.append(element[index + 1].text)
                    }
                    if !reader.acceptSymbol(",") { break }
                }
                _ = reader.acceptSymbol(")")
            } else if reader.accept("as") {
                add(.createTable, name, "create table \(name) from a query")
                tables[name.lowercased()] = []
                return
            }
            var warnings: [String] = []
            if tables[name.lowercased()] != nil, !ifNotExists { warnings.append("\(name) already exists, so this fails.") }
            let missing = references.filter { tables[$0.lowercased()] == nil && $0.lowercased() != name.lowercased() }
            if knowsSchema, !missing.isEmpty { warnings.append("References \(missing.joined(separator: ", ")), which doesn’t exist yet.") }
            add(.createTable, name, "create table \(name) (\(columns.count) column\(columns.count == 1 ? "" : "s"))", warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
            tables[name.lowercased()] = Set(columns.map { $0.lowercased() })
        }

        mutating func createIndex(_ reader: inout SQLTokenReader, unique: Bool) {
            let concurrently = reader.accept("concurrently")
            _ = reader.accept("if", "not", "exists")
            var indexName: String?
            if reader.current?.keyword != "on" { indexName = reader.name()?.last }
            guard reader.accept("on") else { return }
            _ = reader.accept("only")
            guard let table = reader.name()?.last else { return }
            if reader.accept("using") { _ = reader.name() }
            var columns: [String] = []
            if reader.acceptSymbol("(") {
                while !reader.isAtEnd {
                    let element = reader.element()
                    columns.append(element.map(\.text).joined(separator: element.count > 1 && element.first?.text != "(" ? " " : ""))
                    if !reader.acceptSymbol(",") { break }
                }
            }
            var warning: String?
            if knowsSchema, tables[table.lowercased()] == nil {
                warning = "There’s no table \(table)."
            } else if unique, let rows = rows(table), rows > 0 {
                warning = "Fails if \(table) already has duplicates."
            }
            if engine == .postgres, !concurrently, let rows = rows(table), rows > largeTable {
                let lock = "Blocks writes to \(table) (about \(rows) rows) while it builds; CREATE INDEX CONCURRENTLY doesn’t."
                warning = warning.map { "\($0) \(lock)" } ?? lock
            }
            let label = indexName.map { " \($0)" } ?? ""
            add(.createIndex, table, "create \(unique ? "unique " : "")index\(label) on \(table) (\(columns.joined(separator: ", ")))", warning: warning)
        }

        mutating func dropTables(_ reader: inout SQLTokenReader) {
            let ifExists = reader.accept("if", "exists")
            repeat {
                guard let name = reader.name()?.last else { break }
                var warnings: [String] = []
                if let table = existing(name) {
                    warnings.append(deletesRows(name))
                    let pointing = schema.referencing(table).map { "\($0.table.name).\($0.column.name)" }
                    if !pointing.isEmpty { warnings.append("\(pointing.joined(separator: ", ")) \(pointing.count == 1 ? "points" : "point") at it.") }
                } else if knowsSchema, tables[name.lowercased()] == nil, !ifExists {
                    warnings.append("There’s no table \(name), so this fails.")
                } else {
                    warnings.append("Deletes the table and its rows.")
                }
                add(.dropTable, name, "drop table \(name)", warning: warnings.joined(separator: " "))
                tables[name.lowercased()] = nil
            } while reader.acceptSymbol(",")
        }

        mutating func renameTable(_ from: String, _ to: String) {
            let warning = knowsSchema && tables[from.lowercased()] == nil ? "There’s no table \(from)." : "Code that uses \(from) needs to change too."
            add(.renameTable, from, "rename table \(from) to \(to)", warning: warning)
            tables[to.lowercased()] = tables.removeValue(forKey: from.lowercased()) ?? []
        }

        mutating func alterTable(_ reader: inout SQLTokenReader) {
            _ = reader.accept("if", "exists")
            _ = reader.accept("only")
            guard let table = reader.name()?.last else { return }
            if knowsSchema, tables[table.lowercased()] == nil {
                add(.other, table, "alter table \(table)", warning: "There’s no table \(table).")
                return
            }
            repeat {
                let action = reader.element()
                alter(table, action)
            } while reader.acceptSymbol(",")
        }

        mutating func alter(_ table: String, _ action: [SQLToken]) {
            var reader = SQLTokenReader(tokens: action, index: 0)
            let key = table.lowercased()
            let rows = rows(table)
            let hasRows = (rows ?? 1) > 0
            func columnExists(_ name: String) -> Bool { tables[key]?.contains(name.lowercased()) ?? !knowsSchema }

            if reader.accept("add") {
                if reader.accept("constraint") || ["primary", "foreign", "unique", "check", "index", "key", "exclude"].contains(reader.current?.keyword ?? "") {
                    let words = action.prefix(5).map(\.text).joined(separator: " ")
                    let unique = action.contains { $0.keyword == "unique" || $0.keyword == "primary" }
                    let foreign = action.contains { $0.keyword == "foreign" }
                    var warning: String?
                    if hasRows, unique { warning = "Fails if \(table) has duplicate values." }
                    if hasRows, foreign { warning = "Fails if any row of \(table) points at nothing." }
                    add(.addConstraint, table, "\(table): \(words.lowercased())", warning: warning)
                    return
                }
                _ = reader.accept("column")
                let ifNotExists = reader.accept("if", "not", "exists")
                guard let column = reader.current?.text else { return }
                reader.index += 1
                let type = typeWords(&reader)
                let words = Set(action.map(\.keyword))
                let notNull = action.indices.contains { action[$0].keyword == "not" && $0 + 1 < action.count && action[$0 + 1].keyword == "null" }
                var warning: String?
                if columnExists(column), knowsSchema, !ifNotExists {
                    warning = "\(table) already has \(column), so this fails."
                } else if notNull, !words.contains("default"), !words.contains("generated"), hasRows {
                    warning = rows == nil ? "NOT NULL with no default fails if \(table) has rows." : "NOT NULL with no default fails: \(table) has rows."
                } else if engine == .postgres, words.contains("default"), action.contains(where: { ["now", "random", "gen_random_uuid", "uuid_generate_v4", "clock_timestamp"].contains($0.keyword) }), let rows, rows > largeTable {
                    warning = "A volatile default rewrites all \(rows) rows of \(table)."
                }
                add(.addColumn, table, "\(table): add column \(column)\(type.isEmpty ? "" : " \(type)")", warning: warning)
                tables[key, default: []].insert(column.lowercased())
                return
            }
            if reader.accept("drop") {
                if reader.accept("constraint") {
                    _ = reader.accept("if", "exists")
                    add(.dropConstraint, table, "\(table): drop constraint \(reader.current?.text ?? "")")
                    return
                }
                if reader.accept("primary", "key") || reader.accept("foreign", "key") || reader.accept("index") || reader.accept("key") {
                    add(.dropConstraint, table, "\(table): " + action.prefix(4).map(\.text).joined(separator: " ").lowercased())
                    return
                }
                _ = reader.accept("column")
                let ifExists = reader.accept("if", "exists")
                guard let column = reader.current?.text else { return }
                let warning = !columnExists(column) && !ifExists ? "\(table) has no column \(column), so this fails."
                    : hasRows ? "Deletes \(column) from every row of \(table)." : nil
                add(.dropColumn, table, "\(table): drop column \(column)", warning: warning)
                tables[key]?.remove(column.lowercased())
                return
            }
            if reader.accept("rename") {
                if reader.accept("to") {
                    guard let to = reader.name()?.last else { return }
                    return renameTable(table, to)
                }
                _ = reader.accept("column")
                guard let from = reader.current?.text else { return }
                reader.index += 1
                guard reader.accept("to"), let to = reader.current?.text else { return }
                let warning = columnExists(from) ? "Code that uses \(from) needs to change too." : "\(table) has no column \(from), so this fails."
                add(.renameColumn, table, "\(table): rename column \(from) to \(to)", warning: warning)
                tables[key]?.remove(from.lowercased())
                tables[key, default: []].insert(to.lowercased())
                return
            }
            if reader.accept("alter") || reader.accept("modify") || reader.accept("change") {
                let isChange = action.first?.keyword == "change"
                _ = reader.accept("column")
                guard let column = reader.current?.text else { return }
                reader.index += 1
                // MySQL's CHANGE names the column twice: old, then new.
                if isChange, reader.current?.isName == true { reader.index += 1 }
                let words = action.map(\.keyword)
                var warning: String?
                var summary = "\(table): change \(column)"
                if !columnExists(column) {
                    warning = "\(table) has no column \(column), so this fails."
                } else if reader.accept("set", "not", "null") {
                    summary = "\(table): make \(column) required"
                    warning = hasRows ? "Fails if any row of \(table) has no \(column)." : nil
                } else if reader.accept("drop", "not", "null") {
                    summary = "\(table): make \(column) optional"
                } else if reader.accept("set", "default") || reader.accept("drop", "default") {
                    summary = "\(table): change the default of \(column)"
                } else {
                    _ = reader.accept("set", "data")
                    _ = reader.accept("type")
                    let type = typeWords(&reader)
                    summary = "\(table): change \(column) to \(type)"
                    if let rows, rows > largeTable, engine != .sqlite {
                        warning = "Can rewrite all \(rows) rows of \(table), locking it meanwhile."
                    } else if hasRows, words.contains("using") == false, engine == .postgres {
                        warning = "Fails if existing values don’t convert; add USING to say how."
                    }
                }
                add(.alterColumn, table, summary, warning: warning)
                return
            }
            add(.other, table, "\(table): " + action.prefix(5).map(\.text).joined(separator: " "))
        }

        /// A column type: words and a parenthesised size, up to the first constraint keyword.
        func typeWords(_ reader: inout SQLTokenReader) -> String {
            var words: [String] = []
            while let token = reader.current {
                if ["not", "null", "default", "primary", "references", "unique", "check", "constraint", "generated", "collate", "using", "auto_increment", "autoincrement", "first", "after", "comment"].contains(token.keyword) { break }
                if token.text == "(" {
                    reader.index += 1
                    let start = reader.index
                    reader.skipParenthesised()
                    let inner = reader.tokens[start..<max(start, reader.index - 1)].map(\.text).joined()
                    if words.isEmpty { words.append("(\(inner))") } else { words[words.count - 1] += "(\(inner))" }
                    continue
                }
                if token.text == "[" || token.text == "]", !words.isEmpty { words[words.count - 1] += token.text; reader.index += 1; continue }
                words.append(token.text.lowercased())
                reader.index += 1
            }
            return words.joined(separator: " ")
        }
    }
}
