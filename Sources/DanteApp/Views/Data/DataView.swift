import DanteKit
import SwiftUI

/// Data: the project's databases. Dante finds them in compose files, env files, ORM
/// configs and SQLite files, connects through the engine's own client, and gives you a
/// schema browser, table viewer, query editor and ER diagram, with Claude a click away.
struct DataView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    private var model: DataModel { session.data }

    var body: some View {
        Group {
            if model.connections.isEmpty {
                DataEmptyState(session: session, workspace: workspace)
            } else {
                HStack(spacing: 0) {
                    DataSidebar(session: session)
                        .frame(width: 270)
                    Rectangle().fill(theme.line.color).frame(width: 1)
                    if let connection = model.selected {
                        DataMain(session: session, workspace: workspace, connection: connection)
                    }
                }
            }
        }
        .background(theme.ground.color)
        .task(id: workspace.revision) {
            let first = model.root == nil
            model.load(workspace: workspace)
            if let connection = model.selected, first || model.status[connection.id] == nil {
                await model.connect(connection)
            }
        }
        .sheet(isPresented: Binding(get: { model.showsNewDatabase }, set: { model.showsNewDatabase = $0 })) {
            NewDatabaseSheet(session: session, workspace: workspace)
        }
        .sheet(isPresented: Binding(get: { model.showsConnect }, set: { if !$0 { model.showsConnect = false; model.editing = nil } })) {
            ConnectSheet(session: session, workspace: workspace, editing: model.editing)
        }
    }
}

// MARK: - Sidebar

private struct DataSidebar: View {
    @Environment(\.theme) private var theme
    let session: Session
    @State private var filter = ""
    private var model: DataModel { session.data }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Databases")
                Spacer()
                IconButton(symbol: "link", label: "Connect to a database…", size: 11.5) { model.showsConnect = true }
                IconButton(symbol: "plus", label: "New database…", size: 12) { model.showsNewDatabase = true }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            VStack(spacing: 2) {
                ForEach(model.connections) { connection in
                    Button { model.select(connection) } label: {
                        ConnectionRow(connection: connection, status: model.status[connection.id] ?? .unknown, isSelected: model.selected?.id == connection.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: connection) }
                }
            }
            .padding(.horizontal, 8)

            Rectangle().fill(theme.line.color).frame(height: 1).padding(.top, 12)

            if let schema = model.schema {
                tables(schema)
            } else {
                Spacer()
            }

            if !model.profile.otherStores.isEmpty {
                HStack(spacing: 6) {
                    Text("Also uses").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                    ForEach(model.profile.otherStores, id: \.self) { Chip(text: $0) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
                .help("Dante can browse PostgreSQL, MySQL and SQLite. These show up so Claude knows about them.")
            }
        }
        .background(theme.panel.color)
    }

    @ViewBuilder
    private func menu(for connection: DatabaseConnection) -> some View {
        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(connection.displayURL, forType: .string)
        }
        Button(connection.readOnly ? "Allow Changes" : "Make Read-Only") { model.setReadOnly(!connection.readOnly, for: connection) }
        Button("Edit…") {
            model.editing = connection
            model.showsConnect = true
        }
        if connection.origin == .saved {
            Divider()
            Button("Remove", role: .destructive) { model.remove(connection) }
        }
    }

    private func tables(_ schema: DatabaseSchema) -> some View {
        let shown = schema.tables.filter { filter.isEmpty || $0.qualifiedName.localizedCaseInsensitiveContains(filter) }
        let groups = Dictionary(grouping: shown) { $0.isView ? "Views" : ($0.schema.flatMap { $0 == "public" ? nil : $0 } ?? "Tables") }
        let order = ["Tables"] + groups.keys.filter { $0 != "Tables" && $0 != "Views" }.sorted() + ["Views"]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                TextField("Filter \(schema.tables.count) tables", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.dante(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.raised.color))
            .padding(.horizontal, 10)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                    ForEach(order.filter { groups[$0] != nil }, id: \.self) { group in
                        Text(group == "Tables" || group == "Views" ? group : "schema \(group)")
                            .font(.dante(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.text3.color)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                            .padding(.bottom, 3)
                        ForEach(groups[group] ?? []) { table in
                            Button { model.open(table: table) } label: {
                                TableRow(table: table, isSelected: model.tab == .table(table.qualifiedName))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                    Button("Open") { model.open(table: table) }
                                    Button("Query This Table") {
                                        model.newQuery("select *\nfrom \(table.sqlName(for: model.selected?.engine ?? .postgres))\nlimit 100;", title: table.name)
                                    }
                                    Button("Ask Claude About \(table.name)") { askAbout(table) }
                                    Button("Copy Name") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(table.qualifiedName, forType: .string)
                                    }
                                }
                        }
                    }
                    if shown.isEmpty {
                        Text(schema.tables.isEmpty ? "No tables yet. Run your migrations, or ask Claude to design the schema." : "No tables match.")
                            .font(.dante(size: 12))
                            .foregroundStyle(theme.text3.color)
                            .padding(14)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
    }

    private func askAbout(_ table: DatabaseSchema.Table) {
        guard let connection = model.selected, let schema = model.schema else { return }
        session.askClaude("Explain the \(table.qualifiedName) table: what it stores, how the code uses it, and anything that looks off (missing indexes, nullable columns that shouldn’t be, missing foreign keys).",
                          instructions: DataContext.describe(connection, schema: schema))
    }
}

private struct ConnectionRow: View {
    @Environment(\.theme) private var theme
    let connection: DatabaseConnection
    let status: DataModel.Status
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            EngineBadge(engine: connection.engine)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(connection.name).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(1)
                    if connection.readOnly {
                        Image(systemName: "lock.fill").font(.dante(size: 8.5)).foregroundStyle(theme.text3.color).help("Read-only")
                    }
                }
                Text(connection.note ?? connection.displayURL)
                    .font(.dante(size: 11))
                    .foregroundStyle(theme.text3.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            StatusDot(color: status.color(theme))
                .help(status.label)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? theme.accentTint.color : hovering ? theme.raised.color : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct TableRow: View {
    @Environment(\.theme) private var theme
    let table: DatabaseSchema.Table
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: table.isView ? "eye" : "tablecells")
                .font(.dante(size: 10.5))
                .foregroundStyle(isSelected ? theme.accent.color : theme.text3.color)
                .frame(width: 14)
            Text(table.name)
                .font(.dante(size: 12, design: .monospaced))
                .foregroundStyle(theme.text.color)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let rows = table.rows {
                Text(DataFormat.count(rows))
                    .font(.dante(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.text3.color)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? theme.accentTint.color : hovering ? theme.raised.color : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(table.columns.count) columns" + (table.rows.map { " · about \($0) rows" } ?? ""))
    }
}

/// A small coloured tile with the engine's initials.
struct EngineBadge: View {
    @Environment(\.theme) private var theme
    let engine: DatabaseEngine
    var size: CGFloat = 24

    var body: some View {
        let (letters, tint): (String, Color) = switch engine {
        case .postgres: ("PG", theme.accent.color)
        case .mysql: ("MY", theme.amber.color)
        case .sqlite: ("SQ", theme.green.color)
        }
        Text(letters)
            .font(.dante(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(tint.opacity(0.35)))
            .help(engine.name)
    }
}

extension DataModel.Status {
    func color(_ theme: Theme) -> Color {
        switch self {
        case .online: theme.green.color
        case .connecting, .unknown: theme.text3.color
        case .needsPassword, .offline: theme.amber.color
        case .failed: theme.red.color
        }
    }

    var label: String {
        switch self {
        case .unknown: "Not connected yet"
        case .connecting: "Connecting…"
        case .online: "Connected"
        case .needsPassword: "Needs a password"
        case .offline: "Not running"
        case .failed: "Couldn’t connect"
        }
    }
}

enum DataFormat {
    static func count(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<1_000_000: String(format: value < 10_000 ? "%.1fk" : "%.0fk", Double(value) / 1_000)
        default: String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func duration(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.2f s", ms / 1000)
    }
}

/// What Claude is told about a database: never the password.
enum DataContext {
    static func describe(_ connection: DatabaseConnection, schema: DatabaseSchema?) -> String {
        var lines = [
            "The user is looking at a \(connection.engine.name) database in Dante's Data area: \(connection.displayURL)\(connection.service.map { " (Docker Compose service \"\($0)\")" } ?? "")\(connection.readOnly ? ", read-only" : "").",
        ]
        if let version = schema?.version { lines.append("Server: \(version).") }
        if let schema, !schema.tables.isEmpty {
            lines.append("Schema (table(column type, pk, → foreign key)):")
            lines.append(schema.summary)
        }
        lines.append("When you write SQL for the user to run, put it in one ```sql block; Dante can open it in the query editor. Don't run SQL that changes data yourself unless asked, and never print database passwords.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Main

private struct DataMain: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let connection: DatabaseConnection
    @State private var password = ""
    private var model: DataModel { session.data }
    private var status: DataModel.Status { model.status[connection.id] ?? .unknown }

    var body: some View {
        VStack(spacing: 0) {
            header
            banner
            tabStrip
            Rectangle().fill(theme.line.color).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            EngineBadge(engine: connection.engine, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(connection.name).font(.dante(size: 16, weight: .semibold)).foregroundStyle(theme.text.color)
                    if let version = model.schema?.version { Chip(text: version) }
                    if connection.readOnly { Chip(text: "read-only", symbol: "lock.fill") }
                }
                HStack(spacing: 6) {
                    StatusDot(color: status.color(theme), size: 6)
                    Text(status == .online ? connection.displayURL : status.label)
                        .font(.dante(size: 11.5, design: status == .online ? .monospaced : .default))
                        .foregroundStyle(theme.text3.color)
                        .textSelection(.enabled)
                    if let bytes = model.schema?.bytes {
                        Text("· \(DataFormat.bytes(bytes))").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    }
                }
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", label: "Reconnect and reload the schema") { Task { await model.connect(connection) } }
            Button { model.showDiagram() } label: { Label("Diagram", systemImage: "point.3.connected.trianglepath.dotted") }
                .buttonStyle(DanteButtonStyle())
                .disabled(model.schema?.tables.isEmpty ?? true)
            Menu {
                Button("Explain This Database") { ask("Give me a tour of this database: what each group of tables is for, how they relate, and how the code uses them.") }
                Button("Suggest Indexes") { ask("Look at the schema and the queries in the code, and suggest indexes that are missing. Write them as a migration in this project's migration tool.") }
                Button("Find Schema Problems") { ask("Review this schema for problems: missing foreign keys, nullable columns that shouldn't be, inconsistent naming and types, and tables without primary keys.") }
                Button("Write a Seed Script") { ask("Write a script that seeds this database with realistic development data, in the project's language and ORM if it has one.") }
                Button("Draft a Migration…") { ask("I want to change the schema. Ask me what I need, then write the migration in this project's migration tool.") }
            } label: {
                Label("Ask Claude", systemImage: "sparkles")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { model.newQuery() } label: { Label("New Query", systemImage: "plus") }
                .buttonStyle(DanteButtonStyle(primary: true))
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(status != .online)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var banner: some View {
        switch status {
        case .needsPassword(let message):
            DataBanner(symbol: "key.fill", color: theme.amber.color, title: "\(connection.name) needs a password", detail: message) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(savePassword)
                Button("Connect", action: savePassword)
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .disabled(password.isEmpty)
            }
        case .offline(let message):
            DataBanner(symbol: "bolt.horizontal.circle", color: theme.amber.color,
                       title: connection.service.map { "The \($0) service isn’t running" } ?? "Nothing is answering at \(connection.displayURL)", detail: message) {
                if connection.service != nil, model.hasCompose {
                    Button {
                        Task { await model.start(connection) }
                    } label: {
                        Label(model.startingService == nil ? "Start \(connection.service!)" : "Starting…", systemImage: "play.fill")
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .disabled(model.startingService != nil)
                }
            }
        case .failed(let message):
            DataBanner(symbol: "exclamationmark.triangle.fill", color: theme.red.color, title: "Couldn’t connect to \(connection.name)", detail: message) {
                Button("Ask Claude") {
                    session.askClaude("Dante couldn't connect to the \(connection.engine.name) database \(connection.displayURL). The error was:\n\n\(message)\n\nWork out why from the project's config and tell me how to fix it.")
                }
                .buttonStyle(DanteButtonStyle())
            }
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting and reading the schema…").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        case .online, .unknown:
            EmptyView()
        }
    }

    private func savePassword() {
        guard !password.isEmpty else { return }
        model.setPassword(password, for: connection)
        password = ""
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.tabs) { tab in
                    DataTabButton(title: model.title(of: tab), symbol: symbol(tab), isSelected: model.tab == tab,
                                  isRunning: isRunning(tab), close: tab == .overview ? nil : { model.close(tab) }) {
                        model.tab = tab
                    }
                }
                IconButton(symbol: "plus", label: "New query (⇧⌘T)", size: 11) { model.newQuery() }
                    .disabled(status != .online)
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 34)
    }

    private func symbol(_ tab: DataModel.Tab) -> String {
        switch tab {
        case .overview: "square.grid.2x2"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .query: "terminal"
        case .table: "tablecells"
        }
    }

    private func isRunning(_ tab: DataModel.Tab) -> Bool {
        switch tab {
        case .query(let id): model.queries[id]?.running == true
        case .table(let name): model.tables[name]?.loading == true
        default: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .overview:
            DataOverview(session: session, workspace: workspace, connection: connection)
        case .diagram:
            SchemaDiagramView(session: session)
        case .query(let id):
            if model.queries[id] != nil {
                QueryView(session: session, connection: connection, id: id)
                    .id(id)
            }
        case .table(let name):
            if let table = model.schema?.table(name) {
                TableView(session: session, connection: connection, table: table)
                    .id(name)
            } else {
                EmptyState(symbol: "tablecells", title: "\(name) is gone", message: "The table isn’t in the schema any more.") { EmptyView() }
            }
        }
    }

    private func ask(_ text: String) {
        session.askClaude(text, instructions: DataContext.describe(connection, schema: model.schema))
    }
}

struct DataBanner<Actions: View>: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.dante(size: 15)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color)
                Text(detail)
                    .font(.dante(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.text2.color)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.3)))
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }
}

private struct DataTabButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let symbol: String
    let isSelected: Bool
    var isRunning = false
    let close: (() -> Void)?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: symbol).font(.dante(size: 10.5))
            }
            Text(title).font(.dante(size: 12, weight: isSelected ? .semibold : .regular)).lineLimit(1)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark").font(.dante(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .opacity(hovering || isSelected ? 1 : 0)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
        .foregroundStyle(isSelected ? theme.text.color : theme.text2.color)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? theme.raised.color : hovering ? theme.raised.color.opacity(0.5) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isSelected ? theme.line2.color : .clear))
        .contentShape(Rectangle())
    }
}
