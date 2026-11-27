import DanteKit
import Foundation
import Observation

/// The Data area's state for one window: the project's databases, which one is open,
/// its schema, and the query and table tabs. Kept on the session, so it survives
/// switching areas.
@MainActor @Observable
final class DataModel {
    enum Status: Equatable {
        case unknown, connecting
        case online
        /// The database refused the password, or wants one.
        case needsPassword(String)
        /// Nothing is listening; the compose service may be stopped.
        case offline(String)
        case failed(String)
    }

    enum Tab: Hashable, Identifiable {
        case overview, diagram
        case query(UUID)
        case table(String)

        var id: Self { self }
    }

    struct QueryDraft: Identifiable {
        let id = UUID()
        var title: String
        var text: String
        var run: QueryRun?
        var running = false
        /// Which result of a multi-statement run is showing.
        var shown: Int?
        /// The text whose plan `run` holds, when it was an Explain.
        var explained: String?
    }

    struct TableBrowse {
        var page = 0
        var orderBy: String?
        var descending = false
        var filter = ""
        var result: QueryResult?
        var error: String?
        var loading = false
        var elapsed: Duration?
        var mode: Mode = .rows
        /// Bumped per load, so a slow older load can't overwrite a newer one.
        var request = 0

        enum Mode: String, CaseIterable, Identifiable {
            case rows = "Rows", structure = "Structure", relations = "Relations"
            var id: String { rawValue }
        }
    }

    static let pageSize = 100

    private(set) var root: URL?
    private(set) var profile = DataDetector.detect(paths: [])
    private(set) var saved: [DatabaseConnection] = []
    /// Database containers started outside compose that look like this project's (`sp-pg`).
    private(set) var containers: [DatabaseConnection] = []
    var selectedID: String?
    private(set) var status: [String: Status] = [:]
    private(set) var schemas: [String: DatabaseSchema] = [:]
    private(set) var hasCompose = false
    /// SQL Server backups in the project, and in each connection's container by its id.
    private(set) var projectBackups: [DatabaseBackup] = []
    var containerBackups: [String: [DatabaseBackup]] = [:]
    var restoring: RestoreDraft?
    var backupStatus: [String: BackupStatus] = [:]
    private(set) var startingService: String?
    let store = ConnectionStore()

    // Tabs belong to the open connection; switching connections starts afresh.
    var tabs: [Tab] = [.overview]
    var tab: Tab = .overview
    var queries: [UUID: QueryDraft] = [:]
    var tables: [String: TableBrowse] = [:]
    /// Recent scripts, newest first, per connection.
    private(set) var history: [String: [String]] = [:]

    var showsNewDatabase = false
    var showsConnect = false
    var editing: DatabaseConnection?
    /// A saved connection waiting for the person to confirm removing it.
    var removing: DatabaseConnection?
    /// The connection being deleted, while Docker and the files are dealt with.
    var deleting: String?

    /// Detected and saved connections; a saved one replaces the detected one it came from.
    var connections: [DatabaseConnection] {
        let savedIDs = Set(saved.map(\.id))
        let hidden = hiddenIDs
        let found = profile.connections.filter { !savedIDs.contains($0.id) && !hidden.contains($0.id) }
        let known = savedIDs.union(found.map(\.id))
        return saved + found + containers.filter { !known.contains($0.id) && !hidden.contains($0.id) }
    }

    /// Detected connections the person removed: found again on every load, so remembered per
    /// project on this Mac and left out.
    private var hiddenIDs: Set<String> {
        _ = hiddenChanged
        return root.map { Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey($0)) ?? []) } ?? []
    }
    private var hiddenChanged = 0
    private static func hiddenKey(_ root: URL) -> String { "data.hidden." + root.path }

    var selected: DatabaseConnection? {
        connections.first { $0.id == selectedID } ?? connections.first
    }

    var schema: DatabaseSchema? { selected.flatMap { schemas[$0.id] } }

    // MARK: Loading

    func load(workspace: Workspace) {
        root = workspace.url
        let compose = ComposeFile.load(projectRoot: workspace.url)
        hasCompose = compose != nil
        let root = workspace.url
        // A repo of several projects keeps a compose file beside each.
        let nested = ComposeFile.nested(in: workspace.files).compactMap { path in
            ComposeFile.load(projectRoot: root, path: path).map { ((path as NSString).deletingLastPathComponent, $0) }
        }
        projectBackups = SQLServerBackups.inProject(workspace.files).map { path in
            let values = try? root.appending(path: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return DatabaseBackup(place: .project(path), bytes: values?.fileSize, modified: values?.contentModificationDate)
        }
        profile = DataDetector.detect(paths: workspace.files, compose: compose, nested: nested) { path in
            let url = root.appending(path: path)
            // Build files and env files are small; skip anything that isn't.
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000 else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        saved = store.connections(for: root)
        forgetCloudConnections()
        if selectedID == nil || !connections.contains(where: { $0.id == selectedID }) { selectedID = connections.first?.id }
    }

    /// Finds this project's database containers outside compose, running or not.
    func loadContainers(workspace: Workspace) async {
        guard RemoteRegistry.project(containing: workspace.url) == nil, let all = await DockerContainer.load() else { return }
        var found: [DatabaseConnection] = []
        for container in DockerContainer.related(all, project: workspace.name) where container.engine != nil {
            let inspected = await DockerContainer.inspect(container)
            if let connection = inspected.container.connection(environment: inspected.environment) { found.append(connection) }
        }
        guard found != containers else { return }
        containers = found
        if selectedID == nil { selectedID = connections.first?.id }
    }

    /// A database (its compose service or container) and a table to show once connections
    /// are loaded: asked for from the Map.
    var focus: (service: String?, table: String?)?

    func applyFocus() async {
        guard let focus, !connections.isEmpty else { return }
        let wanted = focus.service.flatMap { name in connections.first { $0.service == name || $0.container == name } }
        guard let connection = wanted ?? connections.first(where: { $0.id == selectedID }) ?? connections.first else { return }
        self.focus = nil
        if selectedID != connection.id {
            selectedID = connection.id
            tabs = [.overview]
            tab = .overview
            queries = [:]
            tables = [:]
            await connect(connection)
        } else if schemas[connection.id] == nil {
            await connect(connection)
        }
        guard let name = focus.table else { return }
        if let table = schemas[connection.id]?.tables.first(where: { $0.name.lowercased() == name.lowercased() }) {
            open(table: table)
        } else if schemas[connection.id] != nil {
            notice = "\(name) isn’t in \(connection.name) yet: the repo’s migrations create it, but they haven’t run against this database."
        }
    }

    /// Something to tell the user at the top of the page, until they close it.
    var notice: String?

    func select(_ connection: DatabaseConnection) {
        guard selectedID != connection.id else { return }
        selectedID = connection.id
        tabs = [.overview]
        tab = .overview
        queries = [:]
        tables = [:]
        Task { await connect(connection) }
    }

    func password(for connection: DatabaseConnection) -> String? {
        guard let root else { return connection.devPassword }
        return DatabasePasswords.password(for: connection, project: root) ?? connection.devPassword
    }

    /// Reads the schema, which is also how Dante finds out the connection works.
    func connect(_ connection: DatabaseConnection, quietly: Bool = false) async {
        guard let root else { return }
        if !quietly { status[connection.id] = .connecting }
        var script = SchemaQueries.script(for: connection.engine)
        if connection.engine == .sqlite, let file = connection.fileURL(projectRoot: root), !FileManager.default.fileExists(atPath: file.path) {
            status[connection.id] = .failed("\(connection.file ?? file.path) doesn’t exist yet. Run your migrations, or create it from New database.")
            return
        }
        let run = await DatabaseClient.run(script, on: connection, password: password(for: connection), projectRoot: root, hasCompose: hasCompose)
        if let error = run.error {
            status[connection.id] = classify(error, connection: connection)
            return
        }
        var schema = SchemaQueries.schema(from: run.results, engine: connection.engine)
        if connection.engine == .sqlite, let counts = SchemaQueries.sqliteCounts(schema.tables) {
            script = counts
            let counted = await DatabaseClient.run(script, on: connection, password: nil, projectRoot: root, hasCompose: false)
            for row in counted.results.first?.rows ?? [] {
                guard let name = row.first ?? nil, let index = schema.tables.firstIndex(where: { $0.name == name }) else { continue }
                schema.tables[index].rows = row.last.flatMap { $0 }.flatMap { Int($0) }
            }
        }
        schemas[connection.id] = schema
        status[connection.id] = .online
    }

    private func classify(_ error: String, connection: DatabaseConnection) -> Status {
        let lower = error.lowercased()
        if lower.contains("password authentication failed") || lower.contains("no password supplied") || lower.contains("access denied")
            || lower.contains("password is required") {
            return .needsPassword(error)
        }
        if lower.contains("connection refused") || lower.contains("could not connect") || lower.contains("can't connect")
            || lower.contains("is the server running") || lower.contains("service \"") && lower.contains("is not running")
            || lower.contains("no such service") || lower.contains("timeout expired") {
            return .offline(error)
        }
        return .failed(error)
    }

    /// `docker compose up -d <service>` (or `docker start` for a container outside compose),
    /// then waits for the database to answer.
    func start(_ connection: DatabaseConnection) async {
        guard let root, let service = connection.service ?? connection.container else { return }
        startingService = service
        defer { startingService = nil }
        let output = connection.service != nil
            ? await Shell.run(["docker", "compose", "up", "-d", service], in: connection.composeDirectory(projectRoot: root))
            : await Shell.run(["docker", "start", service], in: root)
        guard output.succeeded else {
            let names = ComposeVariables.named(inError: output.message)
            status[connection.id] = .failed(names.isEmpty ? output.message
                : "Compose needs \(names.joined(separator: ", ")), which .env doesn’t set. Services fills it in: a new password for a secret.")
            return
        }
        status[connection.id] = .connecting
        for _ in 0..<30 {
            await connect(connection, quietly: true)
            if status[connection.id] == .online { return }
            if case .needsPassword = status[connection.id] { return }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    // MARK: Saving

    func save(_ connection: DatabaseConnection, password: String?) {
        guard let root else { return }
        do {
            try store.save(connection, for: root)
            if let password { DatabasePasswords.set(password, for: connection, project: root) }
        } catch {
            status[connection.id] = .failed("Couldn’t save the connection: \(error.localizedDescription)")
        }
        saved = store.connections(for: root)
        selectedID = nil
        select(connection)
    }

    func setPassword(_ password: String, for connection: DatabaseConnection) {
        guard let root else { return }
        DatabasePasswords.set(password, for: connection, project: root)
        Task { await connect(connection) }
    }

    /// Deploy's Explore in Data saved deployed databases as "<db> on DigitalOcean" connections;
    /// that went (DigitalOcean's firewall only lets the app in), so they're forgotten, with their
    /// passwords.
    private func forgetCloudConnections() {
        for connection in saved where connection.name.hasSuffix(" on DigitalOcean") && connection.host.hasSuffix(".ondigitalocean.com") {
            remove(connection)
        }
    }

    func remove(_ connection: DatabaseConnection) {
        guard let root else { return }
        try? store.remove(connection.id, for: root)
        DatabasePasswords.set(nil, for: connection, project: root)
        if connection.origin != .saved {
            UserDefaults.standard.set(Array(hiddenIDs.union([connection.id])).sorted(), forKey: Self.hiddenKey(root))
            hiddenChanged += 1
        }
        saved = store.connections(for: root)
        if selectedID == connection.id { selectedID = connections.first?.id }
    }

    // MARK: Deleting a database Dante created

    static let createdNote = "created by Dante"

    /// What deleting a database Dante created would change, for the confirmation; nil for
    /// connections Dante only knows about, which are just forgotten.
    func removal(for connection: DatabaseConnection) -> DatabaseRemoval? {
        guard let root, connection.origin == .saved, connection.note == Self.createdNote else { return nil }
        let composePath = ComposeFile.load(projectRoot: root).map { ProposedChange.relativePath(of: $0.url, in: root) }
        return DatabaseRemoval.plan(for: connection, composePath: composePath) { path in
            try? String(contentsOf: root.appending(path: path), encoding: .utf8)
        }
    }

    /// Undoes the new-database wizard: removes the container (and its data unless `keepsData`),
    /// takes its service and keys out of the project's files, and forgets the connection, so
    /// the Data area starts fresh. Returns what couldn't be done, for the person to finish.
    func delete(_ connection: DatabaseConnection, keepsData: Bool, workspace: Workspace) async -> String? {
        guard let root, let removal = removal(for: connection) else {
            remove(connection)
            return nil
        }
        deleting = connection.id
        defer { deleting = nil }
        var notes: [String] = []
        if let service = removal.service {
            // Before the compose file changes: Compose finds the container through it.
            let project = await Self.composeProject(in: root)
            let removed = await Shell.run(["docker", "compose", "rm", "--stop", "--force", service], in: root)
            let dockerDown = !removed.succeeded && removed.message.localizedCaseInsensitiveContains("daemon")
            if !removed.succeeded, !dockerDown {
                notes.append("Docker couldn’t remove the \(service) container: \(removed.message)")
            }
            if !keepsData, let volume = removal.volume {
                let name = "\(project)_\(volume)"
                let gone = await Shell.run(["docker", "volume", "rm", name], in: root)
                if !gone.succeeded, !gone.message.localizedCaseInsensitiveContains("no such volume") {
                    notes.append(dockerDown
                        ? "Docker isn’t running, so its data is still in the \(name) volume. Once Docker is up, remove it with: docker volume rm \(name)"
                        : "The \(name) volume is still there: \(gone.message)")
                }
            } else if dockerDown {
                notes.append("Docker isn’t running, so if it had a container, it’s still there: docker compose rm would have removed it.")
            }
        }
        for edit in removal.edits {
            let url = root.appending(path: edit.path)
            do {
                if let text = edit.text {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                } else {
                    // A compose file with nothing else in it goes to the Trash, not away for good.
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            } catch {
                notes.append("Couldn’t change \(edit.path): \(error.localizedDescription)")
            }
        }
        if !keepsData, let file = removal.file {
            let url = URL(filePath: file, relativeTo: root)
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
        remove(connection)
        load(workspace: workspace)
        return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
    }

    /// Compose's project name, which prefixes its volumes: `name:` in the file, else the folder.
    static func composeProject(in root: URL) async -> String {
        let output = await Shell.run(["docker", "compose", "config", "--format", "json"], in: root, timeout: .seconds(20))
        if output.succeeded, let name = JSONValue(line: output.stdout)?["name"]?.string, !name.isEmpty { return name }
        return root.lastPathComponent.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    func setReadOnly(_ readOnly: Bool, for connection: DatabaseConnection) {
        var changed = connection
        changed.readOnly = readOnly
        guard let root else { return }
        try? store.save(changed, for: root)
        saved = store.connections(for: root)
    }

    // MARK: Tabs

    @discardableResult
    func newQuery(_ text: String = "", title: String? = nil) -> UUID {
        let number = queries.count + 1
        let draft = QueryDraft(title: title ?? "Query \(number)", text: text)
        queries[draft.id] = draft
        tabs.append(.query(draft.id))
        tab = .query(draft.id)
        return draft.id
    }

    func open(table: DatabaseSchema.Table) {
        if tables[table.qualifiedName] == nil { tables[table.qualifiedName] = TableBrowse() }
        if !tabs.contains(.table(table.qualifiedName)) { tabs.append(.table(table.qualifiedName)) }
        tab = .table(table.qualifiedName)
        if tables[table.qualifiedName]?.result == nil { Task { await browse(table) } }
    }

    func showDiagram() {
        if !tabs.contains(.diagram) { tabs.insert(.diagram, at: min(1, tabs.count)) }
        tab = .diagram
    }

    func close(_ closing: Tab) {
        guard closing != .overview, let index = tabs.firstIndex(of: closing) else { return }
        tabs.remove(at: index)
        if case .query(let id) = closing { queries[id] = nil }
        if case .table(let name) = closing { tables[name] = nil }
        if tab == closing { tab = tabs[max(0, index - 1)] }
    }

    func title(of tab: Tab) -> String {
        switch tab {
        case .overview: "Overview"
        case .diagram: "Diagram"
        case .query(let id): queries[id]?.title ?? "Query"
        case .table(let name): name
        }
    }

    // MARK: Running

    func run(_ id: UUID, explain: Bool = false) async {
        guard let connection = selected, let root, var draft = queries[id] else { return }
        let script = explain ? SQLScript.split(draft.text).map { SchemaQueries.explain($0, engine: connection.engine) }.joined(separator: ";\n") : draft.text
        draft.running = true
        queries[id] = draft
        let run = await DatabaseClient.run(script, on: connection, password: password(for: connection), projectRoot: root, hasCompose: hasCompose)
        draft = queries[id] ?? draft
        draft.running = false
        draft.run = run
        draft.explained = explain ? draft.text : nil
        draft.shown = run.results.lastIndex(where: \.hasRows) ?? run.results.indices.last
        queries[id] = draft
        if !explain, run.error == nil {
            var recent = history[connection.id] ?? []
            recent.removeAll { $0 == draft.text }
            recent.insert(draft.text, at: 0)
            history[connection.id] = Array(recent.prefix(30))
            // Schema changes show up in the sidebar straight away.
            if SQLScript.statements(script).contains(where: { $0.kind == .schema }) { await connect(connection, quietly: true) }
        }
    }

    func browse(_ table: DatabaseSchema.Table) async {
        guard let connection = selected, let root, var state = tables[table.qualifiedName] else { return }
        state.loading = true
        state.request += 1
        let request = state.request
        tables[table.qualifiedName] = state
        let sql = SchemaQueries.browse(table, engine: connection.engine, limit: Self.pageSize, offset: state.page * Self.pageSize,
                                       orderBy: state.orderBy, descending: state.descending, filter: state.filter)
        let run = await DatabaseClient.run(sql, on: connection, password: password(for: connection), projectRoot: root, hasCompose: hasCompose)
        state = tables[table.qualifiedName] ?? state
        guard state.request == request else { return }
        state.loading = false
        state.result = run.results.first
        state.error = run.error
        state.elapsed = run.elapsed
        tables[table.qualifiedName] = state
    }

    func history(for connection: DatabaseConnection) -> [String] { history[connection.id] ?? [] }
}


// MARK: SQL Server backups

extension DataModel {
    /// A backup being restored, for the sheet: what the backup holds, where it goes, and how
    /// far the restore has got.
    struct RestoreDraft: Identifiable {
        enum Stage: Equatable {
            case reading, ready, restoring, done(String), failed(String)
        }

        let id = UUID()
        var backup: DatabaseBackup
        var connection: DatabaseConnection
        var stage: Stage = .reading
        var header = BackupHeader()
        var files: [BackupFile] = []
        /// The databases the server already holds, to warn before replacing one.
        var existing: [String] = []
        var database = ""
        var makeSaOwner = true

        var replaces: Bool { existing.contains { $0.caseInsensitiveCompare(database) == .orderedSame } }
    }

    /// Whether Dante can reach the server's container to copy a backup in or out.
    func canRestore(_ connection: DatabaseConnection) -> Bool {
        connection.engine == .sqlserver && (connection.service != nil || connection.container != nil)
    }

    /// The project's backups and the container's, newest first.
    func backups(for connection: DatabaseConnection) -> [DatabaseBackup] {
        (projectBackups + (containerBackups[connection.id] ?? [])).sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// Looks in the container's backup folder.
    func loadContainerBackups(for connection: DatabaseConnection) async {
        guard canRestore(connection) else { return }
        let output = await dockerExec(connection, SQLServerBackups.listCommand)
        guard output.succeeded else { return }
        containerBackups[connection.id] = SQLServerBackups.parseList(output.stdout)
    }

    /// Opens the restore sheet and reads what the backup holds, copying it into the container
    /// first when it isn't there yet.
    func prepareRestore(_ backup: DatabaseBackup, on connection: DatabaseConnection) async {
        var draft = RestoreDraft(backup: backup, connection: connection)
        draft.database = backup.suggestedDatabase
        restoring = draft
        guard let root else { return }
        let path = SQLServerBackups.containerPath(for: backup)
        if let source = localFile(of: backup, root: root) {
            _ = await dockerExec(connection, ["mkdir", "-p", SQLServerBackups.containerFolder])
            let copied = await dockerCopy(connection, from: source.path, to: path, intoContainer: true)
            guard copied.succeeded else { return failRestore(draft.id, "Couldn’t copy \(backup.name) into the container: \(copied.message)") }
            // `cp` leaves the file root's; SQL Server reads it as its own user (mssql).
            _ = await dockerExec(connection, SQLServerBackups.readableCommand(path), asRoot: true)
        }
        let master = masterConnection(connection)
        let header = await DatabaseClient.run(SQLServerBackups.headerSQL(path: path), on: master, password: password(for: connection), projectRoot: root, hasCompose: hasCompose)
        if let error = header.error { return failRestore(draft.id, "SQL Server couldn’t read \(backup.name): \(error)") }
        let files = await DatabaseClient.run(SQLServerBackups.fileListSQL(path: path), on: master, password: password(for: connection), projectRoot: root, hasCompose: hasCompose)
        if let error = files.error { return failRestore(draft.id, "SQL Server couldn’t list the files in \(backup.name): \(error)") }
        let databases = await DatabaseClient.run(SQLServerBackups.databasesSQL, on: master, password: password(for: connection), projectRoot: root, hasCompose: hasCompose)
        guard restoring?.id == draft.id else { return }
        draft.header = SQLServerBackups.header(from: header.results.first)
        draft.files = SQLServerBackups.files(from: files.results.first)
        draft.existing = databases.results.first?.rows.compactMap { $0.first ?? nil } ?? []
        if let name = draft.header.database { draft.database = name }
        draft.stage = .ready
        restoring = draft
    }

    private func failRestore(_ id: UUID, _ message: String) {
        guard restoring?.id == id else { return }
        restoring?.stage = .failed(message)
    }

    /// Restores the sheet's backup. Replacing a database puts its other sessions out first.
    func restore() async {
        guard let root, var draft = restoring, draft.stage == .ready else { return }
        let name = draft.database.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        draft.stage = .restoring
        restoring = draft
        let connection = draft.connection
        let sql = SQLServerBackups.restoreSQL(path: SQLServerBackups.containerPath(for: draft.backup), database: name, files: draft.files, makeSaOwner: draft.makeSaOwner)
        let run = await DatabaseClient.run(sql, on: masterConnection(connection), password: password(for: connection), projectRoot: root, hasCompose: hasCompose)
        guard restoring?.id == draft.id else { return }
        if let error = run.error {
            restoring?.stage = .failed(error)
            return
        }
        restoring?.stage = .done(draft.replaces ? "\(name) now holds what \(draft.backup.name) held." : "\(name) is restored from \(draft.backup.name).")
        // The open database may be the one just replaced.
        if connection.database.caseInsensitiveCompare(name) == .orderedSame { await self.connect(connection) }
        await loadContainerBackups(for: connection)
    }

    /// A copy-only backup of the connection's database, copied out of the container to
    /// `folder` on this Mac.
    func backUp(_ connection: DatabaseConnection, to folder: URL) async {
        guard let root, canRestore(connection) else { return }
        backupStatus[connection.id] = .working("Backing up \(connection.database)…")
        let name = SQLServerBackups.backupName(database: connection.database)
        let path = SQLServerBackups.containerFolder + "/" + name
        _ = await dockerExec(connection, ["mkdir", "-p", SQLServerBackups.containerFolder])
        let run = await DatabaseClient.run(SQLServerBackups.backupSQL(database: connection.database, path: path),
                                           on: masterConnection(connection), password: password(for: connection), projectRoot: root, hasCompose: hasCompose)
        if let error = run.error {
            backupStatus[connection.id] = .failed(error)
            return
        }
        let target = folder.appending(path: name)
        let copied = await dockerCopy(connection, from: path, to: target.path, intoContainer: false)
        backupStatus[connection.id] = copied.succeeded
            ? .done("Saved \(name) in \(folder.lastPathComponent)/.", target)
            : .failed("The backup is in the container at \(path), but copying it out failed: \(copied.message)")
        await loadContainerBackups(for: connection)
    }

    enum BackupStatus: Equatable {
        case working(String), done(String, URL), failed(String)
    }

    private func masterConnection(_ connection: DatabaseConnection) -> DatabaseConnection {
        var master = connection
        master.database = "master"
        return master
    }

    private func localFile(of backup: DatabaseBackup, root: URL) -> URL? {
        switch backup.place {
        case .project(let path): root.appending(path: path)
        case .file(let url): url
        case .container: nil
        }
    }

    private func dockerExec(_ connection: DatabaseConnection, _ arguments: [String], asRoot: Bool = false) async -> Shell.Output {
        guard let root else { return Shell.Output(status: 1, stdout: "", stderr: "No project.") }
        let user = asRoot ? ["-u", "0"] : []
        if let service = connection.service {
            return await Shell.run(["docker", "compose", "exec", "-T"] + user + [service] + arguments, in: connection.composeDirectory(projectRoot: root), timeout: .seconds(60))
        }
        return await Shell.run(["docker", "exec"] + user + [connection.container ?? ""] + arguments, in: root, timeout: .seconds(60))
    }

    /// `docker compose cp` for a compose service, `docker cp` for a container run by hand.
    private func dockerCopy(_ connection: DatabaseConnection, from: String, to: String, intoContainer: Bool) async -> Shell.Output {
        guard let root else { return Shell.Output(status: 1, stdout: "", stderr: "No project.") }
        let name = connection.service ?? connection.container ?? ""
        let (source, target) = intoContainer ? (from, "\(name):\(to)") : ("\(name):\(from)", to)
        if connection.service != nil {
            return await Shell.run(["docker", "compose", "cp", source, target], in: connection.composeDirectory(projectRoot: root))
        }
        return await Shell.run(["docker", "cp", source, target], in: root)
    }
}
