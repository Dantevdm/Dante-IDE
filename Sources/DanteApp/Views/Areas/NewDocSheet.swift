import DanteKit
import SwiftUI

/// What Docs can start: a document from a template, a diagram or a motion piece.
enum DocCreation: Identifiable, Hashable {
    case doc(DocTemplate?)
    case diagram
    case motion

    var id: String {
        switch self {
        case .doc(let template): "doc:" + (template?.rawValue ?? "")
        case .diagram: "diagram"
        case .motion: "motion"
        }
    }

    /// Every kind, in the order the create bar and the sheet show them.
    static let all: [DocCreation] = DocTemplate.allCases.map { .doc($0) } + [.diagram, .motion]

    var title: String {
        switch self {
        case .doc(let template): template?.title ?? "Document"
        case .diagram: "Diagram"
        case .motion: "Video or deck"
        }
    }

    /// The create bar's label.
    var shortTitle: String {
        switch self {
        case .doc(.decision): "Decision"
        case .doc(.howTo): "How-to"
        case .doc(.architecture): "Architecture"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .doc(let template): template?.symbol ?? "doc.text"
        case .diagram: "point.3.filled.connected.trianglepath.dotted"
        case .motion: "film.stack"
        }
    }

    var summary: String {
        switch self {
        case .doc(let template): template?.summary ?? ""
        case .diagram: "In the Map's style, or copied from it"
        case .motion: "A video, deck or explainer"
        }
    }
}

extension Session {
    /// Asked by the New sheet: opens the doc it made in Side by Side, for writing.
    func createDoc(_ template: DocTemplate, title: String, folder: String, drafts: Bool, about: String) {
        guard let workspace else { return }
        let existing = workspace.files
        guard let path = template.path(title: title, folder: folder, existing: existing) else {
            errorMessage = "\(folder.isEmpty ? "The project" : folder) already has a README."
            return
        }
        // A decision's heading carries the number its file was given (`0008-…`).
        let number = template == .decision ? Int((path as NSString).lastPathComponent.prefix { $0.isNumber }) : nil
        let text = template.body(title: title, project: workspace.name, folder: folder, number: number)
        let url = workspace.url.appending(path: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            errorMessage = "Couldn’t create \(path): \(error.localizedDescription)"
            return
        }
        workspace.refreshFileIndex()
        docOpensEditing = !drafts
        showDoc(path)
        if drafts { askClaude(template.draftRequest(path: path, title: title, about: about)) }
    }
}

/// New document: the kind, its name and folder, and whether the agent drafts it from the code.
struct NewDocSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session
    let workspace: Workspace
    let library: DocLibrary
    /// Diagrams and motion pieces have sheets of their own.
    let switchTo: (DocCreation) -> Void
    @State var template: DocTemplate
    @State private var title = ""
    @State private var folder = ""
    @State private var about = ""
    @AppStorage("docsDraftWithAgent") private var drafts = false

    private var name: String { title.trimmingCharacters(in: .whitespaces) }
    private var folders: [String] { DocTemplate.folders(for: template, library: library, existing: workspace.files) }
    private var path: String? { template.path(title: template.asksForTitle ? name : "README", folder: folder, existing: workspace.files) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New document").font(.dante(size: 17, weight: .semibold)).foregroundStyle(theme.text.color)
            kinds
            fields
            Toggle(isOn: $drafts) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Draft it with \(session.agentName) from the code").font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                    Text(drafts ? "\(session.agentName) fills in the outline from the code, configuration and history; you review it."
                                : "You get the outline to fill in yourself, open for editing.")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            HStack {
                if let path {
                    Label(path, systemImage: "doc.badge.plus").font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                        .lineLimit(1).truncationMode(.head)
                } else {
                    Label("\(folder.isEmpty ? "The project" : folder) already has a README", systemImage: "exclamationmark.circle")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.amber.color)
                }
                Spacer(minLength: 12)
                Button("Cancel") { dismiss() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
                Button(drafts ? "Create and draft" : "Create", action: create)
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(path == nil || (template.asksForTitle && name.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 600)
        .background(theme.panel.color)
        .onAppear { choose(template) }
    }

    private var kinds: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(DocCreation.all) { kind in
                let chosen = kind == .doc(template)
                Button {
                    switch kind {
                    case .doc(let picked): if let picked { choose(picked) }
                    default: switchTo(kind)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Image(systemName: kind.symbol).font(.dante(size: 15)).foregroundStyle(theme.accent.color).frame(height: 18)
                        Text(kind.shortTitle).font(.dante(size: 12, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                        Text(kind.summary).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                    .background(chosen ? theme.accentTint.color : theme.card.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(chosen ? theme.accent.color : theme.line2.color, lineWidth: chosen ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            if template.asksForTitle {
                GridRow {
                    label("Title")
                    TextField(template.suggestedTitle, text: $title).textFieldStyle(.roundedBorder).font(.dante(size: 13))
                }
            }
            GridRow {
                label("Save in")
                Picker("", selection: $folder) {
                    ForEach(folders, id: \.self) { folder in
                        Text(folder.isEmpty ? "\(workspace.name) (the project folder)" : folder).tag(folder)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            if drafts {
                GridRow {
                    label("About")
                    TextField("Optional: what it should cover, for \(session.agentName)", text: $about, axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.dante(size: 13)).lineLimit(2...4)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.dante(size: 12)).foregroundStyle(theme.text3.color).gridColumnAlignment(.trailing)
    }

    private func choose(_ picked: DocTemplate) {
        // A typed title stays; the suggestion follows the kind.
        if title.isEmpty || DocTemplate.allCases.contains(where: { $0.suggestedTitle == title }) { title = picked.suggestedTitle }
        if title == DocTemplate.document.suggestedTitle { title = "" }
        template = picked
        folder = picked.defaultFolder(existing: workspace.files)
    }

    private func create() {
        guard path != nil else { return }
        dismiss()
        session.createDoc(template, title: template.asksForTitle ? name : "README", folder: folder, drafts: drafts, about: about)
    }
}
