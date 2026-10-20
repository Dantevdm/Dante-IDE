import Foundation

/// Suggestions for a database, from the repo's SQL and the code that queries it: foreign keys
/// and filtered columns without an index, tables without a primary key, money in floating
/// point, times without a zone, `SELECT *`, and queries run once per item in a loop. Each says
/// why and, where it's a schema change, the SQL for a migration. Static: it can't see how big
/// the tables are, so index advice is for when they grow.
public struct SchemaAdvice: Identifiable, Equatable, Sendable, Hashable {
    public enum Kind: String, Sendable {
        case foreignKeyIndex, filterIndex, primaryKey, money, timeZone, selectStar, queryInLoop
    }

    public enum Weight: Int, Sendable, Comparable {
        case note, suggestion, warning
        public static func < (a: Weight, b: Weight) -> Bool { a.rawValue < b.rawValue }
    }

    public var kind: Kind
    public var weight: Weight
    public var table: String?
    public var column: String?
    public var title: String
    public var detail: String
    /// SQL for a migration, when the fix is one.
    public var fix: String?
    /// Where it shows: the code for a query, the CREATE TABLE for the schema.
    public var file: String?
    public var line: Int?

    public var id: String { [kind.rawValue, table ?? "", column ?? "", file ?? "", line.map(String.init) ?? ""].joined(separator: ":") }

    /// Every suggestion, most important first.
    public static func analyse(_ tables: [SystemMap.TableSchema], files: [String], read: (String) -> String?) -> [SchemaAdvice] {
        var advice: [SchemaAdvice] = []
        for table in tables {
            if !table.columns.contains(where: \.primaryKey), !table.columns.isEmpty {
                advice.append(SchemaAdvice(kind: .primaryKey, weight: .warning, table: table.name, title: "\(table.name) has no primary key",
                                           detail: "Without one, rows can't be told apart reliably: updates and deletes by row, replication and most ORMs need it.",
                                           file: table.file, line: table.line))
            }
            for column in table.columns {
                if let target = column.references, !table.isIndexed([column.name]) {
                    advice.append(SchemaAdvice(kind: .foreignKeyIndex, weight: .suggestion, table: table.name, column: column.name,
                                               title: "Index \(table.name).\(column.name)",
                                               detail: "It references \(target), but nothing indexes it: joining \(table.name) to \(target), and deleting from \(target), scan the whole table.",
                                               fix: "CREATE INDEX \(table.name)_\(column.name)_idx ON \(table.name) (\(column.name));", file: table.file, line: table.line))
                }
                let name = column.name.lowercased()
                let type = column.type.lowercased()
                if ["real", "float", "double", "double precision", "float4", "float8"].contains(type),
                   ["price", "amount", "total", "cost", "balance", "fee", "salary", "money", "payment", "tax"].contains(where: name.contains) {
                    advice.append(SchemaAdvice(kind: .money, weight: .warning, table: table.name, column: column.name,
                                               title: "\(table.name).\(column.name) holds money as \(type)",
                                               detail: "Floating point can't hold amounts like 0.10 exactly, so sums drift by cents. Use numeric with a fixed scale.",
                                               fix: "ALTER TABLE \(table.name) ALTER COLUMN \(column.name) TYPE numeric(12, 2);", file: table.file, line: table.line))
                }
                if type == "timestamp" || type == "timestamp without time zone" {
                    advice.append(SchemaAdvice(kind: .timeZone, weight: .note, table: table.name, column: column.name,
                                               title: "\(table.name).\(column.name) has no time zone",
                                               detail: "A timestamp without a zone is read in whatever zone the server or client is in. timestamptz stores the instant.",
                                               fix: "ALTER TABLE \(table.name) ALTER COLUMN \(column.name) TYPE timestamptz;", file: table.file, line: table.line))
                }
            }
        }
        advice += codeAdvice(tables, files: files, read: read)
        // One per id (a query can be found twice), worst first, then by table.
        var seen: Set<String> = []
        return advice.filter { seen.insert($0.id).inserted }
            .sorted { ($0.weight, $1.table ?? "", $1.kind.rawValue) > ($1.weight, $0.table ?? "", $0.kind.rawValue) }
    }

    /// What the code's queries filter by, `SELECT *`, and queries inside loops.
    static func codeAdvice(_ tables: [SystemMap.TableSchema], files: [String], read: (String) -> String?) -> [SchemaAdvice] {
        guard !tables.isEmpty else { return [] }
        let byName = Dictionary(tables.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var advice: [SchemaAdvice] = []
        var filtered: [String: (columns: [String], file: String, line: Int)] = [:]
        let code = files.filter { SystemMap.isCode($0) && !SystemMap.isTest($0) && !$0.lowercased().hasSuffix(".sql") }
        // JPA: an entity's table, for derived queries on its repository.
        var entityTables: [String: String] = [:]
        for file in code where SystemMap.isJVM(file) {
            guard let text = read(file), SystemMap.has(text, "@Entity"), let entity = SystemMap.entity(in: text) else { continue }
            if byName[entity.table.lowercased()] != nil { entityTables[entity.name] = entity.table.lowercased() }
        }
        for file in code {
            guard let text = read(file) else { continue }
            let lower = text.lowercased()
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let hasSQL = SystemMap.has(lower, "select") || SystemMap.has(lower, "where")
            if hasSQL {
                for (number, raw) in lines.enumerated() {
                    let line = raw.lowercased()
                    guard line.contains("select") || line.contains("where") else { continue }
                    // The statement may run over a few lines of a string.
                    let window = lines[number..<min(lines.count, number + 4)].joined(separator: " ").lowercased()
                    if line.contains("select *"), let from = window.firstMatch(of: /select\s+\*\s+from\s+["`]?(\w+)/), byName[String(from.1)] != nil {
                        advice.append(SchemaAdvice(kind: .selectStar, weight: .note, table: String(from.1),
                                                   title: "SELECT * from \(from.1)",
                                                   detail: "It fetches every column, including ones added later, and breaks code that reads columns by position. Name the columns it needs.",
                                                   file: file, line: number + 1))
                    }
                    guard line.contains("where"), let match = window.firstMatch(of: /from\s+["`]?(\w+)["`]?(?:\s+(?:as\s+)?(\w+))?[^;]*?\bwhere\s+(.*)/),
                          let table = byName[String(match.1)] else { continue }
                    let alias = match.2.map(String.init)
                    let clause = String(match.3).prefix(240)
                    var columns: [String] = []
                    for hit in clause.matches(of: /(?:(\w+)\.)?(\w+)\s*(?:=|<|>|\bin\b|\blike\b|\bbetween\b|\bis\b)/) {
                        if let owner = hit.1.map(String.init), owner != alias, owner != table.name.lowercased() { continue }
                        let name = String(hit.2)
                        if table.columns.contains(where: { $0.name.lowercased() == name }), !columns.contains(name) { columns.append(name) }
                    }
                    if !columns.isEmpty, filtered[table.name.lowercased() + ":" + columns.joined(separator: ",")] == nil {
                        filtered[table.name.lowercased() + ":" + columns.joined(separator: ",")] = (columns, file, number + 1)
                    }
                }
            }
            // Spring Data: findByStatusAndCustomer → status, customer(_id).
            if SystemMap.isJVM(file), let repository = text.firstMatch(of: /Repository<\s*(\w+)\s*,/), let table = entityTables[String(repository.1)].flatMap({ byName[$0] }) {
                for (number, raw) in lines.enumerated() {
                    guard let method = raw.firstMatch(of: /\b(?:find|read|get|query|count|exists|delete|stream)(?:First\d*|Top\d*|Distinct|All)*By(\w+?)(?:OrderBy\w+)?\s*\(/) else { continue }
                    var columns: [String] = []
                    for property in String(method.1).split(separator: /And|Or/).map(String.init) {
                        let plain = property.replacing(/(IgnoreCase|Containing|StartingWith|EndingWith|Between|LessThanEqual|LessThan|GreaterThanEqual|GreaterThan|After|Before|IsNull|IsNotNull|NotNull|Null|In|NotIn|Not|Like|True|False|Is|Equals)$/, with: "")
                        let snake = plain.replacing(/([a-z0-9])([A-Z])/) { "\($0.1)_\($0.2)" }.lowercased()
                        if let column = table.columns.first(where: { [snake, snake + "_id"].contains($0.name.lowercased()) }) { columns.append(column.name.lowercased()) }
                    }
                    if !columns.isEmpty { filtered[table.name.lowercased() + ":" + columns.joined(separator: ","), default: (columns, file, number + 1)] = (columns, file, number + 1) }
                }
            }
            // A query per item: a repository or query call inside a for loop.
            for (number, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("for ") || line.hasPrefix("for(") || line.contains(".forEach(") || line.contains(".forEach {") else { continue }
                let body = lines[(number + 1)..<min(lines.count, number + 7)]
                guard let call = body.firstIndex(where: { $0.range(of: #"(?i)\b\w*(repository|repo|dao)\.(find|get|load|fetch|query|select)\w*\(|\.(query|execute|exec|fetch|fetchone|fetchall)\(\s*["'`f]"#, options: .regularExpression) != nil }) else { continue }
                advice.append(SchemaAdvice(kind: .queryInLoop, weight: .suggestion, title: "A query for each item in a loop",
                                           detail: "\((file as NSString).lastPathComponent) queries the database once per item. With many items that's many round trips: load them in one query (IN, a join, or a batch method) before the loop.",
                                           file: file, line: call + 1))
            }
        }
        for (key, found) in filtered {
            guard let table = byName[String(key.split(separator: ":")[0])], !table.isIndexed(found.columns) else { continue }
            // A single column also counts when it leads an index with more.
            if found.columns.count > 1, table.isIndexed([found.columns[0]]) { continue }
            let list = found.columns.joined(separator: ", ")
            advice.append(SchemaAdvice(kind: .filterIndex, weight: .suggestion, table: table.name, column: list,
                                       title: "Index \(table.name) (\(list))",
                                       detail: "\((found.file as NSString).lastPathComponent) looks rows up by \(list), and no index starts with \(found.columns.count == 1 ? "it" : "them"): fine while \(table.name) is small, a full scan once it grows.",
                                       fix: "CREATE INDEX \(table.name)_\(found.columns.joined(separator: "_"))_idx ON \(table.name) (\(list));",
                                       file: found.file, line: found.line))
        }
        return advice
    }
}
