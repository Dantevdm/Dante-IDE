import Foundation

/// The tables in a database, their columns and keys, for the Data area's sidebar,
/// structure view and diagram.
public struct DatabaseSchema: Equatable, Sendable {
    public struct Column: Equatable, Sendable, Identifiable {
        public var name: String
        public var type: String
        public var nullable: Bool
        public var isPrimaryKey: Bool
        public var defaultValue: String?
        /// The table and column a foreign key points at.
        public var references: (table: String, column: String)?
        public var id: String { name }

        public init(name: String, type: String, nullable: Bool = true, isPrimaryKey: Bool = false, defaultValue: String? = nil, references: (table: String, column: String)? = nil) {
            self.name = name
            self.type = type
            self.nullable = nullable
            self.isPrimaryKey = isPrimaryKey
            self.defaultValue = defaultValue
            self.references = references
        }

        public static func == (a: Column, b: Column) -> Bool {
            a.name == b.name && a.type == b.type && a.nullable == b.nullable && a.isPrimaryKey == b.isPrimaryKey
                && a.defaultValue == b.defaultValue && a.references?.table == b.references?.table && a.references?.column == b.references?.column
        }
    }

    public struct Table: Equatable, Sendable, Identifiable {
        /// Postgres schema, or nil where there's only one namespace.
        public var schema: String?
        public var name: String
        public var columns: [Column]
        /// Exact for SQLite, the planner's estimate for Postgres and MySQL; nil when unknown.
        public var rows: Int?
        public var bytes: Int?
        public var isView: Bool

        public init(schema: String? = nil, name: String, columns: [Column] = [], rows: Int? = nil, bytes: Int? = nil, isView: Bool = false) {
            self.schema = schema
            self.name = name
            self.columns = columns
            self.rows = rows
            self.bytes = bytes
            self.isView = isView
        }

        public var id: String { qualifiedName }
        /// schema.name, leaving out Postgres's default `public`.
        public var qualifiedName: String { schema.map { $0 == "public" ? name : "\($0).\(name)" } ?? name }
        public var primaryKey: [String] { columns.filter(\.isPrimaryKey).map(\.name) }
        public var foreignKeys: [Column] { columns.filter { $0.references != nil } }

        /// The name quoted for SQL.
        public func sqlName(for engine: DatabaseEngine) -> String {
            let quoted = SQLScript.quote(name, for: engine)
            guard let schema, schema != "public" || engine != .postgres else { return quoted }
            return SQLScript.quote(schema, for: engine) + "." + quoted
        }
    }

    public var tables: [Table]
    public var version: String?
    public var bytes: Int?

    public init(tables: [Table] = [], version: String? = nil, bytes: Int? = nil) {
        self.tables = tables
        self.version = version
        self.bytes = bytes
    }

    public var schemas: [String] { Array(Set(tables.compactMap(\.schema))).sorted { a, b in a == "public" || (b != "public" && a < b) } }

    public func table(_ qualifiedName: String) -> Table? { tables.first { $0.qualifiedName == qualifiedName } }

    /// Tables that point at this one.
    public func referencing(_ table: Table) -> [(table: Table, column: Column)] {
        tables.flatMap { other in
            other.foreignKeys.filter { $0.references?.table == table.qualifiedName }.map { (other, $0) }
        }
    }

    /// An ER diagram of the tables (not views), for `MermaidView`'s ER renderer.
    public func erDiagram(limit: Int = 40) -> ERDiagram {
        let chosen = tables.filter { !$0.isView }.prefix(limit)
        let names = Set(chosen.map(\.qualifiedName))
        var relationships: [ERDiagram.Relationship] = []
        for table in chosen {
            for column in table.foreignKeys {
                guard let target = column.references?.table, names.contains(target) else { continue }
                relationships.append(ERDiagram.Relationship(
                    from: target, to: table.qualifiedName, fromCardinality: column.nullable ? "0..1" : "1",
                    toCardinality: "0..N", label: column.name
                ))
            }
        }
        return ERDiagram(
            entities: chosen.map { table in
                ERDiagram.Entity(name: table.qualifiedName, attributes: table.columns.map { column in
                    var keys: [String] = []
                    if column.isPrimaryKey { keys.append("PK") }
                    if column.references != nil { keys.append("FK") }
                    return ERDiagram.Attribute(type: Self.shortType(column.type), name: column.name, keys: keys)
                })
            },
            relationships: relationships
        )
    }

    /// `character varying(255)` → `varchar(255)`, and so on, so diagrams stay narrow.
    public static func shortType(_ type: String) -> String {
        var short = type.lowercased()
        for (long, brief) in [("character varying", "varchar"), ("timestamp without time zone", "timestamp"), ("timestamp with time zone", "timestamptz"),
                              ("time without time zone", "time"), ("double precision", "float8"), ("character", "char"), ("boolean", "bool"), ("integer", "int")] {
            short = short.replacingOccurrences(of: long, with: brief)
        }
        return short
    }

    /// The schema as compact text, for Claude: one line per table.
    public var summary: String {
        tables.map { table in
            let columns = table.columns.map { column in
                var text = "\(column.name) \(Self.shortType(column.type))"
                if column.isPrimaryKey { text += " pk" }
                if let target = column.references { text += " → \(target.table).\(target.column)" }
                if !column.nullable, !column.isPrimaryKey { text += " not null" }
                return text
            }
            return "\(table.isView ? "view " : "")\(table.qualifiedName)(\(columns.joined(separator: ", ")))"
        }.joined(separator: "\n")
    }
}

/// The queries that read a schema, and how their rows become a `DatabaseSchema`.
public enum SchemaQueries {
    public static func script(for engine: DatabaseEngine) -> String {
        switch engine {
        case .postgres: """
            select version();
            select c.table_schema, c.table_name, c.column_name, c.data_type
                   || case when c.character_maximum_length is not null then '(' || c.character_maximum_length || ')' else '' end,
                   c.is_nullable, c.column_default, t.table_type
              from information_schema.columns c
              join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
             where c.table_schema not in ('pg_catalog', 'information_schema') and c.table_schema not like 'pg_toast%'
             order by c.table_schema, c.table_name, c.ordinal_position;
            select tc.table_schema, tc.table_name, kcu.column_name, tc.constraint_type, ccu.table_schema, ccu.table_name, ccu.column_name
              from information_schema.table_constraints tc
              join information_schema.key_column_usage kcu on kcu.constraint_name = tc.constraint_name and kcu.table_schema = tc.table_schema
              left join information_schema.constraint_column_usage ccu
                on tc.constraint_type = 'FOREIGN KEY' and ccu.constraint_name = tc.constraint_name and ccu.constraint_schema = tc.table_schema
             where tc.constraint_type in ('PRIMARY KEY', 'FOREIGN KEY') and tc.table_schema not in ('pg_catalog', 'information_schema');
            select n.nspname, c.relname, greatest(c.reltuples, 0)::bigint, pg_total_relation_size(c.oid)
              from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where c.relkind in ('r', 'p', 'm') and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_toast%';
            select pg_database_size(current_database())
            """
        case .mysql: """
            select version();
            select c.table_schema, c.table_name, c.column_name, c.column_type, c.is_nullable, c.column_default, t.table_type
              from information_schema.columns c
              join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
             where c.table_schema = database()
             order by c.table_name, c.ordinal_position;
            select k.table_schema, k.table_name, k.column_name, if(k.constraint_name = 'PRIMARY', 'PRIMARY KEY', 'FOREIGN KEY'),
                   k.referenced_table_schema, k.referenced_table_name, k.referenced_column_name
              from information_schema.key_column_usage k
             where k.table_schema = database() and (k.constraint_name = 'PRIMARY' or k.referenced_table_name is not null);
            select table_schema, table_name, table_rows, data_length + index_length
              from information_schema.tables where table_schema = database();
            select sum(data_length + index_length) from information_schema.tables where table_schema = database()
            """
        case .sqlite: """
            select 'SQLite ' || sqlite_version();
            select null, m.name, p.name, p.type, case when p."notnull" then 'NO' else 'YES' end, p.dflt_value, case m.type when 'view' then 'VIEW' else 'BASE TABLE' end
              from sqlite_master m join pragma_table_info(m.name) p
             where m.type in ('table', 'view') and m.name not like 'sqlite_%'
             order by m.name, p.cid;
            select null, m.name, p.name, 'PRIMARY KEY', null, null, null
              from sqlite_master m join pragma_table_info(m.name) p
             where m.type = 'table' and p.pk > 0 and m.name not like 'sqlite_%'
            union all
            select null, m.name, f."from", 'FOREIGN KEY', null, f."table", f."to"
              from sqlite_master m join pragma_foreign_key_list(m.name) f
             where m.type = 'table';
            select null, name, null, null from sqlite_master where 0;
            select page_count * page_size from pragma_page_count(), pragma_page_size()
            """
        }
    }

    /// Exact row counts, for SQLite, where there are no estimates. Capped at 60 tables.
    public static func sqliteCounts(_ tables: [DatabaseSchema.Table]) -> String? {
        let real = tables.filter { !$0.isView }.prefix(60)
        guard !real.isEmpty else { return nil }
        return real.map { "select \(SQLScript.literal($0.name)), count(*) from \(SQLScript.quote($0.name, for: .sqlite))" }.joined(separator: " union all ")
    }

    /// Builds the schema from the five results of `script(for:)`.
    public static func schema(from results: [QueryResult], engine: DatabaseEngine) -> DatabaseSchema {
        guard results.count >= 4 else { return DatabaseSchema() }
        var schema = DatabaseSchema()
        schema.version = results[0].rows.first?.first.flatMap { $0 }.map(shortVersion)
        let single = engine != .postgres
        var order: [String] = []
        var tables: [String: DatabaseSchema.Table] = [:]
        func key(_ schemaName: String?, _ name: String) -> String { single ? name : "\(schemaName ?? "public").\(name)" }
        for row in results[1].rows where row.count >= 7 {
            guard let name = row[1], let column = row[2] else { continue }
            let id = key(row[0], name)
            if tables[id] == nil {
                order.append(id)
                tables[id] = DatabaseSchema.Table(schema: single ? nil : row[0], name: name, isView: row[6]?.uppercased().contains("VIEW") == true)
            }
            tables[id]?.columns.append(DatabaseSchema.Column(name: column, type: row[3] ?? "", nullable: row[4] != "NO", defaultValue: row[5]))
        }
        for row in results[2].rows where row.count >= 7 {
            guard let name = row[1], let column = row[2], let index = tables[key(row[0], name)]?.columns.firstIndex(where: { $0.name == column }) else { continue }
            let id = key(row[0], name)
            if row[3] == "PRIMARY KEY" {
                tables[id]?.columns[index].isPrimaryKey = true
            } else if let target = row[5] {
                let targetName = single ? target : (row[4] ?? "public") == "public" ? target : "\(row[4]!).\(target)"
                tables[id]?.columns[index].references = (targetName, row[6] ?? "")
            }
        }
        for row in results[3].rows where row.count >= 4 {
            guard let name = row[1] else { continue }
            let id = key(row[0], name)
            tables[id]?.rows = row[2].flatMap { Int($0) }
            tables[id]?.bytes = row[3].flatMap { Int($0) }
        }
        schema.tables = order.compactMap { tables[$0] }
        if results.count >= 5 { schema.bytes = results[4].rows.first?.first.flatMap { $0 }.flatMap { Int($0) } }
        return schema
    }

    /// "PostgreSQL 17.2 on aarch64…" → "PostgreSQL 17.2"
    static func shortVersion(_ text: String) -> String {
        if text.hasPrefix("PostgreSQL") { return text.split(separator: " ").prefix(2).joined(separator: " ") }
        if text.hasPrefix("SQLite") { return text }
        return "MySQL " + (text.split(separator: "-").first.map(String.init) ?? text)
    }

    /// A page of a table's rows.
    public static func browse(_ table: DatabaseSchema.Table, engine: DatabaseEngine, limit: Int, offset: Int,
                              orderBy: String? = nil, descending: Bool = false, filter: String? = nil) -> String {
        var sql = "select * from \(table.sqlName(for: engine))"
        if let filter, !filter.trimmingCharacters(in: .whitespaces).isEmpty { sql += " where \(filter)" }
        if let orderBy { sql += " order by \(SQLScript.quote(orderBy, for: engine))\(descending ? " desc" : "")" }
        else if !table.primaryKey.isEmpty { sql += " order by " + table.primaryKey.map { SQLScript.quote($0, for: engine) }.joined(separator: ", ") }
        sql += " limit \(limit) offset \(offset)"
        return sql
    }

    /// The query that explains another, per engine.
    public static func explain(_ sql: String, engine: DatabaseEngine) -> String {
        switch engine {
        case .postgres: "explain (format text, costs true) \(sql)"
        case .mysql: "explain format=tree \(sql)"
        case .sqlite: "explain query plan \(sql)"
        }
    }
}
