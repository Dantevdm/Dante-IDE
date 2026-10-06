import AppKit
import DanteKit
import SwiftUI

/// Connect to a database that already exists: paste a URL or fill in the fields, test it,
/// and save it on this Mac. Postgres servers running here are offered with their databases.
struct ConnectSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session
    let workspace: Workspace
    let editing: DatabaseConnection?

    @State private var engine: DatabaseEngine = .postgres
    @State private var url = ""
    @State private var name = ""
    @State private var host = "localhost"
    @State private var port = 5432
    @State private var database = ""
    @State private var user = NSUserName()
    @State private var password = ""
    @State private var file = ""
    @State private var readOnly = false
    @State private var readOnlyTouched = false
    @State private var testing = false
    @State private var test: Result<String, TestFailure>?
    @State private var localDatabases: [String] = []

    struct TestFailure: Error { let message: String }

    init(session: Session, workspace: Workspace, editing: DatabaseConnection?) {
        self.session = session
        self.workspace = workspace
        self.editing = editing
        if let editing {
            _engine = State(initialValue: editing.engine)
            _name = State(initialValue: editing.name)
            _host = State(initialValue: editing.host)
            _port = State(initialValue: editing.port ?? editing.engine.defaultPort ?? 0)
            _database = State(initialValue: editing.database)
            _user = State(initialValue: editing.user)
            _file = State(initialValue: editing.file ?? "")
            _readOnly = State(initialValue: editing.readOnly)
            _readOnlyTouched = State(initialValue: true)
        }
    }

    private var connection: DatabaseConnection {
        var made = DatabaseConnection(
            id: editing?.id, name: name.isEmpty ? (engine == .sqlite ? (file as NSString).lastPathComponent : database) : name,
            engine: engine, host: host, port: engine == .sqlite ? nil : port, database: engine == .sqlite ? (file as NSString).lastPathComponent : database,
            user: user, file: engine == .sqlite ? file : nil, service: editing?.service, readOnly: readOnly, origin: .saved, note: editing?.note
        )
        made.devPassword = editing?.devPassword
        return made
    }

    private var isValid: Bool {
        engine == .sqlite ? !file.isEmpty : !host.isEmpty && !database.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "link").font(.dante(size: 16)).foregroundStyle(theme.accent.color)
                Text(editing == nil ? "Connect to a database" : "Edit \(editing!.name)").font(.dante(size: 16, weight: .semibold)).foregroundStyle(theme.text.color)
                Spacer()
                Picker("", selection: $engine) {
                    ForEach(DatabaseEngine.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if engine != .sqlite {
                dataField("Paste a URL", detail: "postgres://user:password@host:5432/db — Dante fills in the fields below and keeps the password in the Keychain.") {
                    TextField("DATABASE_URL", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .font(.dante(size: 12.5, design: .monospaced))
                        .onChange(of: url) { fill(from: url) }
                }
                if !localDatabases.isEmpty, editing == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PostgreSQL on this Mac").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                        FlowLayout(spacing: 5) {
                            ForEach(localDatabases, id: \.self) { name in
                                Button {
                                    engine = .postgres
                                    host = "localhost"
                                    port = 5432
                                    database = name
                                    user = NSUserName()
                                    self.name = name
                                } label: {
                                    Label(name, systemImage: "cylinder")
                                        .font(.dante(size: 12, design: .monospaced))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Capsule().fill(database == name ? theme.accentTint.color : theme.raised.color))
                                        .overlay(Capsule().strokeBorder(database == name ? theme.accentLine.color : theme.line.color))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    dataField("Host") { TextField("localhost", text: $host).textFieldStyle(.roundedBorder) }
                    dataField("Port") { TextField("5432", value: $port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder) }.frame(width: 90)
                }
                HStack(spacing: 12) {
                    dataField("Database") { TextField("app", text: $database).textFieldStyle(.roundedBorder) }
                    dataField("User") { TextField("postgres", text: $user).textFieldStyle(.roundedBorder) }
                    dataField("Password") { SecureField(editing == nil ? "" : "unchanged", text: $password).textFieldStyle(.roundedBorder) }
                }
            } else {
                dataField("File", detail: "A path in the project, or anywhere on this Mac.") {
                    HStack {
                        TextField("data/app.sqlite", text: $file).textFieldStyle(.roundedBorder).font(.dante(size: 12.5, design: .monospaced))
                        Button("Choose…", action: chooseFile).buttonStyle(DanteButtonStyle())
                    }
                }
            }
            dataField("Name") { TextField(connection.name, text: $name).textFieldStyle(.roundedBorder) }
            Toggle(isOn: Binding(get: { readOnly }, set: { readOnly = $0; readOnlyTouched = true })) {
                Text(DatabaseConnection.isLocal(host) || engine == .sqlite ? "Read-only" : "Read-only (recommended: this database isn’t on this Mac)")
                    .font(.dante(size: 12.5))
            }
            .toggleStyle(.checkbox)
            .onChange(of: host) { if !readOnlyTouched { readOnly = !DatabaseConnection.isLocal(host) } }

            if let test {
                switch test {
                case .success(let version): DataNote(symbol: "checkmark.circle.fill", color: theme.green.color, text: "Connected: \(version)")
                case .failure(let failure): DataNote(symbol: "xmark.octagon.fill", color: theme.red.color, text: failure.message)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button(testing ? "Testing…" : "Test") { Task { await runTest() } }
                    .buttonStyle(DanteButtonStyle())
                    .disabled(!isValid || testing)
                Button(editing == nil ? "Connect" : "Save") {
                    session.data.save(connection, password: password.isEmpty ? nil : password)
                    dismiss()
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(22)
        .frame(width: 600)
        .background(theme.card.color)
        .onChange(of: engine) {
            if editing == nil, let defaultPort = engine.defaultPort { port = defaultPort }
            test = nil
        }
        .task { await findLocalDatabases() }
    }

    private func fill(from text: String) {
        guard let parsed = DatabaseConnection.parse(url: text) else { return }
        engine = parsed.engine
        if parsed.engine == .sqlite {
            file = parsed.file ?? ""
        } else {
            host = parsed.host
            port = parsed.port ?? parsed.engine.defaultPort ?? port
            database = parsed.database
            user = parsed.user
            if let secret = parsed.devPassword { password = secret }
            if !readOnlyTouched { readOnly = parsed.readOnly }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = workspace.url
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = workspace.url.standardizedFileURL.path + "/"
        file = url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }

    private func runTest() async {
        testing = true
        defer { testing = false }
        let candidate = connection
        let secret = password.isEmpty ? session.data.password(for: candidate) : password
        let versionQuery = engine == .sqlite ? "select 'SQLite ' || sqlite_version()" : "select version()"
        let run = await DatabaseClient.run(versionQuery, on: candidate, password: secret, projectRoot: workspace.url, hasCompose: session.data.hasCompose)
        if let error = run.error {
            test = .failure(TestFailure(message: error))
        } else {
            let version = run.results.first?.rows.first?.first.flatMap { $0 }
            test = .success(version.map(SchemaQueries.shortVersion) ?? "OK")
        }
    }

    /// Databases on a Postgres server running on this Mac, if there is one and it lets
    /// this user in without a password (Homebrew's default).
    private func findLocalDatabases() async {
        guard Shell.which("pg_isready") != nil else { return }
        let ready = await Shell.run(["pg_isready", "-h", "localhost", "-p", "5432", "-t", "2"], in: workspace.url)
        guard ready.succeeded else { return }
        let list = await Shell.run(["psql", "-X", "-h", "localhost", "-d", "postgres", "--csv", "-t", "-c",
                                    "select datname from pg_database where not datistemplate order by datname"], in: workspace.url, extra: ["PGCONNECT_TIMEOUT": "3"])
        guard list.succeeded else { return }
        localDatabases = list.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }
}
