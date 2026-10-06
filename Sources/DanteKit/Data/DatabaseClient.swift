import Foundation

/// What one statement gave back: rows, or a status like "UPDATE 3".
public struct QueryResult: Equatable, Sendable, Identifiable {
    public var id: Int
    public var statement: String
    public var columns: [String]
    /// nil is SQL NULL.
    public var rows: [[String?]]
    public var message: String?
    /// More rows came back than Dante keeps.
    public var truncated: Bool

    public init(id: Int = 0, statement: String = "", columns: [String] = [], rows: [[String?]] = [], message: String? = nil, truncated: Bool = false) {
        self.id = id
        self.statement = statement
        self.columns = columns
        self.rows = rows
        self.message = message
        self.truncated = truncated
    }

    public var hasRows: Bool { !columns.isEmpty }
}

/// A script's results, and the error that stopped it, if any.
public struct QueryRun: Equatable, Sendable {
    public var results: [QueryResult]
    public var error: String?
    public var elapsed: Duration

    public init(results: [QueryResult] = [], error: String? = nil, elapsed: Duration = .zero) {
        self.results = results
        self.error = error
        self.elapsed = elapsed
    }
}

/// Runs SQL through the engine's command-line client. Each statement is a separate
/// argument, with a marker printed after it, so one session runs the whole script
/// (transactions and temporary tables work) and the output splits back into results.
public enum DatabaseClient {
    /// Rows kept per result. Browsing pages with LIMIT, so this only caps ad hoc queries.
    public static let rowLimit = 5000
    static let null = "\u{2400}NULL\u{2400}"
    static let marker = "@@dante:"

    /// How a connection is reached: the client on this Mac, or the one in its container.
    public enum Route: Equatable, Sendable {
        case local(String)
        case compose(service: String)
        case missing
    }

    public static func route(for connection: DatabaseConnection, hasCompose: Bool) -> Route {
        if let path = Shell.which(connection.engine.client) { return .local(path) }
        if hasCompose, let service = connection.service, Shell.which("docker") != nil { return .compose(service: service) }
        return .missing
    }

    /// The command and environment for a script. Passwords go in the environment, never
    /// the arguments, where `ps` would show them.
    public static func command(for statements: [SQLStatement], on connection: DatabaseConnection, password: String?,
                               route: Route, projectRoot: URL) -> (arguments: [String], environment: [String: String]) {
        var environment: [String: String] = [:]
        var pieces: [String] = []
        let base: [String]
        switch connection.engine {
        case .postgres:
            if let password { environment["PGPASSWORD"] = password }
            environment["PGCONNECT_TIMEOUT"] = "8"
            environment["PGAPPNAME"] = "Dante"
            var options = "-c statement_timeout=120000"
            if connection.readOnly { options += " -c default_transaction_read_only=on" }
            environment["PGOPTIONS"] = options
            var flags = ["-X", "-v", "ON_ERROR_STOP=1", "--csv", "-P", "null=\(null)", "-P", "pager=off"]
            if case .compose = route {
                flags += ["-U", connection.user.isEmpty ? "postgres" : connection.user, "-d", connection.database]
            } else {
                flags += ["-h", connection.host, "-d", connection.database]
                if let port = connection.port { flags += ["-p", "\(port)"] }
                if !connection.user.isEmpty { flags += ["-U", connection.user] }
            }
            for (index, statement) in statements.enumerated() {
                pieces += ["-c", statement.text, "-c", "\\echo \(marker)\(index)"]
            }
            base = ["psql"] + flags
        case .mysql:
            if let password { environment["MYSQL_PWD"] = password }
            var flags = ["--batch", "--default-character-set=utf8mb4", "--connect-timeout=8"]
            if case .compose = route {
                flags += ["-u", connection.user.isEmpty ? "root" : connection.user, "-D", connection.database]
            } else {
                flags += ["-h", connection.host == "localhost" ? "127.0.0.1" : connection.host, "-u", connection.user, "-D", connection.database]
                if let port = connection.port { flags += ["-P", "\(port)"] }
            }
            var script = connection.readOnly ? "SET SESSION TRANSACTION READ ONLY;\n" : ""
            for (index, statement) in statements.enumerated() {
                script += statement.text + ";\n"
                if statement.kind == .write, !statement.returnsRows { script += "SELECT ROW_COUNT() AS rows_affected;\n" }
                script += "SELECT '\(marker)\(index)' AS `@@dante`;\n"
            }
            pieces = ["-e", script]
            base = ["mysql"] + flags
        case .sqlite:
            let path = connection.fileURL(projectRoot: projectRoot)?.path ?? connection.database
            var flags = ["-bail", "-csv", "-header", "-nullvalue", null]
            if connection.readOnly { flags.append("-readonly") }
            for (index, statement) in statements.enumerated() {
                pieces.append(statement.text)
                if statement.kind == .write, !statement.returnsRows { pieces.append("SELECT changes() AS rows_affected") }
                pieces.append(".print \(marker)\(index)")
            }
            base = ["sqlite3"] + flags + [path]
        }
        switch route {
        case .compose(let service):
            let passed = environment.keys.sorted().flatMap { ["-e", $0] }
            return (["docker", "compose", "exec", "-T"] + passed + [service] + base + pieces, environment)
        case .local(let path):
            return ([path] + base.dropFirst() + pieces, environment)
        case .missing:
            return (base + pieces, environment)
        }
    }

    public static func run(_ script: String, on connection: DatabaseConnection, password: String?, projectRoot: URL, hasCompose: Bool) async -> QueryRun {
        let statements = SQLScript.statements(script)
        guard !statements.isEmpty else { return QueryRun(error: "Nothing to run.") }
        if connection.readOnly, let write = statements.first(where: \.changesData) {
            return QueryRun(error: "\(connection.name) is read-only, so Dante won’t run “\(write.text.prefix(60))”. Turn off read-only in the connection to change data.")
        }
        let route = route(for: connection, hasCompose: hasCompose)
        if route == .missing {
            return QueryRun(error: "Dante needs \(connection.engine.client) to talk to \(connection.engine.name). Install it with: \(connection.engine.install)")
        }
        let (arguments, environment) = command(for: statements, on: connection, password: password, route: route, projectRoot: projectRoot)
        let clock = ContinuousClock()
        let start = clock.now
        let output = await Shell.run(arguments, in: projectRoot, trimming: false, extra: environment)
        let elapsed = clock.now - start
        var run = parse(output.stdout, statements: statements, engine: connection.engine)
        run.elapsed = elapsed
        if !output.succeeded || run.results.count < statements.count {
            let message = cleanError(output.stderr.isEmpty ? output.stdout : output.stderr)
            run.error = message.isEmpty ? "\(connection.engine.client) stopped (exit \(output.status))." : message
        }
        return run
    }

    /// Splits the client's output at the markers and reads each piece.
    public static func parse(_ output: String, statements: [SQLStatement], engine: DatabaseEngine) -> QueryRun {
        var results: [QueryResult] = []
        var rest = Substring(output)
        for (index, statement) in statements.enumerated() {
            let tag = "\(marker)\(index)"
            // MySQL prints the marker's column name on the line before.
            let pattern = engine == .mysql ? "@@dante\n\(tag)\n" : "\(tag)\n"
            guard let range = rest.range(of: pattern) ?? (rest.hasSuffix(tag) ? rest.range(of: tag, options: .backwards) : nil) else { break }
            let chunk = rest[..<range.lowerBound]
            rest = rest[range.upperBound...]
            results.append(read(String(chunk), statement: statement, engine: engine, id: index))
        }
        return QueryRun(results: results)
    }

    static func read(_ chunk: String, statement: SQLStatement, engine: DatabaseEngine, id: Int) -> QueryResult {
        var result = QueryResult(id: id, statement: statement.text)
        let text = chunk.hasSuffix("\n") ? String(chunk.dropLast()) : chunk
        if text.isEmpty {
            // SQLite prints nothing, not even a header, for an empty result.
            result.message = statement.returnsRows ? "No rows" : "Done"
            return result
        }
        let table = engine == .mysql ? TabularText.tsv(text, limit: rowLimit + 1) : TabularText.csv(text, null: null, limit: rowLimit + 1)
        // Postgres prints a status line ("UPDATE 3", "BEGIN") for statements without rows.
        if engine == .postgres, !statement.returnsRows, table.count == 1, table[0].count == 1, let line = table[0][0] {
            result.message = line
            return result
        }
        guard let header = table.first else { return result }
        var rows = Array(table.dropFirst())
        // The rows_affected line Dante adds after writes.
        if header == ["rows_affected"], rows.count == 1, let count = rows[0].first ?? nil {
            result.message = "\(count) row\(count == "1" ? "" : "s") affected"
            return result
        }
        result.columns = header.map { $0 ?? "" }
        if rows.count > rowLimit {
            rows.removeLast(rows.count - rowLimit)
            result.truncated = true
        }
        result.rows = rows
        return result
    }

    /// The useful part of a client's error.
    static func cleanError(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                var line = line
                for prefix in ["psql: ", "Error: ", "ERROR 1064 (42000) at line 1: "] where line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
                if line.hasPrefix("ERROR:  ") { line = String(line.dropFirst(8)) }
                return line
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("mysql: [Warning]") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// CSV and MySQL's tab-separated batch output, as rows of optional strings.
public enum TabularText {
    public static func csv(_ text: String, null: String? = nil, limit: Int = .max) -> [[String?]] {
        var rows: [[String?]] = []
        var row: [String?] = []
        var field = ""
        var quoted = false
        var wasQuoted = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        func endField() {
            row.append(!wasQuoted && field == null ? nil : field)
            field = ""
            wasQuoted = false
        }
        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    let next = iterator.next()
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty: quoted = true; wasQuoted = true
            case ",": endField()
            case "\n", "\r\n":
                endField()
                rows.append(row)
                row = []
                if rows.count >= limit { return rows }
            case "\r": continue
            default: field.append(c)
            }
        }
        if !field.isEmpty || wasQuoted || !row.isEmpty {
            endField()
            rows.append(row)
        }
        return rows
    }

    /// `mysql --batch`: tabs between fields, \t \n \\ \0 escaped, NULL for null.
    public static func tsv(_ text: String, limit: Int = .max) -> [[String?]] {
        var rows: [[String?]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            rows.append(line.split(separator: "\t", omittingEmptySubsequences: false).map { field in
                if field == "NULL" { return nil }
                guard field.contains("\\") else { return String(field) }
                var out = ""
                var escaped = false
                for c in field {
                    if escaped {
                        switch c {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "0": out.append("\0")
                        default: out.append(c)
                        }
                        escaped = false
                    } else if c == "\\" {
                        escaped = true
                    } else {
                        out.append(c)
                    }
                }
                return out
            })
            if rows.count >= limit { break }
        }
        return rows
    }
}

public extension QueryResult {
    /// Columns whose values are all numbers, to right-align.
    var numericColumns: Set<Int> {
        var numeric = Set(columns.indices)
        for row in rows.prefix(200) {
            for (index, value) in row.enumerated() where numeric.contains(index) {
                if let value, Double(value) == nil { numeric.remove(index) }
            }
        }
        // A column of nothing but NULLs isn't numeric.
        return numeric.filter { index in rows.prefix(200).contains { index < $0.count && $0[index] != nil } }
    }

    var csv: String {
        func field(_ value: String?) -> String {
            guard let value else { return "" }
            return value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        return ([columns.map(field)] + rows.map { $0.map(field) }).map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// A Markdown table of up to `limit` rows, for pasting into docs or Claude.
    func markdown(limit: Int = 50) -> String {
        func cell(_ value: String?) -> String {
            (value ?? "NULL").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = ["| " + columns.map(cell).joined(separator: " | ") + " |", "|" + columns.map { _ in " --- |" }.joined()]
        lines += rows.prefix(limit).map { "| " + $0.map(cell).joined(separator: " | ") + " |" }
        if rows.count > limit { lines.append("\n…and \(rows.count - limit) more rows") }
        return lines.joined(separator: "\n")
    }

    /// One row as a JSON object.
    func json(row index: Int) -> String {
        guard rows.indices.contains(index) else { return "{}" }
        var object: [String: JSONValue] = [:]
        for (column, value) in zip(columns, rows[index]) { object[column] = value.map { .string($0) } ?? .null }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(JSONValue.object(object))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
