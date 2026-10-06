import AppKit
import DanteEditor
import DanteKit
import SwiftUI
import UniformTypeIdentifiers

/// A SQL editor over a results grid. ⌘↩ runs the script; statements that drop, empty or
/// rewrite whole tables ask first; each statement's result can be picked when there are several.
struct QueryView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let connection: DatabaseConnection
    let id: UUID
    @State private var confirming: [SQLStatement] = []
    @State private var request = ""
    private var model: DataModel { session.data }
    private var draft: DataModel.QueryDraft? { model.queries[id] }

    private var text: Binding<String> {
        Binding(get: { model.queries[id]?.text ?? "" }, set: { model.queries[id]?.text = $0 })
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                toolbar
                CodeEditorView(text: text, language: .sql, theme: theme, fontSize: 13)
                    .frame(minHeight: 90)
            }
            .frame(minHeight: 140, idealHeight: 240)
            results
                .frame(minHeight: 120, maxHeight: .infinity)
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { !confirming.isEmpty }, set: { if !$0 { confirming = [] } }), titleVisibility: .visible) {
            Button("Run It", role: .destructive) {
                confirming = []
                Task { await model.run(id) }
            }
            Button("Cancel", role: .cancel) { confirming = [] }
        } message: {
            Text(confirming.map { "• \($0.text.prefix(80))" }.joined(separator: "\n"))
        }
    }

    private var confirmTitle: String {
        let dangers = confirming.compactMap(\.danger)
        return "This \(dangers.joined(separator: " and ")) in \(connection.name). Run it?"
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: run) {
                Label(draft?.running == true ? "Running…" : "Run", systemImage: "play.fill")
            }
            .buttonStyle(DanteButtonStyle(primary: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(draft?.running == true || text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Run the script (⌘↩)")
            Button { Task { await model.run(id, explain: true) } } label: { Label("Explain", systemImage: "list.bullet.indent") }
                .buttonStyle(DanteButtonStyle())
                .disabled(draft?.running == true || text.wrappedValue.isEmpty)
                .help("Show the query plan")
            history
            Rectangle().fill(theme.line.color).frame(width: 1, height: 18)
            Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(theme.accent.color)
            TextField("Describe a query and Claude writes it…", text: $request)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .onSubmit(askForQuery)
            if !request.isEmpty {
                Button("Ask", action: askForQuery).buttonStyle(DanteButtonStyle())
            }
            Spacer(minLength: 0)
            if connection.readOnly {
                Label("Read-only", systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(theme.text3.color)
            }
            IconButton(symbol: "square.and.arrow.down", label: "Save as a .sql file…") { saveScript() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.panel.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    private var history: some View {
        Menu {
            let recent = model.history(for: connection)
            if recent.isEmpty { Text("Nothing run yet") }
            ForEach(recent, id: \.self) { script in
                Button(script.replacingOccurrences(of: "\n", with: " ").prefix(70)) { text.wrappedValue = script }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Recent queries")
    }

    private func run() {
        let statements = SQLScript.statements(text.wrappedValue)
        let dangerous = statements.filter { $0.danger != nil }
        if !connection.readOnly, !dangerous.isEmpty {
            confirming = dangerous
        } else {
            Task { await model.run(id) }
        }
    }

    private func askForQuery() {
        let wanted = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return }
        request = ""
        session.askClaude("Write a \(connection.engine.name) query: \(wanted)",
                          instructions: DataContext.describe(connection, schema: model.schema) + "\nAnswer with the query in one ```sql block and a sentence on what it does. Don't run it.")
    }

    private func saveScript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.nameFieldStringValue = (draft?.title ?? "query").lowercased().replacingOccurrences(of: " ", with: "-") + ".sql"
        panel.directoryURL = model.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.wrappedValue.write(to: url, atomically: true, encoding: .utf8)
            model.queries[id]?.title = url.deletingPathExtension().lastPathComponent
        } catch {
            session.errorMessage = "Couldn’t save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if let draft, let run = draft.run {
            VStack(spacing: 0) {
                if let error = run.error {
                    ErrorStrip(error: error) {
                        session.askClaude("This \(connection.engine.name) query failed:\n\n```sql\n\(draft.text)\n```\n\nError:\n\n\(error)\n\nWhat's wrong, and what's the fixed query?",
                                          instructions: DataContext.describe(connection, schema: model.schema))
                    }
                }
                if run.results.count > 1 {
                    resultPicker(run)
                }
                if let index = draft.shown, run.results.indices.contains(index) {
                    let result = run.results[index]
                    if result.hasRows {
                        ResultGrid(result: result)
                        footer(result, elapsed: run.elapsed)
                    } else {
                        message(result.message ?? "Done", elapsed: run.elapsed)
                    }
                } else if run.error == nil {
                    message("Done", elapsed: run.elapsed)
                } else {
                    Spacer()
                }
            }
            .opacity(draft.running ? 0.5 : 1)
        } else if draft?.running == true {
            VStack { ProgressView().controlSize(.small) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.cursor").font(.system(size: 22)).foregroundStyle(theme.text3.color)
                Text("Write SQL above and press ⌘↩").font(.system(size: 13)).foregroundStyle(theme.text2.color)
                Text("Several statements run in one session, so BEGIN … COMMIT works.").font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.ground.color)
        }
    }

    private func resultPicker(_ run: QueryRun) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(run.results) { result in
                    let selected = draft?.shown == result.id
                    Button {
                        model.queries[id]?.shown = result.id
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(result.id + 1)").font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            Text(result.hasRows ? "\(result.rows.count) row\(result.rows.count == 1 ? "" : "s")" : result.message ?? "Done")
                                .font(.system(size: 11.5))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .foregroundStyle(selected ? theme.text.color : theme.text2.color)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? theme.raised.color : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? theme.line2.color : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(result.statement)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .background(theme.panel.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    private func message(_ text: String, elapsed: Duration) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle").font(.system(size: 20)).foregroundStyle(theme.green.color)
            Text(text).font(.system(size: 13, design: .monospaced)).foregroundStyle(theme.text.color)
            Text(DataFormat.duration(elapsed)).font(.system(size: 11)).foregroundStyle(theme.text3.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.ground.color)
    }

    private func footer(_ result: QueryResult, elapsed: Duration) -> some View {
        HStack(spacing: 10) {
            Text("\(result.rows.count) row\(result.rows.count == 1 ? "" : "s")\(result.truncated ? " shown (more were returned)" : "") · \(DataFormat.duration(elapsed))")
                .font(.system(size: 11.5))
                .foregroundStyle(result.truncated ? theme.amber.color : theme.text3.color)
            Spacer()
            Menu {
                Button("Copy as CSV") { copy(result.csv) }
                Button("Copy as Markdown") { copy(result.markdown()) }
                Button("Save as CSV…") { saveCSV(result) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                session.askClaude("Here are the results of this query:\n\n```sql\n\(result.statement)\n```\n\n\(result.markdown(limit: 40))\n\nWhat do they tell us?",
                                  instructions: DataContext.describe(connection, schema: model.schema))
            } label: {
                Label("Ask Claude", systemImage: "sparkles")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(theme.accent.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.panel.color)
        .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveCSV(_ result: QueryResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "results.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? result.csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct ErrorStrip: View {
    @Environment(\.theme) private var theme
    let error: String
    let ask: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(theme.red.color)
            Text(error)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: ask) { Label("Fix with Claude", systemImage: "sparkles") }
                .buttonStyle(DanteButtonStyle())
        }
        .padding(12)
        .background(theme.red.color.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.red.color.opacity(0.3)).frame(height: 1) }
    }
}

/// One table: its rows a page at a time (sortable, filterable), its columns, and the
/// tables it points at or is pointed at by.
struct TableView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let connection: DatabaseConnection
    let table: DatabaseSchema.Table
    @State private var filterText = ""
    private var model: DataModel { session.data }
    private var state: DataModel.TableBrowse { model.tables[table.qualifiedName] ?? .init() }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch state.mode {
            case .rows: rows
            case .structure: structure
            case .relations: relations
            }
        }
        .onAppear { filterText = state.filter }
    }

    private func update(_ change: (inout DataModel.TableBrowse) -> Void, reload: Bool = true) {
        var next = state
        change(&next)
        model.tables[table.qualifiedName] = next
        if reload { Task { await model.browse(table) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { state.mode }, set: { mode in update({ $0.mode = mode }, reload: false) })) {
                ForEach(DataModel.TableBrowse.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if state.mode == .rows {
                HStack(spacing: 6) {
                    Text("WHERE").font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(theme.accent.color)
                    TextField("email like '%@example.com'", text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { update { $0.filter = filterText; $0.page = 0 } }
                    if filterText != state.filter {
                        Button("Apply") { update { $0.filter = filterText; $0.page = 0 } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(theme.accent.color)
                            .help("Show only rows that match (↩)")
                    }
                    if !state.filter.isEmpty {
                        IconButton(symbol: "xmark.circle.fill", label: "Clear the filter", size: 11) {
                            filterText = ""
                            update { $0.filter = ""; $0.page = 0 }
                        }
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.raised.color))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line.color))
            } else {
                Spacer()
            }
            HStack(spacing: 6) {
                if let rows = table.rows { Chip(text: "~\(DataFormat.count(rows)) rows") }
                if let bytes = table.bytes { Chip(text: DataFormat.bytes(bytes)) }
            }
            IconButton(symbol: "arrow.clockwise", label: "Reload") { Task { await model.browse(table) } }
            Button {
                model.newQuery("select *\nfrom \(table.sqlName(for: connection.engine))\(state.filter.isEmpty ? "" : "\nwhere \(state.filter)")\nlimit 100;", title: table.name)
            } label: {
                Label("Query", systemImage: "terminal")
            }
            .buttonStyle(DanteButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.panel.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    @ViewBuilder
    private var rows: some View {
        if let error = state.error {
            ErrorStrip(error: error) {
                session.askClaude("Browsing \(table.qualifiedName) with the filter `\(state.filter)` failed:\n\n\(error)\n\nWhat's the right filter?",
                                  instructions: DataContext.describe(connection, schema: model.schema))
            }
            Spacer()
        } else if let result = state.result {
            if result.rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 20)).foregroundStyle(theme.text3.color)
                    Text(state.filter.isEmpty ? "\(table.name) is empty" : "No rows match").font(.system(size: 13)).foregroundStyle(theme.text2.color)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultGrid(
                    result: result, firstRow: state.page * DataModel.pageSize, sortColumn: state.orderBy, descending: state.descending,
                    onSort: { column in
                        update { browse in
                            if browse.orderBy == column { browse.descending.toggle() } else { browse.orderBy = column; browse.descending = false }
                            browse.page = 0
                        }
                    },
                    onFilter: { column, value in
                        let condition = "\(SQLScript.quote(column, for: connection.engine)) " + (value.map { "= \(SQLScript.literal($0))" } ?? "is null")
                        filterText = condition
                        update { $0.filter = condition; $0.page = 0 }
                    }
                )
                .opacity(state.loading ? 0.5 : 1)
            }
            pager(result)
        } else {
            VStack { ProgressView().controlSize(.small) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pager(_ result: QueryResult) -> some View {
        let first = state.page * DataModel.pageSize
        let hasMore = result.rows.count == DataModel.pageSize
        return HStack(spacing: 10) {
            Text(result.rows.isEmpty ? "No rows" : "Rows \(first + 1)–\(first + result.rows.count)\(table.rows.map { $0 > 0 ? " of ~\(DataFormat.count($0))" : "" } ?? "")")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.text3.color)
            if let elapsed = state.elapsed {
                Text("· \(DataFormat.duration(elapsed))").font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
            }
            Spacer()
            IconButton(symbol: "chevron.left", label: "Previous page", size: 11) { update { $0.page -= 1 } }
                .disabled(state.page == 0 || state.loading)
            Text("Page \(state.page + 1)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2.color)
            IconButton(symbol: "chevron.right", label: "Next page", size: 11) { update { $0.page += 1 } }
                .disabled(!hasMore || state.loading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(theme.panel.color)
        .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    private var structure: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Column").frame(width: 220, alignment: .leading)
                    Text("Type").frame(width: 200, alignment: .leading)
                    Text("Null").frame(width: 60, alignment: .leading)
                    Text("Default").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text3.color)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                ForEach(table.columns) { column in
                    HStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Text(column.name).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(theme.text.color)
                            if column.isPrimaryKey { KeyBadge(text: "PK", color: theme.amber.color) }
                            if let target = column.references {
                                KeyBadge(text: "FK", color: theme.accent.color).help("References \(target.table).\(target.column)")
                            }
                        }
                        .frame(width: 220, alignment: .leading)
                        Text(column.type).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.syntax.type.color)
                            .frame(width: 200, alignment: .leading)
                        Text(column.nullable ? "yes" : "no").font(.system(size: 12)).foregroundStyle(column.nullable ? theme.text3.color : theme.text.color)
                            .frame(width: 60, alignment: .leading)
                        Text(column.defaultValue ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2.color)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var relations: some View {
        let outgoing = table.foreignKeys
        let incoming = model.schema?.referencing(table) ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                relationGroup("Points at", empty: "\(table.name) has no foreign keys.", items: outgoing.map { column in
                    (column.name, column.references!.table, column.references!.column)
                })
                relationGroup("Pointed at by", empty: "No table references \(table.name).", items: incoming.map { other, column in
                    (column.name, other.qualifiedName, column.references!.column)
                }, incoming: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func relationGroup(_ title: String, empty: String, items: [(String, String, String)], incoming: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(title)
            if items.isEmpty {
                Text(empty).font(.system(size: 12.5)).foregroundStyle(theme.text3.color)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let (column, other, otherColumn) = item
                Button {
                    if let target = model.schema?.table(other) { model.open(table: target) }
                } label: {
                    HStack(spacing: 8) {
                        Text(incoming ? "\(other).\(column)" : "\(table.name).\(column)").foregroundStyle(theme.text.color)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(theme.text3.color)
                        Text(incoming ? "\(table.name).\(otherColumn)" : "\(other).\(otherColumn)").foregroundStyle(theme.accent.color)
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.card.color))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.line.color))
                }
                .buttonStyle(.plain)
                .help("Open \(other)")
            }
        }
    }
}

struct KeyBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.14)))
    }
}
