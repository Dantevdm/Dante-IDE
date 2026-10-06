import Foundation

/// What the new-database wizard will do: a Docker Compose service (Postgres or MySQL) or
/// a SQLite file, the .env lines the app reads, and the connection Dante saves.
public struct NewDatabasePlan: Equatable, Sendable {
    public enum Host: String, CaseIterable, Sendable, Identifiable {
        case docker, file
        public var id: String { rawValue }
    }

    public var engine: DatabaseEngine
    public var name: String
    public var user: String
    public var password: String
    public var port: Int
    public var service: String
    public var image: String
    /// SQLite: where the file goes, relative to the project.
    public var file: String
    public var envKey: String

    public init(engine: DatabaseEngine, project: String, port: Int? = nil, password: String = NewDatabasePlan.makePassword()) {
        let slug = Self.slug(project)
        self.engine = engine
        self.name = slug
        self.user = engine == .mysql ? "app" : slug
        self.password = password
        self.port = port ?? engine.defaultPort ?? 0
        self.service = "db"
        self.image = engine.image ?? ""
        self.file = "data/\(slug).sqlite"
        self.envKey = "DATABASE_URL"
    }

    public var host: Host { engine == .sqlite ? .file : .docker }

    /// Picks an env variable that isn't taken, so a second database doesn't replace the
    /// first one's DATABASE_URL: SQLITE_DATABASE_URL, DB2_DATABASE_URL and so on.
    public mutating func avoidTakenKeys(_ taken: Set<String>) {
        guard taken.contains(envKey) else { return }
        let prefix = engine == .sqlite ? "SQLITE" : service.uppercased().replacingOccurrences(of: "-", with: "_")
        var key = "\(prefix)_DATABASE_URL"
        var index = 2
        while taken.contains(key) { key = "\(prefix)\(index)_DATABASE_URL"; index += 1 }
        envKey = key
    }

    /// Keys this plan would overwrite in an env file.
    public func replacedKeys(in text: String?) -> [String] {
        let existing = Set(EnvFile.parse(text ?? "").map(\.key))
        return envValues.map(\.key).filter(existing.contains)
    }
    public var volume: String { "\(service)-data" }

    /// A database or user name: lowercase letters, digits and underscores.
    public static func slug(_ text: String) -> String {
        var slug = text.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        while slug.contains("__") { slug = slug.replacingOccurrences(of: "__", with: "_") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if slug.isEmpty { slug = "app" }
        if slug.first!.isNumber { slug = "db_" + slug }
        return String(slug.prefix(40))
    }

    public static func makePassword(length: Int = 24) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(generator.next(upperBound: UInt(alphabet.count)))] })
    }

    /// The service block, without its indentation under `services:`.
    public var composeService: [String] {
        switch engine {
        case .postgres:
            [
                "\(service):",
                "  image: \(image)",
                "  restart: unless-stopped",
                "  environment:",
                "    POSTGRES_USER: \(user)",
                "    POSTGRES_PASSWORD: ${\(passwordKey)}",
                "    POSTGRES_DB: \(name)",
                "  ports:",
                "    - \"\(port):5432\"",
                "  volumes:",
                "    - \(volume):/var/lib/postgresql/data",
                "  healthcheck:",
                "    test: [\"CMD-SHELL\", \"pg_isready -U \(user) -d \(name)\"]",
                "    interval: 5s",
                "    timeout: 3s",
                "    retries: 10",
            ]
        case .mysql:
            [
                "\(service):",
                "  image: \(image)",
                "  restart: unless-stopped",
                "  environment:",
                "    MYSQL_DATABASE: \(name)",
                "    MYSQL_USER: \(user)",
                "    MYSQL_PASSWORD: ${\(passwordKey)}",
                "    MYSQL_ROOT_PASSWORD: ${\(passwordKey)}",
                "  ports:",
                "    - \"\(port):3306\"",
                "  volumes:",
                "    - \(volume):/var/lib/mysql",
                "  healthcheck:",
                "    test: [\"CMD\", \"mysqladmin\", \"ping\", \"-h\", \"127.0.0.1\", \"-u\", \"\(user)\", \"--password=${\(passwordKey)}\"]",
                "    interval: 5s",
                "    timeout: 3s",
                "    retries: 20",
            ]
        case .sqlite: []
        }
    }

    public var passwordKey: String { engine == .mysql ? "MYSQL_PASSWORD" : "POSTGRES_PASSWORD" }

    /// What goes in .env. The password lives there (git-ignored) and Compose reads it.
    public var envValues: [(key: String, value: String)] {
        switch engine {
        case .postgres: [(passwordKey, password), (envKey, "postgres://\(user):\(password)@localhost:\(port)/\(name)")]
        case .mysql: [(passwordKey, password), (envKey, "mysql://\(user):\(password)@localhost:\(port)/\(name)")]
        case .sqlite: [(envKey, "file:./\(file)")]
        }
    }

    /// The same keys with placeholder values, for .env.example, which is committed.
    public var exampleValues: [(key: String, value: String)] {
        envValues.map { key, value in
            (key, value.replacingOccurrences(of: password, with: key == passwordKey ? "change-me" : "${\(passwordKey)}"))
        }
    }

    public var connection: DatabaseConnection {
        switch engine {
        case .sqlite:
            DatabaseConnection(name: (file as NSString).lastPathComponent, engine: .sqlite, database: (file as NSString).lastPathComponent,
                               file: file, origin: .saved, note: "created by Dante")
        case .postgres, .mysql:
            DatabaseConnection(name: service, engine: engine, port: port, database: name, user: user, service: service,
                               readOnly: false, origin: .saved, note: "created by Dante")
        }
    }
}

/// Adds a service and a named volume to a compose file without reformatting it, so
/// comments and ordering survive.
public enum ComposeEditing {
    public static func adding(service lines: [String], volume: String?, to text: String?) -> String {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            var out = ["services:"] + lines.map { "  " + $0 }
            if let volume { out += ["", "volumes:", "  \(volume):"] }
            return out.joined(separator: "\n") + "\n"
        }
        var all = text.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        let indent = Self.indent(of: all) ?? "  "
        // Indent nested lines with the file's own unit.
        let reindented = lines.map { line -> String in
            let leading = line.prefix { $0 == " " }.count / 2
            return String(repeating: indent, count: leading + 1) + line.drop { $0 == " " }
        }
        if let servicesLine = all.firstIndex(where: { $0.hasPrefix("services:") }) {
            // After the last line that belongs to `services:`.
            var end = servicesLine + 1
            var lastContent = servicesLine
            while end < all.count {
                let line = all[end]
                if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#") { break }
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { lastContent = end }
                end += 1
            }
            all.insert(contentsOf: [""] + reindented, at: lastContent + 1)
        } else {
            all += ["", "services:"] + reindented
        }
        if let volume {
            if let volumesLine = all.firstIndex(where: { $0.hasPrefix("volumes:") }) {
                if all[volumesLine].trimmingCharacters(in: .whitespaces) != "volumes:" {
                    // `volumes: {}` and the like: replace with a block.
                    all[volumesLine] = "volumes:"
                }
                all.insert("\(indent)\(volume):", at: volumesLine + 1)
            } else {
                all += ["", "volumes:", "\(indent)\(volume):"]
            }
        }
        return all.joined(separator: "\n") + "\n"
    }

    /// The indentation of the first service, so added lines match.
    static func indent(of lines: [String]) -> String? {
        guard let services = lines.firstIndex(where: { $0.hasPrefix("services:") }) else { return nil }
        for line in lines[(services + 1)...] where !line.trimmingCharacters(in: .whitespaces).isEmpty && !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            return leading.isEmpty ? nil : String(leading)
        }
        return nil
    }

    /// The service names already taken, so the wizard can pick a free one.
    public static func freeServiceName(_ preferred: String, taken: [String]) -> String {
        guard taken.contains(preferred) else { return preferred }
        var index = 2
        while taken.contains("\(preferred)\(index)") { index += 1 }
        return "\(preferred)\(index)"
    }
}

/// Lines added to .gitignore when missing.
public enum GitIgnore {
    public static func ensuring(_ entries: [String], in text: String?) -> String? {
        let existing = Set((text ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = entries.filter { !existing.contains($0) && !existing.contains("/" + $0) }
        guard !missing.isEmpty else { return nil }
        var out = text ?? ""
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        return out + missing.joined(separator: "\n") + "\n"
    }
}
