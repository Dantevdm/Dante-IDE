import Foundation

/// The databases the Data area can open. Dante talks to each through its own command-line
/// client (`psql`, `mysql`, `sqlite3`), or through the client inside the project's Docker
/// Compose service when it isn't installed, so there's no driver to bundle.
public enum DatabaseEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    case postgres, mysql, sqlite

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .sqlite: "SQLite"
        }
    }

    public var defaultPort: Int? {
        switch self {
        case .postgres: 5432
        case .mysql: 3306
        case .sqlite: nil
        }
    }

    /// The command-line client Dante runs.
    public var client: String {
        switch self {
        case .postgres: "psql"
        case .mysql: "mysql"
        case .sqlite: "sqlite3"
        }
    }

    /// How to get the client with Homebrew.
    public var install: String {
        switch self {
        case .postgres: "brew install libpq && brew link --force libpq"
        case .mysql: "brew install mysql-client && brew link --force mysql-client"
        case .sqlite: "brew install sqlite"
        }
    }

    /// The Docker image the new-database wizard uses.
    public var image: String? {
        switch self {
        case .postgres: "postgres:17-alpine"
        case .mysql: "mysql:8.4"
        case .sqlite: nil
        }
    }

    /// The URL schemes that mean this engine in a DATABASE_URL.
    static let schemes: [String: DatabaseEngine] = [
        "postgres": .postgres, "postgresql": .postgres, "postgis": .postgres,
        "mysql": .mysql, "mariadb": .mysql, "mysql2": .mysql,
        "sqlite": .sqlite, "sqlite3": .sqlite, "file": .sqlite,
    ]
}

/// A database Dante can connect to. Passwords are never part of it: they live in the
/// Keychain (`DatabasePasswords`), or come from the project's own dev config.
public struct DatabaseConnection: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Origin: String, Codable, Sendable {
        /// Found in the project's files: compose, an example env file, a SQLite file.
        case detected
        /// Added by hand or by the new-database wizard; kept on this Mac only.
        case saved
    }

    public var id: String
    public var name: String
    public var engine: DatabaseEngine
    public var host: String
    public var port: Int?
    public var database: String
    public var user: String
    /// For SQLite: the file, relative to the project root or absolute.
    public var file: String?
    /// The Compose service that runs it, so Dante can start it and use the client inside.
    public var service: String?
    /// Refuse statements that change data. On for anything that isn't on this Mac.
    public var readOnly: Bool
    public var origin: Origin
    /// Where Dante found it, for the sidebar.
    public var note: String?
    /// A password from the project's dev config (a compose file or .env.example), used when
    /// the Keychain has none. Not saved with the connection.
    public var devPassword: String?

    public init(id: String? = nil, name: String, engine: DatabaseEngine, host: String = "localhost", port: Int? = nil,
                database: String, user: String = "", file: String? = nil, service: String? = nil, readOnly: Bool? = nil,
                origin: Origin = .saved, note: String? = nil, devPassword: String? = nil) {
        self.name = name
        self.engine = engine
        self.host = host
        self.port = port ?? engine.defaultPort
        self.database = database
        self.user = user
        self.file = file
        self.service = service
        self.readOnly = readOnly ?? !(engine == .sqlite || Self.isLocal(host))
        self.origin = origin
        self.note = note
        self.devPassword = devPassword
        self.id = id ?? Self.makeID(engine: engine, host: host, port: self.port, database: database, file: file)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, engine, host, port, database, user, file, service, readOnly, origin, note
    }

    static func makeID(engine: DatabaseEngine, host: String, port: Int?, database: String, file: String?) -> String {
        if let file { return "\(engine.rawValue):\(file)" }
        return "\(engine.rawValue)://\(host):\(port.map(String.init) ?? "")/\(database)"
    }

    public static func isLocal(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1", "0.0.0.0", ""].contains(host.lowercased()) || host.hasPrefix("/")
    }

    public var isLocal: Bool { engine == .sqlite || Self.isLocal(host) }

    /// A URL to show: no password, ever.
    public var displayURL: String {
        if engine == .sqlite { return file ?? database }
        let who = user.isEmpty ? "" : "\(user)@"
        let at = port.map { "\(host):\($0)" } ?? host
        return "\(engine == .postgres ? "postgres" : "mysql")://\(who)\(at)/\(database)"
    }

    /// The SQLite file's location.
    public func fileURL(projectRoot: URL) -> URL? {
        guard let file else { return nil }
        return file.hasPrefix("/") ? URL(filePath: file) : projectRoot.appending(path: file)
    }

    /// Reads a DATABASE_URL-style string. Returns the connection and the password in it.
    public static func parse(url string: String, name: String? = nil, origin: Origin = .saved, note: String? = nil) -> DatabaseConnection? {
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let scheme = trimmed[..<colon].lowercased().split(separator: "+").first.map(String.init) ?? ""
        guard let engine = DatabaseEngine.schemes[scheme] else { return nil }
        if engine == .sqlite {
            var path = String(trimmed[trimmed.index(after: colon)...])
            while path.hasPrefix("//") { path.removeFirst() }
            // sqlite:///abs/path keeps one slash; sqlite:./rel or sqlite://rel is relative.
            if path.hasPrefix("/./") { path.removeFirst() }
            if path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty, !path.contains("${") else { return nil }
            return DatabaseConnection(name: name ?? (path as NSString).lastPathComponent, engine: .sqlite, database: (path as NSString).lastPathComponent,
                                      file: path, origin: origin, note: note)
        }
        guard let components = URLComponents(string: trimmed.replacingOccurrences(of: "\(trimmed[..<colon]):", with: "db:")),
              let host = components.host, !host.isEmpty else { return nil }
        let database = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !database.isEmpty, !host.contains("${"), !database.contains("${") else { return nil }
        let user = components.user?.removingPercentEncoding ?? ""
        let password = components.password?.removingPercentEncoding
        return DatabaseConnection(
            name: name ?? database, engine: engine, host: host, port: components.port, database: database, user: user,
            origin: origin, note: note, devPassword: password.flatMap { $0.contains("${") ? nil : $0 }
        )
    }
}
