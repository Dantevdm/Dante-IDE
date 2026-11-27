import Foundation

/// What a project's files say about its data: which database engines the code uses, the
/// databases it can connect to (compose services, DATABASE_URLs, SQLite files), other
/// stores, and where migrations live. Pure, so it's cheap to run on every reload.
public struct DataProfile: Equatable, Sendable {
    public struct Signal: Equatable, Sendable, Identifiable {
        public var engine: DatabaseEngine?
        /// "pg in package.json", "Prisma (postgresql)".
        public var label: String
        public var path: String
        public var id: String { "\(path):\(label)" }
    }

    public var signals: [Signal]
    public var connections: [DatabaseConnection]
    /// Stores Dante can't browse yet but should mention: Redis, MongoDB…
    public var otherStores: [String]
    /// Migration folders and how many files each holds.
    public var migrations: [(path: String, count: Int)]
    public var orms: [String]

    public static func == (a: DataProfile, b: DataProfile) -> Bool {
        a.signals == b.signals && a.connections == b.connections && a.otherStores == b.otherStores
            && a.migrations.map(\.path) == b.migrations.map(\.path) && a.migrations.map(\.count) == b.migrations.map(\.count) && a.orms == b.orms
    }

    /// Engines the project uses, most evidence first.
    public var engines: [DatabaseEngine] {
        var counts: [DatabaseEngine: Int] = [:]
        for signal in signals { if let engine = signal.engine { counts[engine, default: 0] += 1 } }
        for connection in connections { counts[connection.engine, default: 0] += 2 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }.map(\.key)
    }

    public var suggestedEngine: DatabaseEngine? { engines.first }
    public var isEmpty: Bool { signals.isEmpty && connections.isEmpty && otherStores.isEmpty }

    /// One line for the empty state: "Uses PostgreSQL (Prisma, pg in package.json)".
    public var headline: String? {
        guard let engine = suggestedEngine else { return nil }
        let reasons = signals.filter { $0.engine == engine }.map(\.label).prefix(3)
        return "Uses \(engine.name)" + (reasons.isEmpty ? "" : " (\(reasons.joined(separator: ", ")))")
    }
}

public enum DataDetector {
    /// Where a database file sits, so two of the same name can be told apart.
    static func folderNote(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "file at the project root" : "in \(folder)/"
    }

    /// A file kept by a tool rather than the app: inside a dot folder (`.angular/cache`,
    /// `.next`, `.dante`) or a cache or temp folder. Angular's build cache, for one, is a SQLite
    /// file named `angular-compiler.db`.
    static func isToolFile(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { folder in
            folder.hasPrefix(".") || ["cache", "caches", ".cache", "tmp", "temp", "coverage", "out"].contains(folder.lowercased())
        }
    }

    static let ignoredFolders = ["node_modules/", ".git/", "build/", "dist/", ".build/", "vendor/", "target/", "Pods/", ".venv/", "venv/"]

    /// `nested` are compose files below the top, by the folder each sits in.
    public static func detect(paths: [String], compose: ComposeFile? = nil, nested: [(folder: String, file: ComposeFile)] = [],
                              read: (String) -> String? = { _ in nil }) -> DataProfile {
        var signals: [DataProfile.Signal] = []
        var connections: [DatabaseConnection] = []
        var other: [String] = []
        var orms: [String] = []
        func signal(_ engine: DatabaseEngine?, _ label: String, _ path: String) {
            if !signals.contains(where: { $0.engine == engine && $0.label == label }) { signals.append(.init(engine: engine, label: label, path: path)) }
        }
        func store(_ name: String) { if !other.contains(name) { other.append(name) } }
        func orm(_ name: String) { if !orms.contains(name) { orms.append(name) } }
        func addConnection(_ connection: DatabaseConnection, inside: Bool = false) {
            var connection = connection
            connection.insideDocker = inside
            if let index = connections.firstIndex(where: { $0.id == connection.id }) {
                // Keep the first, but fill in what a later source knows.
                if connections[index].service == nil { connections[index].service = connection.service }
                if connections[index].devPassword == nil { connections[index].devPassword = connection.devPassword }
                if connections[index].composeFolder == nil { connections[index].composeFolder = connection.composeFolder }
                if inside { connections[index].insideDocker = true }
            } else {
                connections.append(connection)
            }
        }
        let files = paths.filter { path in !ignoredFolders.contains { path.hasPrefix($0) || path.contains("/" + $0) } }
        let env = files.contains(".env") ? EnvFile.values(read(".env") ?? "") : [:]

        // Docker Compose services: the top's, then each folder's own.
        let composes: [(folder: String?, file: ComposeFile)] = (compose.map { [(nil, $0)] } ?? []) + nested.map { ($0.folder, $0.file) }
        for (folder, file) in composes {
          let env = folder.map { folder in files.contains(folder + "/.env") ? EnvFile.values(read(folder + "/.env") ?? "") : [:] } ?? env
          // A database that another service reaches by JDBC URL (Flyway's) names the database.
          let jdbc = file.services.flatMap(\.environment.values).compactMap { SQLServer.connection(jdbc: $0) }.first
          for service in file.services {
            let image = (service.image ?? "").lowercased()
            let name = image.split(separator: "/").last.map(String.init) ?? image
            let composePath = folder.map { "\($0)/\(file.url.lastPathComponent)" } ?? file.url.lastPathComponent
            func value(_ key: String) -> String? { service.environment[key].map { EnvFile.interpolate($0, env: env) }.flatMap { $0.isEmpty ? nil : $0 } }
            func add(_ connection: DatabaseConnection, inside: Bool) {
                var connection = connection
                connection.composeFolder = folder
                addConnection(connection, inside: inside)
            }
            if name.hasPrefix("postgres") || name.hasPrefix("postgis") || name.hasPrefix("timescale") || image.contains("pgvector") || name.hasPrefix("supabase/postgres") {
                signal(.postgres, "\(service.name) service in \(composePath)", composePath)
                let user = value("POSTGRES_USER") ?? "postgres"
                add(DatabaseConnection(
                    name: service.name, engine: .postgres, port: hostPort(service.ports, container: 5432) ?? 5432,
                    database: value("POSTGRES_DB") ?? user, user: user, service: service.name, readOnly: false,
                    origin: .detected, note: "\(composePath) service", devPassword: value("POSTGRES_PASSWORD")
                ), inside: hostPort(service.ports, container: 5432) == nil)
            } else if name.hasPrefix("mysql") || name.hasPrefix("mariadb") || name.hasPrefix("percona") {
                signal(.mysql, "\(service.name) service in \(composePath)", composePath)
                let user = value("MYSQL_USER") ?? value("MARIADB_USER") ?? "root"
                let password = user == "root" ? (value("MYSQL_ROOT_PASSWORD") ?? value("MARIADB_ROOT_PASSWORD")) : (value("MYSQL_PASSWORD") ?? value("MARIADB_PASSWORD"))
                add(DatabaseConnection(
                    name: service.name, engine: .mysql, port: hostPort(service.ports, container: 3306) ?? 3306,
                    database: value("MYSQL_DATABASE") ?? value("MARIADB_DATABASE") ?? "mysql", user: user, service: service.name, readOnly: false,
                    origin: .detected, note: "\(composePath) service", devPassword: password
                ), inside: hostPort(service.ports, container: 3306) == nil)
            } else if SQLServer.isServerImage(image) {
                signal(.sqlserver, "\(service.name) service in \(composePath)", composePath)
                let port = hostPort(service.ports, container: 1433)
                add(DatabaseConnection(
                    name: service.name, engine: .sqlserver, port: port ?? 1433,
                    database: jdbc?.database ?? "master", user: "sa", service: service.name, readOnly: false,
                    origin: .detected, note: "\(composePath) service", devPassword: value("MSSQL_SA_PASSWORD") ?? value("SA_PASSWORD")
                ), inside: port == nil)
            } else if name.hasPrefix("redis") || name.hasPrefix("valkey") || name.hasPrefix("keydb") {
                store("Redis")
            } else if name.hasPrefix("mongo") {
                store("MongoDB")
            } else if name.hasPrefix("elasticsearch") || name.hasPrefix("opensearch") {
                store(name.hasPrefix("open") ? "OpenSearch" : "Elasticsearch")
            } else if name.hasPrefix("rabbitmq") {
                store("RabbitMQ")
            } else if name.contains("kafka") || name.contains("redpanda") {
                store("Kafka")
            }
          }
        }

        // DATABASE_URLs in env files. Example files hold dev settings; .env is this Mac's own.
        for path in files where isEnvFile(path) {
            for (key, raw) in EnvFile.parse(read(path) ?? "") where key.hasSuffix("URL") || key.hasSuffix("DSN") || key.hasSuffix("URI") {
                let value = EnvFile.interpolate(raw, env: env)
                guard var connection = DatabaseConnection.parse(url: value, origin: .detected, note: "\(key) in \(path)") else {
                    if value.hasPrefix("redis") { store("Redis") } else if value.hasPrefix("mongodb") { store("MongoDB") }
                    continue
                }
                if connection.name == connection.database, key != "DATABASE_URL" { connection.name = "\(connection.database) (\(key.lowercased()))" }
                // A compose service on the same port is the same database.
                if let match = connections.first(where: { $0.engine == connection.engine && $0.port == connection.port && DatabaseConnection.isLocal($0.host) && connection.isLocal }) {
                    connection.service = match.service
                }
                signal(connection.engine, "\(key) in \(path)", path)
                addConnection(connection)
            }
        }

        // .NET settings: ConnectionStrings in appsettings.json and its environment copies.
        for path in files where SQLServer.isAppSettings(path) {
            for var connection in SQLServer.connections(appSettings: read(path) ?? "", path: path) {
                if let match = connections.first(where: { $0.engine == connection.engine && $0.port == connection.port && DatabaseConnection.isLocal($0.host) && connection.isLocal }) {
                    connection.service = match.service
                    connection.composeFolder = match.composeFolder
                    if connection.devPassword == nil { connection.devPassword = match.devPassword }
                }
                signal(connection.engine, "ConnectionStrings in \((path as NSString).lastPathComponent)", path)
                addConnection(connection)
            }
        }

        // SQLite files in the repo.
        for path in files {
            let ext = (path as NSString).pathExtension.lowercased()
            guard ["sqlite", "sqlite3", "db", "db3"].contains(ext), !Self.isToolFile(path) else { continue }
            signal(.sqlite, "\((path as NSString).lastPathComponent)", path)
            addConnection(DatabaseConnection(name: (path as NSString).lastPathComponent, engine: .sqlite, database: (path as NSString).lastPathComponent,
                                   file: path, origin: .detected, note: Self.folderNote(path)))
        }

        // Libraries and ORMs in the build files.
        let libraries: [(file: (String) -> Bool, needles: [(String, DatabaseEngine?, String)])] = [
            ({ $0.hasSuffix("package.json") }, [
                ("\"pg\"", .postgres, "pg"), ("\"postgres\"", .postgres, "postgres.js"), ("\"@neondatabase/serverless\"", .postgres, "Neon"),
                ("\"@vercel/postgres\"", .postgres, "Vercel Postgres"), ("\"mysql2\"", .mysql, "mysql2"), ("\"mysql\"", .mysql, "mysql"),
                ("\"mssql\"", .sqlserver, "mssql"), ("\"tedious\"", .sqlserver, "tedious"),
                ("\"better-sqlite3\"", .sqlite, "better-sqlite3"), ("\"sqlite3\"", .sqlite, "sqlite3"), ("\"@libsql/client\"", .sqlite, "libSQL"),
            ]),
            ({ $0.hasSuffix("requirements.txt") || $0.hasSuffix("pyproject.toml") || $0.hasSuffix("Pipfile") || $0.hasSuffix("setup.py") }, [
                ("psycopg", .postgres, "psycopg"), ("asyncpg", .postgres, "asyncpg"), ("pymysql", .mysql, "PyMySQL"),
                ("mysqlclient", .mysql, "mysqlclient"), ("aiomysql", .mysql, "aiomysql"), ("aiosqlite", .sqlite, "aiosqlite"),
                ("pyodbc", .sqlserver, "pyodbc"), ("pymssql", .sqlserver, "pymssql"),
            ]),
            ({ $0.hasSuffix("go.mod") }, [
                ("jackc/pgx", .postgres, "pgx"), ("lib/pq", .postgres, "lib/pq"), ("go-sql-driver/mysql", .mysql, "go-sql-driver"),
                ("mattn/go-sqlite3", .sqlite, "go-sqlite3"), ("modernc.org/sqlite", .sqlite, "modernc sqlite"),
                ("go-mssqldb", .sqlserver, "go-mssqldb"),
            ]),
            ({ $0.hasSuffix("Cargo.toml") }, [
                ("tokio-postgres", .postgres, "tokio-postgres"), ("rusqlite", .sqlite, "rusqlite"), ("mysql_async", .mysql, "mysql_async"),
            ]),
            ({ ($0 as NSString).lastPathComponent == "Gemfile" }, [
                ("'pg'", .postgres, "pg gem"), ("\"pg\"", .postgres, "pg gem"), ("'mysql2'", .mysql, "mysql2 gem"), ("'sqlite3'", .sqlite, "sqlite3 gem"),
            ]),
            ({ $0.hasSuffix("Package.swift") }, [
                ("postgres-nio", .postgres, "PostgresNIO"), ("postgres-kit", .postgres, "PostgresKit"), ("mysql-nio", .mysql, "MySQLNIO"),
                ("GRDB", .sqlite, "GRDB"), ("SQLite.swift", .sqlite, "SQLite.swift"),
            ]),
            ({ $0.hasSuffix("pom.xml") || $0.hasSuffix("build.gradle") || $0.hasSuffix("build.gradle.kts") }, [
                ("org.postgresql", .postgres, "PostgreSQL JDBC"), ("mysql-connector", .mysql, "MySQL Connector/J"), ("sqlite-jdbc", .sqlite, "sqlite-jdbc"),
                ("mssql-jdbc", .sqlserver, "Microsoft JDBC"),
            ]),
            ({ $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") || $0.hasSuffix("Directory.Packages.props") }, [
                ("Microsoft.Data.SqlClient", .sqlserver, "Microsoft.Data.SqlClient"), ("System.Data.SqlClient", .sqlserver, "System.Data.SqlClient"),
                ("EntityFrameworkCore.SqlServer", .sqlserver, "EF Core SQL Server"), ("Npgsql", .postgres, "Npgsql"),
                ("MySqlConnector", .mysql, "MySqlConnector"), ("Pomelo.EntityFrameworkCore.MySql", .mysql, "Pomelo MySQL"),
                ("Microsoft.Data.Sqlite", .sqlite, "Microsoft.Data.Sqlite"),
            ]),
        ]
        let ormNeedles: [(String, String)] = [
            ("\"prisma\"", "Prisma"), ("\"@prisma/client\"", "Prisma"), ("\"drizzle-orm\"", "Drizzle"), ("\"typeorm\"", "TypeORM"),
            ("\"knex\"", "Knex"), ("\"sequelize\"", "Sequelize"), ("\"kysely\"", "Kysely"), ("\"mongoose\"", "Mongoose"),
            ("sqlalchemy", "SQLAlchemy"), ("alembic", "Alembic"), ("django", "Django ORM"), ("tortoise-orm", "Tortoise"),
            ("gorm.io", "GORM"), ("sqlx", "SQLx"), ("diesel", "Diesel"), ("activerecord", "Active Record"), ("'rails'", "Active Record"),
            ("fluent", "Fluent"), ("hibernate", "Hibernate"), ("microsoft.entityframeworkcore", "Entity Framework Core"), ("\"dapper\"", "Dapper"), ("spring-boot-starter-data-jpa", "JPA"), ("flyway", "Flyway"), ("liquibase", "Liquibase"),
        ]
        for path in files where !path.contains("/node_modules/") {
            let name = (path as NSString).lastPathComponent
            guard ["package.json", "requirements.txt", "pyproject.toml", "Pipfile", "setup.py", "go.mod", "Cargo.toml", "Gemfile", "Package.swift", "pom.xml", "build.gradle", "build.gradle.kts", "Directory.Packages.props"].contains(name)
                  || name.hasSuffix(".csproj") || name.hasSuffix(".fsproj")
                  || name.hasPrefix("requirements") && name.hasSuffix(".txt"),
                  let text = read(path) else { continue }
            // A Go module's indirect requirements are its dependencies' choices, not its own.
            let lower = (name == "go.mod" ? text.split(separator: "\n").filter { !$0.contains("// indirect") }.joined(separator: "\n") : text).lowercased()
            for group in libraries where group.file(path) || (name.hasPrefix("requirements") && group.file("requirements.txt")) {
                for (needle, engine, label) in group.needles where lower.contains(needle.lowercased()) {
                    signal(engine, "\(label) in \(name)", path)
                }
            }
            for (needle, label) in ormNeedles where lower.contains(needle.lowercased()) { orm(label) }
            if lower.contains("\"redis\"") || lower.contains("\"ioredis\"") || lower.contains("redis-py") || lower.contains("go-redis") { store("Redis") }
            if lower.contains("\"mongodb\"") || lower.contains("pymongo") || lower.contains("mongo-driver") { store("MongoDB") }
            // SQLx and Diesel name the engine in their features.
            if name == "Cargo.toml", lower.contains("sqlx") || lower.contains("diesel") {
                if lower.contains("\"postgres\"") { signal(.postgres, "SQLx/Diesel postgres feature", path) }
                if lower.contains("\"mysql\"") { signal(.mysql, "SQLx/Diesel mysql feature", path) }
                if lower.contains("\"sqlite\"") { signal(.sqlite, "SQLx/Diesel sqlite feature", path) }
            }
        }

        // Prisma, Rails and Django name the engine in their config.
        for path in files {
            let name = (path as NSString).lastPathComponent
            if name == "schema.prisma", let text = read(path) {
                orm("Prisma")
                if let provider = firstMatch(#"provider\s*=\s*"(postgresql|postgres|mysql|sqlite|cockroachdb|mongodb)""#, in: text) {
                    let engine: DatabaseEngine? = ["postgresql", "postgres", "cockroachdb"].contains(provider) ? .postgres : provider == "mysql" ? .mysql : provider == "sqlite" ? .sqlite : nil
                    if provider == "mongodb" { store("MongoDB") }
                    signal(engine, "Prisma (\(provider))", path)
                    if engine == .sqlite, let file = firstMatch(#"url\s*=\s*"file:([^"]+)""#, in: text) {
                        let folder = (path as NSString).deletingLastPathComponent
                        let relative = file.hasPrefix("./") ? String(file.dropFirst(2)) : file
                        let full = folder.isEmpty ? relative : "\(folder)/\(relative)"
                        addConnection(DatabaseConnection(name: (relative as NSString).lastPathComponent, engine: .sqlite, database: relative,
                                               file: full, origin: .detected, note: "Prisma datasource"))
                    }
                }
            } else if path.hasSuffix("config/database.yml"), let text = read(path) {
                orm("Active Record")
                if let adapter = firstMatch(#"adapter:\s*(\w+)"#, in: text) {
                    let engine: DatabaseEngine? = adapter.hasPrefix("postg") ? .postgres : adapter.hasPrefix("mysql") || adapter == "trilogy" ? .mysql : adapter.hasPrefix("sqlite") ? .sqlite : nil
                    signal(engine, "Rails (\(adapter))", path)
                }
            } else if name == "settings.py", let text = read(path), text.contains("DATABASES") {
                orm("Django ORM")
                if text.contains("backends.postgresql") { signal(.postgres, "Django settings", path) }
                if text.contains("backends.mysql") { signal(.mysql, "Django settings", path) }
                if text.contains("backends.sqlite3") { signal(.sqlite, "Django settings", path) }
            }
        }

        // Migrations.
        var migrationFolders: [String: Int] = [:]
        let migrationRoots = ["prisma/migrations/", "db/migrate/", "migrations/", "alembic/versions/", "supabase/migrations/", "drizzle/",
                              "db/migrations/", "database/migrations/", "src/main/resources/db/migration/", "sql/migrations/",
                              "flyway/sql/", "Migrations/"]
        for path in files {
            for root in migrationRoots where path.hasPrefix(root) || path.contains("/" + root) {
                let range = path.range(of: root)!
                let folder = String(path[..<range.upperBound].dropLast())
                migrationFolders[folder, default: 0] += 1
                break
            }
        }
        if signals.isEmpty, connections.isEmpty, files.contains(where: { $0.hasSuffix(".sql") }) {
            signal(nil, "SQL files", files.first { $0.hasSuffix(".sql") }!)
        }

        return DataProfile(
            signals: signals, connections: connections, otherStores: other,
            migrations: migrationFolders.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, orms: orms
        )
    }

    static func isEnvFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == ".env" || name.hasPrefix(".env.") && !name.hasSuffix(".swp")
    }

    /// The host port published for a container port: "5433:5432" → 5433.
    static func hostPort(_ ports: [String], container: Int) -> Int? {
        for port in ports {
            let parts = port.split(separator: "/").first.map { $0.split(separator: ":").map(String.init) } ?? []
            guard let last = parts.last, Int(last) == container else { continue }
            if parts.count >= 2, let host = Int(parts[parts.count - 2]) { return host }
            if parts.count == 1 { return nil }
        }
        return nil
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// `.env` files: reading them, interpolating `${VAR:-default}`, and setting keys while
/// keeping everything else as it was.
public enum EnvFile {
    public static func parse(_ text: String) -> [(key: String, value: String)] {
        text.components(separatedBy: .newlines).compactMap { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            return key.isEmpty ? nil : (key, value)
        }
    }

    /// The values by key; a later line wins, as it does for Compose.
    public static func values(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        for (key, value) in parse(text) { map[key] = value }
        return map
    }

    /// Fills in `${VAR}`, `${VAR:-default}`, `${VAR-default}`, `${VAR:?error}`, `${VAR?error}`,
    /// `${VAR:+other}` and `$VAR` the way Compose does.
    public static func interpolate(_ value: String, env: [String: String]) -> String {
        guard value.contains("$") else { return value }
        var result = value
        for match in interpolation.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let whole = Range(match.range, in: result) else { continue }
            let name = Range(match.range(at: 1), in: value).map { String(value[$0]) } ?? Range(match.range(at: 4), in: value).map { String(value[$0]) } ?? ""
            let operation = Range(match.range(at: 2), in: value).map { String(value[$0]) } ?? ""
            let word = Range(match.range(at: 3), in: value).map { String(value[$0]) } ?? ""
            let set = env[name]
            // A colon makes an empty value count as unset.
            let present = operation.hasPrefix(":") ? set.map { !$0.isEmpty } ?? false : set != nil
            let replacement: String? = switch operation.last {
            case "-": present ? set : word
            case "+": present ? word : ""
            // `?` is an error when unset: leave it, so callers can tell it's unresolved.
            default: present ? set : nil
            }
            if let replacement { result.replaceSubrange(whole, with: replacement) }
        }
        return result
    }

    static let interpolation = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-?+])([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)

    /// Sets keys, replacing existing lines in place and appending the rest under a comment.
    public static func setting(_ values: [(key: String, value: String)], in text: String?, comment: String? = nil) -> String {
        var lines = (text ?? "").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var appended: [String] = []
        for (key, value) in values {
            let line = "\(key)=\(value)"
            if let index = lines.firstIndex(where: { $0.hasPrefix("\(key)=") || $0.hasPrefix("export \(key)=") }) {
                lines[index] = line
            } else {
                appended.append(line)
            }
        }
        if !appended.isEmpty {
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            if let comment { lines.append("# \(comment)") }
            lines += appended
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
