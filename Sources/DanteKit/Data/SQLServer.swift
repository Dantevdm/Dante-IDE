import Foundation

/// SQL Server through `sqlcmd`: the script it reads, the flags it takes and how its output
/// splits back into results; connection strings from .NET settings and JDBC URLs; and the
/// `.bak` backups a project keeps, restored into the server's container.
public enum SQLServer {
    /// Between fields. A control character, so commas and tabs in values stay put.
    static let separator = "\u{1F}"
    /// Variable-length values (`nvarchar(max)`) are cut at this many characters; without a
    /// width sqlcmd cuts them at 256, and with 0 it drops the column names.
    static let valueWidth = 8000

    /// Where the client sits inside Microsoft's images: tools18 from 2022, tools before.
    public static let containerClients = ["/opt/mssql-tools18/bin/sqlcmd", "/opt/mssql-tools/bin/sqlcmd"]

    /// sqlcmd's flags, after the program. `inside` is the client in the server's container,
    /// which reaches it as localhost.
    static func flags(for connection: DatabaseConnection, inside: Bool) -> [String] {
        var flags: [String]
        if inside {
            flags = ["-S", "localhost"]
        } else {
            let host = connection.host == "localhost" ? "127.0.0.1" : connection.host
            flags = ["-S", connection.port.map { "\(host),\($0)" } ?? host]
        }
        flags += ["-U", connection.user.isEmpty ? "sa" : connection.user]
        if !connection.database.isEmpty { flags += ["-d", connection.database] }
        // -C trusts the server's own certificate, as every local SQL Server's is; -b stops at
        // the first error; -l is the login timeout.
        flags += ["-C", "-b", "-l", "8", "-s", separator, "-y", "\(valueWidth)", "-w", "65535"]
        return flags
    }

    /// The script, read from stdin: each statement in a batch of its own (so CREATE VIEW and
    /// CREATE PROCEDURE, which must start a batch, work) and a marker printed after it.
    public static func script(_ statements: [SQLStatement]) -> String {
        var script = "SET NOCOUNT ON;\nGO\n"
        for (index, statement) in statements.enumerated() {
            script += statement.text + "\n"
            // @@ROWCOUNT only lasts until the batch ends.
            if statement.kind == .write, !statement.returnsRows { script += "SELECT @@ROWCOUNT AS rows_affected;\n" }
            script += "GO\nPRINT '\(DatabaseClient.marker)\(index)';\nGO\n"
        }
        return script
    }

    /// The client inside a container, wherever the image keeps it.
    static func containerCommand(_ flags: [String]) -> [String] {
        let find = containerClients.map { "[ -x \($0) ] && exec \($0) \"$@\"" }.joined(separator: "; ")
        return ["sh", "-c", find + "; echo 'sqlcmd isn’t in this container' >&2; exit 127", "sqlcmd"] + flags
    }

    /// One result's text: column names, a line of dashes, then rows, every field padded to
    /// its column's width.
    static func table(_ text: String, limit: Int) -> [[String?]] {
        var rows: [[String?]] = []
        var header: [String]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }
            if header == nil {
                header = fields
                rows.append(fields)
                continue
            }
            // The dashes under the names.
            if rows.count == 1, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" } }) { continue }
            rows.append(fields.map { $0 == "NULL" ? nil : $0 })
            if rows.count >= limit { break }
        }
        return rows
    }

    /// The error lines sqlcmd prints among its results: "Msg 208, Level 16, …" and the
    /// message after it.
    static func errors(in output: String) -> String? {
        let lines = output.components(separatedBy: "\n")
        var found: [String] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("Msg ") && line.contains(", Level ") {
            let level = line.firstMatch(of: /Level (\d+)/).flatMap { Int($0.1) } ?? 16
            // Level 10 and below are information.
            guard level > 10 else { continue }
            if index + 1 < lines.count { found.append(lines[index + 1].trimmingCharacters(in: .whitespaces)) }
        }
        if found.isEmpty, let line = lines.first(where: { $0.hasPrefix("Sqlcmd: Error:") }) {
            found.append(line.replacingOccurrences(of: "Sqlcmd: Error: ", with: ""))
        }
        return found.isEmpty ? nil : found.joined(separator: "\n")
    }

    // MARK: Connection strings

    /// An ADO.NET connection string (`Server=localhost,1433;Database=Shop;User Id=sa;
    /// Password=…`) and the password in it. Npgsql's (`Host=…;Username=…`) is PostgreSQL.
    public static func connection(adoNet text: String, name: String? = nil, note: String? = nil) -> DatabaseConnection? {
        var values: [String: String] = [:]
        for pair in text.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            values[parts[0].lowercased().replacingOccurrences(of: " ", with: "")] = parts[1]
        }
        if values["server"] == nil, values["datasource"] == nil, let host = values["host"], !host.contains("${") {
            guard let database = values["database"], !database.contains("${") else { return nil }
            return DatabaseConnection(name: name ?? database, engine: .postgres, host: host, port: values["port"].flatMap { Int($0) },
                                      database: database, user: values["username"] ?? values["userid"] ?? values["user"] ?? "postgres",
                                      origin: .detected, note: note, devPassword: values["password"].flatMap { $0.contains("${") || $0.isEmpty ? nil : $0 })
        }
        guard var server = values["server"] ?? values["datasource"] ?? values["address"] ?? values["addr"] else { return nil }
        let database = values["database"] ?? values["initialcatalog"] ?? "master"
        if server.lowercased().hasPrefix("tcp:") { server.removeFirst(4) }
        var host = server
        var port: Int? = 1433
        if let comma = server.firstIndex(of: ",") {
            host = String(server[..<comma])
            port = Int(server[server.index(after: comma)...].trimmingCharacters(in: .whitespaces)) ?? 1433
        }
        // A named instance (`.\SQLEXPRESS`) or `(localdb)` isn't reachable from a Mac.
        if host == "." || host.lowercased() == "(local)" { host = "localhost" }
        guard !host.contains("\\"), !host.hasPrefix("("), !host.contains("${"), !database.contains("${") else { return nil }
        let integrated = ["true", "sspi", "yes"].contains((values["integratedsecurity"] ?? values["trustedconnection"] ?? "").lowercased())
        let user = values["userid"] ?? values["uid"] ?? values["user"] ?? (integrated ? "" : "sa")
        let password = values["password"] ?? values["pwd"]
        return DatabaseConnection(name: name ?? database, engine: .sqlserver, host: host, port: port, database: database, user: user,
                                  origin: .detected, note: note, devPassword: password.flatMap { $0.contains("${") || $0.isEmpty ? nil : $0 })
    }

    /// `jdbc:sqlserver://host:1433;databaseName=Shop;…`
    public static func connection(jdbc text: String, note: String? = nil) -> DatabaseConnection? {
        guard let range = text.range(of: "jdbc:sqlserver://") else { return nil }
        let rest = text[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let parts = rest.split(separator: ";").map(String.init)
        guard let address = parts.first, !address.isEmpty else { return nil }
        var host = address, port: Int? = 1433
        if let colon = address.lastIndex(of: ":") {
            host = String(address[..<colon])
            port = Int(address[address.index(after: colon)...]) ?? 1433
        }
        var database = "master", user = ""
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            switch pair[0].lowercased() {
            case "databasename", "database": database = pair[1]
            case "user", "username": user = pair[1]
            default: break
            }
        }
        guard !host.contains("${") else { return nil }
        return DatabaseConnection(name: database, engine: .sqlserver, host: host, port: port, database: database, user: user, origin: .detected, note: note)
    }

    /// Connection strings in a .NET settings file (`appsettings.json` and its
    /// environment copies): every entry under ConnectionStrings that names a server.
    public static func connections(appSettings text: String, path: String) -> [DatabaseConnection] {
        // .NET reads JSON with comments and a byte-order mark.
        let plain = text.replacingOccurrences(of: "\u{FEFF}", with: "").split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        guard let json = JSONValue(line: plain), let strings = json["ConnectionStrings"]?.object else { return [] }
        return strings.keys.sorted().compactMap { key in
            guard let value = strings[key]?.string else { return nil }
            return connection(adoNet: value, note: "\(key) in \(path)")
        }
    }

    public static func isAppSettings(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "appsettings.json" || name.hasPrefix("appsettings.") && name.hasSuffix(".json")
    }

    /// A compose service running Microsoft's server: the SQL Server image or Azure SQL Edge.
    public static func isServerImage(_ image: String) -> Bool {
        let lower = image.lowercased()
        return lower.contains("mssql/server") || lower.contains("azure-sql-edge") || lower.contains("mssql/rhel/server")
    }
}
