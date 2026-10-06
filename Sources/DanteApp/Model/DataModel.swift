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
    var selectedID: String?
    private(set) var status: [String: Status] = [:]
    private(set) var schemas: [String: DatabaseSchema] = [:]
    private(set) var hasCompose = false
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

    /// Detected and saved connections; a saved one replaces the detected one it came from.
    var connections: [DatabaseConnection] {
        let savedIDs = Set(saved.map(\.id))
        return saved + profile.connections.filter { !savedIDs.contains($0.id) }
    }

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
        profile = DataDetector.detect(paths: workspace.files, compose: compose) { path in
            let url = root.appending(path: path)
            // Build files and env files are small; skip anything that isn't.
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000 else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        saved = store.connections(for: root)
        if selectedID == nil || !connections.contains(where: { $0.id == selectedID }) { selectedID = connections.first?.id }
    }

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

    /// `docker compose up -d <service>`, then waits for the database to answer.
    func start(_ connection: DatabaseConnection) async {
        guard let root, let service = connection.service else { return }
        startingService = service
        defer { startingService = nil }
        let output = await Shell.run(["docker", "compose", "up", "-d", service], in: root)
        guard output.succeeded else {
            status[connection.id] = .failed(output.message)
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

    func remove(_ connection: DatabaseConnection) {
        guard let root else { return }
        try? store.remove(connection.id, for: root)
        DatabasePasswords.set(nil, for: connection, project: root)
        saved = store.connections(for: root)
        if selectedID == connection.id { selectedID = connections.first?.id }
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
