import Foundation

/// A SQL Server backup (`.bak`) Dante can restore: one in the project, one already inside the
/// server's container, or one chosen from anywhere on this Mac.
public struct DatabaseBackup: Equatable, Hashable, Sendable, Identifiable {
    public enum Place: Equatable, Hashable, Sendable {
        /// Relative to the project root.
        case project(String)
        /// A path inside the server's container.
        case container(String)
        /// A file chosen from this Mac.
        case file(URL)
    }

    public var place: Place
    public var bytes: Int?
    public var modified: Date?

    public init(place: Place, bytes: Int? = nil, modified: Date? = nil) {
        self.place = place
        self.bytes = bytes
        self.modified = modified
    }

    public var id: String {
        switch place {
        case .project(let path): "project:" + path
        case .container(let path): "container:" + path
        case .file(let url): "file:" + url.path
        }
    }

    public var name: String {
        switch place {
        case .project(let path), .container(let path): (path as NSString).lastPathComponent
        case .file(let url): url.lastPathComponent
        }
    }

    /// Where it is, for the row under its name.
    public var location: String {
        switch place {
        case .project(let path):
            let folder = (path as NSString).deletingLastPathComponent
            return folder.isEmpty ? "In the project" : "In \(folder)/"
        case .container(let path): return "In the container, \((path as NSString).deletingLastPathComponent)/"
        case .file(let url): return url.deletingLastPathComponent().path
        }
    }

    /// The name the database most likely had: the file's, without dates or copy suffixes.
    public var suggestedDatabase: String {
        var stem = (name as NSString).deletingPathExtension
        stem = stem.replacingOccurrences(of: #"[-_ ]?(\d{4}-?\d{2}-?\d{2}([-_T ]?\d{2,6})?|copy|backup|full)$"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        return stem.isEmpty ? "restored" : stem
    }
}

/// One file inside a backup: `RESTORE FILELISTONLY` rows.
public struct BackupFile: Equatable, Sendable {
    public var logicalName: String
    public var physicalName: String
    /// D data, L log, F full-text or FILESTREAM, S FILESTREAM.
    public var type: String

    public init(logicalName: String, physicalName: String, type: String) {
        self.logicalName = logicalName
        self.physicalName = physicalName
        self.type = type
    }
}

/// What `RESTORE HEADERONLY` says about a backup.
public struct BackupHeader: Equatable, Sendable {
    public var database: String?
    public var server: String?
    public var finished: String?
    public var version: String?

    public init(database: String? = nil, server: String? = nil, finished: String? = nil, version: String? = nil) {
        self.database = database
        self.server = server
        self.finished = finished
        self.version = version
    }
}

/// Finding and restoring SQL Server backups in the server's Docker container. Restores read
/// the file from the container's disk, so a backup in the project is copied in first, to
/// `/var/opt/mssql/backup`, the way Microsoft's own instructions do it.
public enum SQLServerBackups {
    public static let containerFolder = "/var/opt/mssql/backup"
    public static let dataFolder = "/var/opt/mssql/data"

    /// Backups in the project, outside dependencies and build output.
    public static func inProject(_ files: [String]) -> [String] {
        let skipped: Set<String> = ["node_modules", "bin", "obj", "vendor", ".git"]
        return files.filter { path in
            (path as NSString).pathExtension.lowercased() == "bak"
                && !path.split(separator: "/").dropLast().contains { skipped.contains(String($0)) }
        }
    }

    /// Lists the backups in the container: size, modified time and path on each line.
    public static let listCommand = ["sh", "-c", "find \(containerFolder) -maxdepth 2 -type f -iname '*.bak' -printf '%s\\t%T@\\t%p\\n' 2>/dev/null; true"]

    public static func parseList(_ output: String) -> [DatabaseBackup] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[2].hasPrefix("/") else { return nil }
            return DatabaseBackup(place: .container(parts[2]), bytes: Int(parts[0]),
                                  modified: Double(parts[1]).map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// Makes a file copied in readable by SQL Server, which runs as its own user while
    /// `docker cp` leaves the file root's (and only the owner's, when it was 0600 here).
    public static func readableCommand(_ path: String) -> [String] {
        ["sh", "-c", "chmod a+r \"$1\" && chown mssql \"$1\" 2>/dev/null; true", "sh", path]
    }

    /// Where a backup lands inside the container.
    public static func containerPath(for backup: DatabaseBackup) -> String {
        if case .container(let path) = backup.place { return path }
        return containerFolder + "/" + backup.name
    }

    static func literal(_ text: String) -> String { "N" + SQLScript.literal(text) }

    public static func headerSQL(path: String) -> String { "RESTORE HEADERONLY FROM DISK = \(literal(path))" }
    public static func fileListSQL(path: String) -> String { "RESTORE FILELISTONLY FROM DISK = \(literal(path))" }

    public static func header(from result: QueryResult?) -> BackupHeader {
        guard let result, let row = result.rows.first else { return BackupHeader() }
        func value(_ column: String) -> String? {
            result.columns.firstIndex(of: column).flatMap { $0 < row.count ? row[$0] : nil }.flatMap { $0?.isEmpty == false ? $0 : nil }
        }
        let major = value("SoftwareVersionMajor")
        return BackupHeader(database: value("DatabaseName"), server: value("ServerName"), finished: value("BackupFinishDate"),
                            version: major.map { "SQL Server \(versionName($0))" })
    }

    static func versionName(_ major: String) -> String {
        ["10": "2008", "11": "2012", "12": "2014", "13": "2016", "14": "2017", "15": "2019", "16": "2022", "17": "2025"][major] ?? "version \(major)"
    }

    public static func files(from result: QueryResult?) -> [BackupFile] {
        guard let result, let logical = result.columns.firstIndex(of: "LogicalName"),
              let physical = result.columns.firstIndex(of: "PhysicalName"), let type = result.columns.firstIndex(of: "Type") else { return [] }
        return result.rows.compactMap { row in
            guard let name = row[safe: logical] ?? nil else { return nil }
            return BackupFile(logicalName: name, physicalName: (row[safe: physical] ?? nil) ?? "", type: (row[safe: type] ?? nil) ?? "D")
        }
    }

    /// Where each file goes in the container: the first data file as `<db>.mdf`, others
    /// `.ndf`, logs `.ldf`, FILESTREAM as folders.
    public static func moves(_ files: [BackupFile], database: String) -> [(logical: String, to: String)] {
        let base = database.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        var data = 0, logs = 0, streams = 0
        return files.map { file in
            switch file.type.uppercased() {
            case "L":
                logs += 1
                return (file.logicalName, "\(dataFolder)/\(base)_log\(logs == 1 ? "" : "\(logs)").ldf")
            case "S", "F":
                streams += 1
                return (file.logicalName, "\(dataFolder)/\(base)_fs\(streams)")
            default:
                data += 1
                return (file.logicalName, "\(dataFolder)/\(base)\(data == 1 ? ".mdf" : "_\(data).ndf")")
            }
        }
    }

    /// The restore, run against `master`: other sessions are put out first (the app may hold
    /// the database open), and a restored database is made `sa`'s when asked, since one from
    /// another server keeps an owner this server doesn't know, which stops Service Broker.
    public static func restoreSQL(path: String, database: String, files: [BackupFile], makeSaOwner: Bool) -> String {
        let name = SQLScript.quote(database, for: .sqlserver)
        let moves = moves(files, database: database).map { "MOVE \(literal($0.logical)) TO \(literal($0.to))" }
        var lines = [
            "IF DB_ID(\(literal(database))) IS NOT NULL ALTER DATABASE \(name) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;",
            "RESTORE DATABASE \(name) FROM DISK = \(literal(path)) WITH " + (moves + ["REPLACE", "RECOVERY", "STATS = 10"]).joined(separator: ", ") + ";",
            "ALTER DATABASE \(name) SET MULTI_USER;",
        ]
        if makeSaOwner { lines.append("ALTER AUTHORIZATION ON DATABASE::\(name) TO sa;") }
        return lines.joined(separator: "\n")
    }

    /// A copy-only full backup, which leaves the server's own backup chain alone.
    public static func backupSQL(database: String, path: String) -> String {
        "BACKUP DATABASE \(SQLScript.quote(database, for: .sqlserver)) TO DISK = \(literal(path)) WITH COPY_ONLY, INIT, STATS = 10"
    }

    /// `shop-2026-11-27-1530.bak`
    public static func backupName(database: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let base = database.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return "\(base)-\(formatter.string(from: date)).bak"
    }

    /// Databases the server holds besides its own.
    public static let databasesSQL = "SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name"
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
