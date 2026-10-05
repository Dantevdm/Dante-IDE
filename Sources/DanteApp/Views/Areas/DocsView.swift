import DanteKit
import SwiftUI

/// Docs: the project's markdown as documents to read, not files to edit. An outline on
/// the left, the document in the middle, and what links to it on the right. Paper
/// theme sets it in a serif.
struct DocsView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var markdown: MarkdownDocument?
    @State private var loadError: String?

    private var library: DocLibrary { DocLibrary(paths: workspace.files) }

    private var selected: DocLibrary.Doc? {
        let all = library.all
        if let path = session.docPath, let doc = all.first(where: { $0.path == path }) { return doc }
        return all.first { $0.path.lowercased() == "readme.md" } ?? all.first
    }

    var body: some View {
        HStack(spacing: 0) {
            DocsSidebar(session: session, library: library, selected: selected, markdown: markdown)
                .frame(width: 236)
            Rectangle().fill(theme.line.color).frame(width: 1)
            if let selected {
                VStack(spacing: 0) {
                    toolbar(for: selected)
                    Rectangle().fill(theme.line.color).frame(height: 1)
                    HStack(spacing: 0) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Group {
                                    if let markdown {
                                        DocumentBody(document: markdown, path: selected.path)
                                    } else if let loadError {
                                        Text(loadError).foregroundStyle(theme.red.color)
                                    }
                                }
                                .padding(.horizontal, 44)
                                .padding(.vertical, 40)
                                .frame(maxWidth: 780, alignment: .leading)
                                .frame(maxWidth: .infinity)
                            }
                            .onChange(of: session.docAnchor) { _, anchor in
                                guard let anchor else { return }
                                withAnimation(.snappy) { proxy.scrollTo(anchor, anchor: .top) }
                                session.docAnchor = nil
                            }
                        }
                        Rectangle().fill(theme.line.color).frame(width: 1)
                        LinkedPanel(session: session, workspace: workspace, doc: selected, markdown: markdown)
                            .frame(width: 250)
                    }
                }
                .environment(\.openURL, OpenURLAction { url in open(url, from: selected) })
            } else {
                EmptyState(
                    symbol: "doc.text",
                    title: "No docs yet",
                    message: "Markdown files in the repo show up here: the README, .dante specs and decisions, and anything under docs/."
                ) {
                    Button("Ask Claude to draft a README") {
                        session.askClaude("Draft a README.md for this project from the code, the .dante folder and git history. Keep it short and accurate.")
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(theme.ground.color)
        .task(id: "\(selected?.path ?? "")#\(workspace.revision)") { load() }
    }

    private func toolbar(for doc: DocLibrary.Doc) -> some View {
        HStack(spacing: 8) {
            let parts = doc.path.split(separator: "/").map(String.init)
            Text("Docs").foregroundStyle(theme.text3.color)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.text3.color)
                Text(part).foregroundStyle(index == parts.count - 1 ? theme.text.color : theme.text3.color)
            }
            Spacer()
            Button {
                session.askClaude("Read \(doc.path) and tell me what's out of date or missing compared with the code. Don't change anything yet.")
            } label: {
                Label("Check against the code", systemImage: "sparkle")
            }
            .buttonStyle(DanteButtonStyle())
            Button {
                session.open(file: workspace.url.appending(path: doc.path))
                session.area = .code
            } label: {
                Label("Edit markdown", systemImage: "pencil")
            }
            .buttonStyle(DanteButtonStyle())
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 20)
        .frame(height: 46)
        .background(theme.panel.color)
    }

    private func load() {
        guard let selected else { markdown = nil; return }
        do {
            let text = try String(contentsOf: workspace.url.appending(path: selected.path), encoding: .utf8)
            markdown = MarkdownDocument(text)
            loadError = nil
        } catch {
            markdown = nil
            loadError = "Couldn’t read \(selected.path): \(error.localizedDescription)"
        }
    }

    /// Relative links to other docs open here; files open in the editor; the rest go to the browser.
    private func open(_ url: URL, from doc: DocLibrary.Doc) -> OpenURLAction.Result {
        if url.scheme != nil { return .systemAction }
        let raw = url.relativeString
        if raw.hasPrefix("#") {
            session.docAnchor = String(raw.dropFirst())
            return .handled
        }
        let base = (doc.path as NSString).deletingLastPathComponent
        let target = (((base as NSString).appendingPathComponent(raw.components(separatedBy: "#")[0])) as NSString).standardizingPath
        if library.all.contains(where: { $0.path == target }) {
            session.showDoc(target)
        } else if workspace.files.contains(target) {
            session.open(file: workspace.url.appending(path: target))
            session.area = .code
        }
        return .handled
    }
}

// MARK: Sidebar

private struct DocsSidebar: View {
    @Environment(\.theme) private var theme
    let session: Session
    let library: DocLibrary
    let selected: DocLibrary.Doc?
    let markdown: MarkdownDocument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let outline = markdown?.outline.filter({ $0.level > 1 }), !outline.isEmpty {
                    Eyebrow("On this page").padding(.horizontal, 12)
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(outline, id: \.anchor) { entry in
                            Button { session.docAnchor = entry.anchor } label: {
                                Text(MarkdownText.attributed(entry.text, theme: theme, codeSize: 11.5))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(theme.text2.color)
                                    .lineLimit(1)
                                    .padding(.leading, CGFloat(entry.level - 2) * 12)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Rectangle().fill(theme.line.color).frame(height: 1).padding(.horizontal, 12)
                }
                ForEach(library.groups) { group in
                    VStack(alignment: .leading, spacing: 1) {
                        Eyebrow(group.title).padding(.horizontal, 12).padding(.bottom, 5)
                        ForEach(group.docs) { doc in
                            DocRow(doc: doc, isSelected: doc == selected) { session.showDoc(doc.path) }
                        }
                    }
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 8)
        }
        .background(theme.panel.color)
    }
}

private struct DocRow: View {
    @Environment(\.theme) private var theme
    let doc: DocLibrary.Doc
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(doc.title)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? theme.text.color : theme.text2.color)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? theme.accentTint.color : (hovering ? theme.raised.color : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(doc.path)
    }
}

// MARK: Document

/// The rendered document. Paper sets body text in a serif, as the design does.
private struct DocumentBody: View {
    @Environment(\.theme) private var theme
    let document: MarkdownDocument
    let path: String

    private var serif: Bool { theme.id == .paper }
    private var bodySize: CGFloat { serif ? 17 : 14.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text3.color)
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: serif ? .serif : .default)
    }

    private func inline(_ text: String, size: CGFloat? = nil) -> Text {
        Text(MarkdownText.attributed(text, theme: theme, codeSize: (size ?? bodySize) - 2))
    }

    @ViewBuilder
    private func view(for block: MarkdownDocument.Block) -> some View {
        switch block {
        case .heading(let level, let text, let anchor):
            let size: CGFloat = [serif ? 40 : 30, serif ? 26 : 21, serif ? 21 : 17, 15, 14, 13][min(level, 6) - 1]
            inline(text, size: size)
                .font(font(size, weight: level == 1 ? (serif ? .medium : .semibold) : .semibold))
                .foregroundStyle(theme.text.color)
                .padding(.top, level == 1 ? 0 : 10)
                .id(anchor)
        case .paragraph(let text):
            inline(text)
                .font(font(bodySize))
                .lineSpacing(serif ? 6 : 4)
                .foregroundStyle(theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items, _):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(.system(size: bodySize - 2))
                                .foregroundStyle(checked ? theme.green.color : theme.text3.color)
                        } else if let number = item.number {
                            Text("\(number).").font(font(bodySize)).foregroundStyle(theme.text3.color).monospacedDigit()
                        } else {
                            Text("•").font(font(bodySize)).foregroundStyle(theme.text3.color)
                        }
                        inline(item.text)
                            .font(font(bodySize))
                            .lineSpacing(serif ? 5 : 3)
                            .foregroundStyle(item.checked == true ? theme.text2.color : theme.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case .quote(let text):
            HStack(spacing: 12) {
                Rectangle().fill(theme.line2.color).frame(width: 3)
                inline(text).font(font(bodySize).italic()).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let code, let language) where language?.lowercased() == "mermaid":
            MermaidBlock(source: code)
        case .code(let code, let language):
            CodeBlock(text: code, language: language)
        case .table(let header, let rows):
            DocTable(header: header, rows: rows, inline: { inline($0, size: 13) })
        case .rule:
            Rectangle().fill(theme.line.color).frame(height: 1).padding(.vertical, 6)
        }
    }
}

private struct DocTable: View {
    @Environment(\.theme) private var theme
    let header: [String]
    let rows: [[String]]
    let inline: (String) -> Text

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(cell.uppercased())
                        .font(.system(size: 10.5, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(theme.text3.color)
                        .padding(.bottom, 8)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().overlay(theme.line.color).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        inline(cell)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
    }
}

// MARK: Linked

/// What points at this doc: tasks that use it as their spec, and the project files it
/// mentions in `code`.
private struct LinkedPanel: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let doc: DocLibrary.Doc
    let markdown: MarkdownDocument?

    var body: some View {
        let tasks = workspace.tasks.tasks.filter { task in
            guard let spec = task.spec else { return false }
            return ".dante/" + spec == doc.path || spec == doc.path
        }
        let files = mentionedFiles
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Linked to this doc")
                if tasks.isEmpty, files.isEmpty {
                    Text("No tasks use this doc as their spec, and it doesn’t mention any project files.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text3.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(tasks) { task in
                    note(symbol: "checklist", title: task.id, subtitle: "\(task.title) · \(task.state.title.lowercased())") {
                        session.showPhase(task.phase.capitalized)
                    }
                }
                ForEach(files, id: \.self) { file in
                    note(symbol: "doc.text", title: (file as NSString).lastPathComponent, subtitle: file) {
                        if DocLibrary(paths: [file]).isEmpty {
                            session.open(file: workspace.url.appending(path: file))
                            session.area = .code
                        } else {
                            session.showDoc(file)
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(theme.ground.color)
    }

    /// `path` mentions in the doc that name a real file, as written or relative to the doc.
    private var mentionedFiles: [String] {
        guard let markdown else { return [] }
        let known = Set(workspace.files)
        var found: [String] = []
        let text = markdown.blocks.map { block -> String in
            switch block {
            case .paragraph(let text), .quote(let text), .heading(_, let text, _): text
            case .list(let items, _): items.map(\.text).joined(separator: " ")
            case .table(let header, let rows): (header + rows.flatMap { $0 }).joined(separator: " ")
            case .code, .rule: ""
            }
        }.joined(separator: " ")
        for match in text.matches(of: /`([^`\s]+)`/) {
            let candidate = String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "./")).isEmpty ? "" : String(match.1)
            let paths = [candidate, ".dante/" + candidate, ((doc.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(candidate)]
            if let path = paths.first(where: known.contains), path != doc.path, !found.contains(path) {
                found.append(path)
            }
        }
        return Array(found.prefix(12))
    }

    private func note(symbol: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(theme.text3.color).frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(1)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
