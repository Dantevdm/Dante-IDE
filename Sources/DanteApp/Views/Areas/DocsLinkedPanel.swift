import DanteEditor
import DanteKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// What points at this doc: tasks that use it as their spec, and the project files it
/// mentions in `code`.
struct LinkedPanel: View {
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
                if let outline = markdown?.outline.filter({ $0.level > 1 }), !outline.isEmpty {
                    Eyebrow("On this page")
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(outline, id: \.anchor) { entry in
                            Button { session.docAnchor = entry.anchor } label: {
                                Text(MarkdownText.attributed(entry.text, theme: theme, codeSize: 11.5))
                                    .font(.dante(size: 12.5))
                                    .foregroundStyle(entry.level == 2 ? theme.text2.color : theme.text3.color)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .padding(.leading, CGFloat(entry.level - 2) * 12)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(entry.text)
                        }
                    }
                    Rectangle().fill(theme.line.color).frame(height: 1).padding(.vertical, 6)
                }
                Eyebrow("Linked to this doc")
                if tasks.isEmpty, files.isEmpty {
                    Text("No tasks use this doc as their spec, and it doesn’t mention any project files.")
                        .font(.dante(size: 12))
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
            case .code, .rule, .image: ""
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
                Image(systemName: symbol).font(.dante(size: 12)).foregroundStyle(theme.text3.color).frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(1)
                    Text(subtitle).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(2)
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
