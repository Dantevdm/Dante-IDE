import DanteKit
import SwiftUI

/// The first tab for a database: how Dante reaches it, its biggest tables, and what the
/// code says about it.
struct DataOverview: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let connection: DatabaseConnection
    private var model: DataModel { session.data }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], spacing: 14) {
                connectionCard
                tablesCard
                codeCard
                if let connection = model.selected, !model.history(for: connection).isEmpty { recentCard }
            }
            .padding(18)
        }
    }

    private var route: String {
        switch DatabaseClient.route(for: connection, hasCompose: model.hasCompose) {
        case .local(let path): "\((path as NSString).lastPathComponent) on this Mac"
        case .compose(let service): "\(connection.engine.client) inside the \(service) container"
        case .missing: "\(connection.engine.client) isn’t installed"
        }
    }

    private var connectionCard: some View {
        Card("Connection") {
            VStack(alignment: .leading, spacing: 8) {
                fact("URL", connection.displayURL, mono: true)
                fact("Engine", model.schema?.version ?? connection.engine.name)
                fact("Through", route)
                if let service = connection.service { fact("Compose service", service, mono: true) }
                if let bytes = model.schema?.bytes { fact("Size", DataFormat.bytes(bytes)) }
                if let schema = model.schema {
                    fact("Tables", "\(schema.tables.filter { !$0.isView }.count) tables, \(schema.tables.filter(\.isView).count) views")
                }
                fact("Found", connection.origin == .saved ? "Saved on this Mac" : connection.note ?? "In the project")
                Toggle(isOn: Binding(get: { connection.readOnly }, set: { model.setReadOnly($0, for: connection) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Read-only").font(.dante(size: 12.5)).foregroundStyle(theme.text.color)
                        Text(connection.isLocal ? "Refuse statements that change data" : "Recommended: this database isn’t on this Mac")
                            .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    private func fact(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.dante(size: 12)).foregroundStyle(theme.text3.color).frame(width: 110, alignment: .leading)
            Text(value)
                .font(.dante(size: 12.5, design: mono ? .monospaced : .default))
                .foregroundStyle(theme.text.color)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var tablesCard: some View {
        if let schema = model.schema {
            let real = schema.tables.filter { !$0.isView }
            let bySize = real.sorted { ($0.bytes ?? $0.rows ?? 0) > ($1.bytes ?? $1.rows ?? 0) }.prefix(8)
            let largest = Double(bySize.first.flatMap { $0.bytes ?? $0.rows } ?? 1)
            Card("Largest tables") {
                if real.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No tables yet.").font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                        Button("Design the schema with Claude") {
                            session.askClaude("This database has no tables yet. Ask me what the app needs to store, then design the schema and write it as a migration in this project's migration tool.",
                                              instructions: DataContext.describe(connection, schema: schema))
                        }
                        .buttonStyle(DanteButtonStyle(primary: true))
                    }
                } else {
                    VStack(spacing: 7) {
                        ForEach(Array(bySize)) { table in
                            Button { model.open(table: table) } label: {
                                HStack(spacing: 10) {
                                    Text(table.qualifiedName).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color)
                                        .frame(width: 140, alignment: .leading).lineLimit(1)
                                    GeometryReader { proxy in
                                        let value = Double(table.bytes ?? table.rows ?? 0)
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(theme.accent.color.opacity(0.75))
                                            .frame(width: max(3, proxy.size.width * value / max(largest, 1)))
                                    }
                                    .frame(height: 8)
                                    Text(table.bytes.map(DataFormat.bytes) ?? table.rows.map { "\(DataFormat.count($0)) rows" } ?? "")
                                        .font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                                        .frame(width: 70, alignment: .trailing)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var codeCard: some View {
        let profile = model.profile
        return Card("In the code") {
            VStack(alignment: .leading, spacing: 10) {
                if profile.signals.isEmpty, profile.orms.isEmpty, profile.migrations.isEmpty {
                    Text("Dante didn’t find database code in this project yet.").font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                }
                if !profile.orms.isEmpty {
                    labelled("Libraries") { FlowLayout(spacing: 5) { ForEach(profile.orms, id: \.self) { Chip(text: $0, symbol: "shippingbox") } } }
                }
                if !profile.migrations.isEmpty {
                    labelled("Migrations") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(profile.migrations, id: \.path) { migration in
                                Text("\(migration.path)/ · \(migration.count) file\(migration.count == 1 ? "" : "s")")
                                    .font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color)
                                ForEach(latestMigrations(in: migration.path), id: \.self) { file in
                                    HStack(spacing: 6) {
                                        Text(file.lastPathComponent == "migration.sql" ? file.deletingLastPathComponent().lastPathComponent : file.lastPathComponent)
                                            .font(.dante(size: 11.5, design: .monospaced))
                                            .foregroundStyle(theme.text2.color)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 8)
                                        LinkButton("Preview") { preview(file) }
                                            .help("See what this migration changes, without running it")
                                    }
                                    .padding(.leading, 12)
                                }
                            }
                        }
                    }
                }
                let signals = profile.signals.prefix(8)
                if !signals.isEmpty {
                    labelled("Evidence") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(signals)) { signal in
                                HStack(spacing: 6) {
                                    if let engine = signal.engine { EngineBadge(engine: engine, size: 15) }
                                    Text(signal.label).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                                }
                            }
                        }
                    }
                }
                if !profile.migrations.isEmpty || !profile.orms.isEmpty {
                    Button("Compare the schema with the code") {
                        session.askClaude("Compare this database's real schema with the models and migrations in the code. Tell me about drift: tables or columns in one but not the other, mismatched types, and migrations that haven't run.",
                                          instructions: DataContext.describe(connection, schema: model.schema))
                    }
                    .buttonStyle(DanteButtonStyle())
                }
            }
        }
    }

    /// The newest few SQL migrations in a folder, newest last.
    private func latestMigrations(in folder: String) -> [URL] {
        guard let root = model.root else { return [] }
        return Array(MigrationPreview.files(in: root.appending(path: folder)).filter { !MigrationPreview.isDownMigration($0) }.suffix(4))
    }

    /// Opens the migration in a query tab, which previews its changes until it's run.
    private func preview(_ file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let name = file.lastPathComponent == "migration.sql" ? file.deletingLastPathComponent().lastPathComponent : file.deletingPathExtension().lastPathComponent
        model.newQuery(text, title: name)
    }

    private var recentCard: some View {
        Card("Recent queries") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.history(for: connection).prefix(6), id: \.self) { script in
                    Button { model.newQuery(script) } label: {
                        Text(script.replacingOccurrences(of: "\n", with: " "))
                            .font(.dante(size: 12, design: .monospaced))
                            .foregroundStyle(theme.text.color)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func labelled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            content()
        }
    }
}

/// The schema as an ER diagram, drawn by the same renderer as Mermaid erDiagrams in Docs.
struct SchemaDiagramView: View {
    @Environment(\.theme) private var theme
    let session: Session

    var body: some View {
        if let schema = session.data.schema {
            let diagram = schema.erDiagram()
            VStack(spacing: 0) {
                HStack {
                    Text("\(diagram.entities.count) tables, \(diagram.relationships.count) foreign keys\(schema.tables.filter { !$0.isView }.count > diagram.entities.count ? " (first \(diagram.entities.count) shown)" : "")")
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.text3.color)
                    Spacer()
                    Button {
                        if let url = writeDiagram(diagram) { session.showDoc(url) }
                    } label: {
                        Label("Save to Docs", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(DanteButtonStyle())
                    .help("Write docs/data-model.md with this diagram as Mermaid")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                ScrollView(.vertical) {
                    ERDiagramView(diagram: diagram)
                        .padding(30)
                }
                .background(theme.panel.color)
            }
        }
    }

    /// docs/data-model.md, so the diagram lives with the rest of the docs.
    private func writeDiagram(_ diagram: ERDiagram) -> String? {
        guard let root = session.data.root, let connection = session.data.selected else { return nil }
        var lines = ["# Data model", "", "The \(connection.engine.name) schema of `\(connection.database)`, drawn from the live database by Dante.", "", "```mermaid", "erDiagram"]
        for entity in diagram.entities {
            lines.append("    \(Self.mermaidName(entity.name)) {")
            for attribute in entity.attributes {
                let type = attribute.type.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "(", with: "_").replacingOccurrences(of: ")", with: "").replacingOccurrences(of: ",", with: "_")
                lines.append("        \(type) \(attribute.name)\(attribute.keys.isEmpty ? "" : " " + attribute.keys.joined(separator: ","))")
            }
            lines.append("    }")
        }
        for relation in diagram.relationships {
            let left = relation.fromCardinality == "1" ? "||" : "|o"
            lines.append("    \(Self.mermaidName(relation.from)) \(left)--o{ \(Self.mermaidName(relation.to)) : \"\(relation.label)\"")
        }
        lines.append("```")
        let path = "docs/data-model.md"
        let url = root.appending(path: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return path
        } catch {
            session.errorMessage = "Couldn’t write \(path): \(error.localizedDescription)"
            return nil
        }
    }

    static func mermaidName(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_")
    }
}

/// No database yet: what Dante found in the code, and the ways to get one.
struct DataEmptyState: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    private var model: DataModel { session.data }

    var body: some View {
        let profile = model.profile
        let engine = profile.suggestedEngine ?? .postgres
        AreaPage(
            eyebrow: "Data",
            title: profile.headline ?? "No database yet",
            subtitle: profile.isEmpty
                ? "Create a local database in Docker or as a SQLite file, or connect to one you already have. Dante browses tables, runs queries and draws the schema, and Claude can design it with you."
                : "Dante didn’t find a database it can connect to, but the code expects one. Create it locally in a minute, or connect to the one you use."
        ) {
            EmptyView()
        } content: {
            HStack(alignment: .top, spacing: 14) {
                OptionCard(
                    symbol: "shippingbox.fill", title: engine == .sqlite ? "Create a SQLite database" : "Create a local \(engine.name)",
                    detail: engine == .sqlite
                        ? "A file in the repo, with DATABASE_URL in .env."
                        : "A Docker Compose service with a volume and health check, a generated password in .env, and DATABASE_URL set.",
                    recommended: true
                ) { model.showsNewDatabase = true }
                OptionCard(symbol: "link", title: "Connect to a database",
                           detail: "Paste a DATABASE_URL or fill in the host. Passwords go in the Keychain; anything not on this Mac opens read-only.") {
                    model.showsConnect = true
                }
                OptionCard(symbol: "sparkles", title: "Design it with Claude",
                           detail: "Claude asks what the app stores, then writes the schema and migrations for the stack you use.") {
                    session.askClaude("This project needs a database. Ask me what the app has to store, then propose a schema (as a ```mermaid erDiagram) and write the migrations for the project's stack.")
                }
            }
            if !profile.signals.isEmpty || !profile.orms.isEmpty || !profile.otherStores.isEmpty {
                Card("What Dante found") {
                    FlowLayout(spacing: 6) {
                        ForEach(profile.signals) { signal in
                            HStack(spacing: 5) {
                                if let engine = signal.engine { EngineBadge(engine: engine, size: 15) }
                                Text(signal.label).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(theme.raised.color))
                        }
                        ForEach(profile.orms, id: \.self) { Chip(text: $0, symbol: "shippingbox") }
                        ForEach(profile.otherStores, id: \.self) { Chip(text: $0, symbol: "cylinder") }
                    }
                }
            }
        }
    }
}

private struct OptionCard: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let detail: String
    var recommended = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                        .font(.dante(size: 17))
                        .foregroundStyle(recommended ? theme.onAccent.color : theme.accent.color)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(recommended ? theme.accent.color : theme.accentTint.color))
                    Spacer()
                    if recommended { Chip(text: "Suggested", color: theme.accent.color) }
                }
                Text(title).font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
                Text(detail).font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering || recommended ? theme.accentLine.color : theme.line.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
