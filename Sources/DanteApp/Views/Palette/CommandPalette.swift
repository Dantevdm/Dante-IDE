import DanteKit
import SwiftUI

/// ⌘K: search files, docs and actions, or hand the query to Claude.
struct CommandPalette: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore
    let session: Session
    let workspace: Workspace

    @State private var query = ""
    @State private var scope: PaletteScope
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    init(session: Session, workspace: Workspace, scope: PaletteScope) {
        self.session = session
        self.workspace = workspace
        _scope = State(initialValue: scope)
    }

    var body: some View {
        let sections = self.sections
        let rows = sections.flatMap(\.rows)

        VStack(spacing: 0) {
            searchField(rows: rows)
            scopeBar
            Rectangle().fill(theme.line.color).frame(height: 1)
            results(sections, rows: rows)
            Rectangle().fill(theme.line.color).frame(height: 1)
            footer
        }
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line2.color))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: theme.scrim.color, radius: 30, y: 16)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { selection = defaultSelection }
        .onChange(of: scope) { selection = defaultSelection; fieldFocused = true }
        .onExitCommand { close() }
    }

    // MARK: Pieces

    private func searchField(rows: [PaletteRow]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(theme.text3.color)
            TextField(scope == .files ? "Open a file…" : "Search or ask Claude…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(theme.text.color)
                .focused($fieldFocused)
                .onSubmit { run(rows[safe: selection]) }
                .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
                .onKeyPress(.tab) {
                    askClaude()
                    return .handled
                }
            Text("esc").font(.system(size: 11)).foregroundStyle(theme.text3.color)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var scopeBar: some View {
        HStack(spacing: 4) {
            ForEach(PaletteScope.allCases) { option in
                Button(option.rawValue) { scope = option }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: scope == option ? .semibold : .regular))
                    .foregroundStyle(scope == option ? theme.accent.color : theme.text2.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(scope == option ? theme.accentTint.color : .clear))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func results(_ sections: [PaletteSection], rows: [PaletteRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty {
                        Text(workspace.files.isEmpty && scope != .actions ? "Indexing files…" : "No matches")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.text3.color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }
                    ForEach(sections) { section in
                        Text(section.title.uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(theme.text3.color)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(section.rows) { row in
                            let index = rows.firstIndex { $0.id == row.id } ?? 0
                            PaletteRowView(row: row, isSelected: index == selection)
                                .id(row.id)
                                .onTapGesture { run(row) }
                                .onHover { if $0 { selection = index } }
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: 380)
            .onChange(of: selection) {
                if let row = rows[safe: selection] { proxy.scrollTo(row.id) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "move")
            hint("↵", "open")
            if session.claude != nil { hint("tab", "ask Claude instead") }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.text2.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.raised.color))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.line.color))
            Text(label).font(.system(size: 11)).foregroundStyle(theme.text3.color)
        }
    }

    // MARK: Behaviour

    private func move(_ offset: Int, in rows: [PaletteRow]) {
        guard !rows.isEmpty else { return }
        selection = (selection + offset + rows.count) % rows.count
    }

    private func run(_ row: PaletteRow?) {
        guard let row else { return }
        close()
        row.perform()
    }

    private func askClaude() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, session.claude != nil else { return }
        close()
        session.askClaude(text)
    }

    /// ↵ opens the best result; asking Claude is Tab, so skip its row when there's anything else.
    private var defaultSelection: Int {
        let rows = sections.flatMap(\.rows)
        return rows.first?.id == "ask" && rows.count > 1 ? 1 : 0
    }

    private func close() {
        session.palette = nil
    }

    // MARK: Results

    private var sections: [PaletteSection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var sections: [PaletteSection] = []

        if scope == .all, !trimmed.isEmpty, let claude = session.claude, claude.state != .working {
            sections.append(PaletteSection(title: "Ask Claude", rows: [
                PaletteRow(
                    id: "ask",
                    symbol: "sparkle",
                    title: AttributedString("Ask: “\(trimmed)”"),
                    detail: AttributedString("Claude sees the open file and the current phase"),
                    trailing: "tab"
                ) { [session] in session.askClaude(trimmed) },
            ]))
        }

        if scope != .actions {
            if trimmed.isEmpty, scope != .docs {
                let open = workspace.documents.reversed().map { fileRow(path: ProposedChange.relativePath(of: $0.url, in: workspace.url), match: nil) }
                if !open.isEmpty { sections.append(PaletteSection(title: "Open files", rows: open)) }
            } else {
                let candidates = scope == .docs ? workspace.files.filter(Self.isDoc) : workspace.files
                let limit = scope == .all ? 8 : 40
                let ranked = FuzzyMatch.rank(trimmed, in: candidates, limit: limit)
                if !ranked.isEmpty {
                    sections.append(PaletteSection(
                        title: scope == .docs ? "Docs" : "Files",
                        rows: ranked.map { fileRow(path: $0.path, match: $0.result) }
                    ))
                }
            }
        }

        if scope == .all || scope == .actions {
            let actions = self.actions
            let matched: [PaletteRow] = trimmed.isEmpty
                ? (scope == .actions ? actions : [])
                : FuzzyMatch.rank(trimmed, in: actions.map { String($0.title.characters) }, limit: scope == .all ? 5 : 30)
                    .compactMap { result in actions.first { String($0.title.characters) == result.path } }
            if !matched.isEmpty { sections.append(PaletteSection(title: "Actions", rows: matched)) }
        }
        return sections
    }

    static func isDoc(_ path: String) -> Bool {
        path.hasPrefix(".dante/") || ["md", "markdown", "txt", "rst", "adoc"].contains((path as NSString).pathExtension.lowercased())
    }

    private func fileRow(path: String, match: FuzzyMatch.Result?) -> PaletteRow {
        let nameStart = (path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 }) ?? 0
        let matched = Set(match?.indices ?? [])
        let name = highlighted(path, range: nameStart..<path.count, matched: matched)
        let folder = nameStart > 0 ? highlighted(path, range: 0..<(nameStart - 1), matched: matched) : AttributedString("")
        let url = workspace.url.appending(path: path)
        return PaletteRow(
            id: "file:\(path)",
            symbol: FileIcon.symbol(for: url, isDirectory: false),
            title: name,
            detail: folder,
            trailing: nil
        ) { [session] in session.open(file: url) }
    }

    private func highlighted(_ text: String, range: Range<Int>, matched: Set<Int>) -> AttributedString {
        let characters = Array(text)
        var result = AttributedString()
        for offset in range {
            var piece = AttributedString(String(characters[offset]))
            if matched.contains(offset) {
                piece.foregroundColor = theme.accent.color
                piece.font = .system(size: 13, weight: .semibold)
            }
            result += piece
        }
        return result
    }

    private var actions: [PaletteRow] {
        func action(_ title: String, _ symbol: String, _ shortcut: String? = nil, _ perform: @escaping @MainActor () -> Void) -> PaletteRow {
            PaletteRow(id: "action:\(title)", symbol: symbol, title: AttributedString(title), detail: nil, trailing: shortcut, perform: perform)
        }
        var list = [
            action(session.showsTerminal ? "Hide terminal" : "Show terminal", "terminal", "⌃`") { session.showsTerminal.toggle() },
            action(session.showsClaude ? "Hide Claude" : "Show Claude", "sparkle", "⌥⌘L") { session.showsClaude.toggle() },
            action("Save all", "square.and.arrow.down.on.square", "⌥⌘S") { session.saveAll() },
            action("Open folder…", "folder", "⌘O") { session.openFolderPanel() },
            action("Clone repository…", "arrow.down.circle") { session.isCloning = true },
            action("Close project", "xmark.square") { session.closeProject() },
            action("Reveal project in Finder", "finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.url]) },
        ]
        for id in ThemeID.allCases where id != themeStore.id {
            list.append(action("Theme: \(id.displayName)", id == .dark ? "moon" : (id == .light ? "sun.max" : "book"), nil) { themeStore.id = id })
        }
        if let claude = session.claude, !claude.items.isEmpty {
            list.append(action("New Claude conversation", "square.and.pencil") { claude.reset() })
        }
        for area in Area.allCases where area != session.area {
            list.append(action("Go to \(area.title)", area.symbol) { session.area = area })
        }
        return list
    }
}

struct PaletteSection: Identifiable {
    var id: String { title }
    let title: String
    let rows: [PaletteRow]
}

struct PaletteRow: Identifiable {
    let id: String
    let symbol: String
    let title: AttributedString
    let detail: AttributedString?
    let trailing: String?
    let perform: @MainActor () -> Void
}

private struct PaletteRowView: View {
    @Environment(\.theme) private var theme
    let row: PaletteRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.system(size: 12.5))
                .foregroundStyle(isSelected ? theme.accent.color : theme.text3.color)
                .frame(width: 18)
            Text(row.title)
                .font(.system(size: 13))
                .foregroundStyle(theme.text.color)
                .lineLimit(1)
            if let detail = row.detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.text3.color)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let trailing = row.trailing {
                Text(trailing).font(.system(size: 11)).foregroundStyle(theme.text3.color)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? theme.accentTint.color : .clear))
        .contentShape(Rectangle())
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
