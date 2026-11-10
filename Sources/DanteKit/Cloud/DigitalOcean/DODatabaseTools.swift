import Foundation
import os

/// Reaching an app's database from this Mac for a backup, a restore or a fresh start. App
/// Platform only tells the app itself how to connect (variables bound to `${db.…}`), so Dante
/// asks the running component for them through its console, uses them for one command, and
/// never shows or keeps them.
public enum DODatabaseAccess {
    /// What to read inside the app: a component and, per variable, the database field it holds.
    public struct Plan: Equatable, Sendable {
        public var component: String
        public var reads: [String: String]
    }

    /// The first service or worker with variables bound to `database` that are enough to connect:
    /// `DATABASE_URL`, or host, user, password and database name.
    public static func plan(spec: DOAppSpec, database: String) -> Plan? {
        let shared = bound(spec.envs ?? [], to: database)
        for (kind, component) in spec.components where kind == .service || kind == .worker {
            let reads = shared.merging(bound(component.envs ?? [], to: database)) { _, own in own }
            if reads.values.contains("DATABASE_URL") || Set(["HOSTNAME", "USERNAME", "PASSWORD", "DATABASE"]).isSubset(of: Set(reads.values)) {
                return Plan(component: component.name, reads: reads)
            }
        }
        return nil
    }

    static func bound(_ envs: [DOAppSpec.Env], to database: String) -> [String: String] {
        var reads: [String: String] = [:]
        for env in envs {
            guard let value = env.value?.trimmingCharacters(in: .whitespaces), value.hasPrefix("${\(database)."), value.hasSuffix("}") else { continue }
            let field = value.dropFirst(database.count + 3).dropLast()
            if ["DATABASE_URL", "HOSTNAME", "PORT", "USERNAME", "PASSWORD", "DATABASE"].contains(String(field)) { reads[env.key] = String(field) }
        }
        return reads
    }

    static let begin = "_DANTE_B_", end = "_DANTE_E_"

    /// The line typed into the component's shell. The markers are written as octal escapes so
    /// the shell's echo of the command can't be mistaken for its output.
    public static func script(for plan: Plan) -> String {
        func octal(_ text: String) -> String { text.utf8.map { "\\" + String($0, radix: 8) }.joined() }
        let lines = plan.reads.keys.sorted().map { key in "printf '%s=%s\\n' \(key) \"$\(key)\"" }
        return (["stty -echo 2>/dev/null", "printf '\\n\(octal(begin))\\n'"] + lines + ["printf '\(octal(end))\\n'", "exit"]).joined(separator: "; ")
    }

    /// The values between the markers, by variable.
    public static func values(in output: String) -> [String: String]? {
        let lines = output.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n").map(strippingEscapes)
        guard let start = lines.firstIndex(of: begin), let stop = lines[start...].firstIndex(of: end) else { return nil }
        var values: [String: String] = [:]
        for line in lines[(start + 1)..<stop] {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return values
    }

    static func strippingEscapes(_ line: String) -> String {
        line.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The connection from what the component said.
    public static func connection(_ values: [String: String], plan: Plan) -> PGConnection? {
        var field: [String: String] = [:]
        for (key, name) in plan.reads { if let value = values[key], !value.isEmpty { field[name] = value } }
        if let url = field["DATABASE_URL"], let connection = PGConnection(url: url) { return connection }
        guard let host = field["HOSTNAME"], let user = field["USERNAME"], let password = field["PASSWORD"], let name = field["DATABASE"] else { return nil }
        return PGConnection(host: host, port: Int(field["PORT"] ?? "") ?? 25060, user: user, password: password, database: name)
    }
}

/// A Postgres connection used for one command: the password goes in `PGPASSWORD`, never on
/// the command line, and `description` leaves it out.
public struct PGConnection: Equatable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public var user: String
    public var password: String
    public var database: String

    public init(host: String, port: Int, user: String, password: String, database: String) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
    }

    public init?(url text: String) {
        guard let url = URLComponents(string: text), ["postgres", "postgresql"].contains(url.scheme ?? ""), let host = url.host, let user = url.user else { return nil }
        self.init(host: host, port: url.port ?? 5432, user: user.removingPercentEncoding ?? user,
                  password: (url.password ?? "").removingPercentEncoding ?? "", database: String(url.path.dropFirst()))
    }

    public var description: String { "\(user)@\(host):\(port)/\(database)" }

    /// Arguments naming the database; the password goes in `environment`.
    public var arguments: [String] { ["--host=\(host)", "--port=\(port)", "--username=\(user)", "--dbname=\(database)"] }
    public var environment: [String: String] { ["PGPASSWORD": password, "PGSSLMODE": "require", "PGCONNECT_TIMEOUT": "15"] }
}

/// pg_dump, pg_restore and psql on this Mac, and what Dante runs with them.
public enum PGTools {
    /// Whether the database's port takes a connection from this Mac at all. A cloud
    /// database's firewall drops packets rather than refusing them, so without this every tool
    /// waits out its own timeout and reports "timeout expired".
    public static func answers(_ connection: PGConnection, timeout: Int = 6) async -> Bool {
        await Shell.run(["/usr/bin/nc", "-z", "-G", String(timeout), "-w", String(timeout), connection.host, String(connection.port)],
                        in: FileManager.default.temporaryDirectory, timeout: .seconds(timeout + 4), withoutMise: true).succeeded
    }

    /// Where the tools usually are: PATH first, then Homebrew's keg-only libpq and Postgres.app.
    public static let folders = ["/opt/homebrew/opt/libpq/bin", "/usr/local/opt/libpq/bin", "/opt/homebrew/bin", "/usr/local/bin",
                                 "/Applications/Postgres.app/Contents/Versions/latest/bin"]

    public static func locate(_ tool: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        let fromPath = (path ?? "").split(separator: ":").map(String.init)
        for folder in fromPath + folders {
            let file = (folder as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: file) { return file }
        }
        return nil
    }

    /// Typed into the terminal when a tool is missing; never run by Dante.
    public static let installCommand = "brew install libpq"

    /// Backups live on this Mac, outside every repository: Application Support/Dante/backups/<app>.
    public static func backupFolder(app: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "Dante/backups/\(app)", directoryHint: .isDirectory)
    }

    public static func backupName(database: String, date: Date, note: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(database)-\(formatter.string(from: date))\(note.map { "-" + $0 } ?? "").dump"
    }

    /// A backup file's date, from its name.
    public static func date(ofBackup name: String) -> Date? {
        guard let range = name.range(of: #"\d{8}-\d{6}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: String(name[range]))
    }

    /// Custom format, without owners or grants, so it restores into a database whose user differs.
    public static func dumpArguments(_ connection: PGConnection, to file: URL) -> [String] {
        connection.arguments + ["--format=custom", "--no-owner", "--no-privileges", "--file=\(file.path)"]
    }

    /// Replaces what the backup holds, in one transaction so a failure leaves the database as it was.
    public static func restoreArguments(_ connection: PGConnection, from file: URL) -> [String] {
        connection.arguments + ["--clean", "--if-exists", "--no-owner", "--no-privileges", "--single-transaction", "--exit-on-error", file.path]
    }

    /// Drops everything the app's user owns in the public schema, leaving the schema and its
    /// grants (a dev database's user can't make them again), so the next deploy's migrations
    /// start from nothing.
    public static let freshSQL = """
    DO $$
    DECLARE r record;
    BEGIN
      FOR r IN SELECT c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = 'public' AND pg_get_userbyid(c.relowner) = current_user AND c.relkind IN ('v', 'm') LOOP
        EXECUTE format(CASE r.relkind WHEN 'm' THEN 'DROP MATERIALIZED VIEW IF EXISTS public.%I CASCADE' ELSE 'DROP VIEW IF EXISTS public.%I CASCADE' END, r.relname);
      END LOOP;
      FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tableowner = current_user LOOP
        EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', r.tablename);
      END LOOP;
      FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname = 'public' AND sequenceowner = current_user LOOP
        EXECUTE format('DROP SEQUENCE IF EXISTS public.%I CASCADE', r.sequencename);
      END LOOP;
      FOR r IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'public' AND pg_get_userbyid(p.proowner) = current_user LOOP
        EXECUTE format('DROP ROUTINE IF EXISTS %s CASCADE', r.signature);
      END LOOP;
      FOR r IN SELECT t.typname FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
               WHERE n.nspname = 'public' AND pg_get_userbyid(t.typowner) = current_user AND t.typtype IN ('e', 'd', 'c')
                 AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.reltype = t.oid AND c.relkind <> 'c') LOOP
        EXECUTE format('DROP TYPE IF EXISTS public.%I CASCADE', r.typname);
      END LOOP;
    END $$;
    """

    public static func freshArguments(_ connection: PGConnection) -> [String] {
        connection.arguments + ["--no-psqlrc", "--set=ON_ERROR_STOP=1", "--command=\(freshSQL)"]
    }

    /// pg_dump's complaint about a server newer than itself, in words.
    public static func explain(_ message: String) -> String {
        if message.contains("server version mismatch") || message.contains("aborting because of server version mismatch") {
            return "This Mac’s pg_dump is older than the database. Update it (\(installCommand), or upgrade Postgres.app) and try again."
        }
        if message.contains("timeout expired") || message.contains("Connection refused") || message.contains("no pg_hba.conf entry") {
            return "This Mac can’t reach the database. A managed cluster only lets in its trusted sources; add this Mac’s address there for the backup, then take it out."
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A managed cluster's daily backup.
public struct DODatabaseBackup: Decodable, Equatable, Sendable, Identifiable {
    public var createdAt: String
    public var sizeGigabytes: Double?
    public var id: String { createdAt }

    public init(createdAt: String, sizeGigabytes: Double?) {
        self.createdAt = createdAt
        self.sizeGigabytes = sizeGigabytes
    }

    public var date: Date? { DOJSON.date(createdAt) }
}

/// Managed database sizes and their list prices (DigitalOcean doesn't give prices through the
/// API): a node a month, before standby nodes, which cost the same here as a rough guide.
public enum DODatabaseSizes {
    public static let pg: [(slug: String, title: String, monthly: Double)] = [
        ("db-s-1vcpu-1gb", "1 vCPU · 1 GB", 15), ("db-s-1vcpu-2gb", "1 vCPU · 2 GB", 30), ("db-s-2vcpu-4gb", "2 vCPU · 4 GB", 60),
        ("db-s-4vcpu-8gb", "4 vCPU · 8 GB", 120), ("db-s-6vcpu-16gb", "6 vCPU · 16 GB", 240), ("db-s-8vcpu-32gb", "8 vCPU · 32 GB", 480),
        ("db-s-16vcpu-64gb", "16 vCPU · 64 GB", 960),
    ]

    public static func title(_ slug: String?) -> String? { pg.first { $0.slug == slug }?.title ?? slug }

    public static func monthly(_ slug: String?, nodes: Int = 1) -> Double? {
        pg.first { $0.slug == slug }.map { $0.monthly * Double(max(1, nodes)) }
    }

    /// A restored cluster's name: the original's with the backup's day, cut to DigitalOcean's limit.
    public static func restoredName(_ name: String, backup: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMdd-HHmm"
        return String((name + "-restored-" + formatter.string(from: backup)).prefix(63))
    }
}

/// Runs one line in a running component's shell through DigitalOcean's console and returns what
/// it printed, for reading the database's variables. Fails when the image has no shell.
public enum DOConsoleExec {
    public struct Failure: Error, Equatable {
        public var message: String
        public init(message: String) { self.message = message }
    }

    public static func run(_ url: URL, line: String, timeout: Duration = .seconds(25)) async throws -> String {
        guard DOConsole.isAllowed(url) else { throw Failure(message: "Not a DigitalOcean console address.") }
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let sent = OSAllocatedUnfairLock(initialState: false)
        // Typed once the shell has printed its prompt, or after two seconds of quiet.
        @Sendable func send() async throws {
            guard sent.withLock({ was in defer { was = true }; return !was }) else { return }
            try await Task.sleep(for: .milliseconds(400))
            try await task.send(.string(DOConsole.resize(width: 200, height: 50)))
            try await task.send(.string(DOConsole.stdin(line + "\r")))
        }
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                var output = ""
                while !output.contains(DODatabaseAccess.end + "\n") && !output.contains(DODatabaseAccess.end + "\r") {
                    let message: URLSessionWebSocketTask.Message
                    do { message = try await task.receive() } catch {
                        if output.contains(DODatabaseAccess.end) { break }
                        throw Failure(message: sent.withLock { $0 } ? "The console closed before the command finished." : "The console closed straight away; the image may have no shell.")
                    }
                    let text: String = switch message {
                    case .string(let string): string
                    case .data(let data): String(decoding: data, as: UTF8.self)
                    @unknown default: ""
                    }
                    if let chunk = DOConsole.output(text) { output += chunk }
                    try await send()
                }
                return output
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                try await send()
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure(message: "The component’s console didn’t answer in time.")
            }
            while let result = try await group.next() {
                if let output = result {
                    group.cancelAll()
                    return output
                }
            }
            throw Failure(message: "The console closed.")
        }
    }
}
