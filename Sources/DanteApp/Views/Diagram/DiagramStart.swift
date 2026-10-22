import DanteKit
import SwiftUI

extension Session {
    /// Saves a new diagram into docs/diagrams/ and opens it in Docs.
    func createDiagram(_ diagram: Diagram) {
        guard let workspace else { return }
        do {
            let path = try DiagramDocument.create(diagram, in: workspace)
            showDoc(path)
        } catch {
            errorMessage = "Couldn’t create the diagram: \(error.localizedDescription)"
        }
    }

    /// A new diagram from the Map's last build for this window, or read from the project's files
    /// when the Map hasn't been opened yet.
    func createDiagram(from start: NewDiagramSheet.Start, title: String) {
        let cached: Diagram? = switch start {
        case .blank: Diagram(title: title)
        case .system: mapCache?.system.flatMap { $0.isUseful ? Diagram.system($0, title: title) : nil }
        case .infra: mapCache?.infra.flatMap { $0.isEmpty ? nil : Diagram.infrastructure($0, title: title) }
        }
        if let cached { return createDiagram(cached) }
        guard let root = workspace?.url else { return }
        let system = start == .system
        Task {
            let found = await Task.detached { Diagram.fromProject(root, system: system, title: title) }.value
            if let found { createDiagram(found) } else {
                errorMessage = system ? "Dante found no system map in this project's code." : "Dante found no pipelines or infrastructure templates in this project."
            }
        }
    }
}

/// The Map's "Copy and edit": what's on screen, with the same positions, as a diagram of your own.
struct CopyAndEditButton: View {
    let session: Session
    let suggestedTitle: String
    let make: (String) -> Diagram
    @State private var asking = false

    var body: some View {
        Button { asking = true } label: {
            Label("Copy and edit", systemImage: "square.on.square.dashed")
        }
        .buttonStyle(DanteButtonStyle())
        .fixedSize()
        .help("Make this picture into a diagram of your own, in Docs: move, add and relabel anything, then export it")
        .popover(isPresented: $asking, arrowEdge: .bottom) {
            // Its own view and state: a popover doesn't follow state kept by the view that shows it.
            CopyAndEditForm(title: suggestedTitle) { name in
                asking = false
                session.createDiagram(make(name))
            } cancel: {
                asking = false
            }
        }
    }
}

private struct CopyAndEditForm: View {
    @Environment(\.theme) private var theme
    @State var title: String
    let create: (String) -> Void
    let cancel: () -> Void

    private var name: String { title.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Copy as a diagram").font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
            Text("Saved in docs/diagrams/ and opened in Docs. The Map stays as the code has it.")
                .font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.dante(size: 13))
                .onSubmit { if !name.isEmpty { create(name) } }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Copy and edit") { create(name) }.buttonStyle(DanteButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(theme.panel.color)
    }
}

/// New diagram: a name, and whether to start blank or from the Map.
struct NewDiagramSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @State private var title = "Target architecture"
    @State private var start: Start = .blank

    enum Start: String, CaseIterable, Identifiable {
        case blank, infra, system
        var id: String { rawValue }

        var title: String {
            switch self {
            case .blank: "Blank"
            case .infra: "Infrastructure"
            case .system: "System map"
            }
        }

        var detail: String {
            switch self {
            case .blank: "An empty canvas"
            case .infra: "The Map's Infra view: pipelines, the cloud and its tiers"
            case .system: "The Map's System view: clients, API, backend, data"
            }
        }

        var symbol: String {
            switch self {
            case .blank: "square.dashed"
            case .infra: "cloud"
            case .system: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    private func available(_ start: Start) -> Bool {
        switch start {
        case .blank: true
        // Before the Map is built it's read from the project on Create.
        case .infra: session.mapCache.map { $0.infra.map { !$0.isEmpty } ?? false } ?? true
        case .system: session.mapCache.map { $0.system?.isUseful ?? false } ?? true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New diagram").font(.dante(size: 17, weight: .semibold)).foregroundStyle(theme.text.color)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                TextField("Name", text: $title).textFieldStyle(.roundedBorder).font(.dante(size: 13))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Start from").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                HStack(spacing: 8) {
                    ForEach(Start.allCases) { option in
                        let enabled = available(option)
                        Button { start = option } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: option.symbol).font(.dante(size: 16)).foregroundStyle(theme.accent.color)
                                Text(option.title).font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color)
                                Text(enabled ? option.detail : "Nothing like it in this project")
                                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .frame(width: 150, height: 112, alignment: .topLeading)
                            .background(start == option ? theme.accentTint.color : theme.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(start == option ? theme.accent.color : theme.line2.color, lineWidth: start == option ? 1.5 : 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .opacity(enabled ? 1 : 0.5)
                    }
                }
            }
            Text("Saved as docs/diagrams/\(Diagram.slug(title).isEmpty ? "diagram" : Diagram.slug(title)).dante-diagram.json, so it's reviewed in git like any doc.")
                .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Create") {
                    let name = title.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    session.createDiagram(from: start, title: name)
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(theme.panel.color)
    }
}

/// Docs' strip of what was made in Dante: each diagram as a thumbnail and each motion piece,
/// shown only when there are some.
struct MadeInDante: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let diagrams: [DocLibrary.Doc]
    let pieces: [DocLibrary.Doc]
    @State private var pictures: [String: Diagram] = [:]

    var body: some View {
        if !diagrams.isEmpty || !pieces.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Diagrams and motion")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(diagrams) { doc in
                            thumbnail(doc, title: pictures[doc.path]?.title ?? doc.title, symbol: "point.3.filled.connected.trianglepath.dotted") {
                                if let picture = pictures[doc.path], !picture.isEmpty {
                                    let still = DiagramStill(diagram: picture, padding: 20)
                                    let frame = still.frame
                                    let scale = min(180 / frame.width, 100 / frame.height)
                                    still.scaleEffect(scale)
                                        .frame(width: frame.width * scale, height: frame.height * scale)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                        ForEach(pieces) { doc in
                            thumbnail(doc, title: doc.title, symbol: "film.stack") {
                                Image(systemName: "play.rectangle").font(.dante(size: 26, weight: .light)).foregroundStyle(theme.accent.color)
                            }
                        }
                    }
                }
            }
            .task(id: workspace.revision) { load() }
        }
    }

    private func thumbnail(_ doc: DocLibrary.Doc, title: String, symbol: String, @ViewBuilder picture: () -> some View) -> some View {
        Button { session.showDoc(doc.path) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    theme.panel.color
                    picture()
                }
                .frame(width: 180, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line.color))
                Label(title, systemImage: symbol)
                    .font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(1)
            }
            .frame(width: 180)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(doc.path)
    }

    private func load() {
        var found: [String: Diagram] = [:]
        for doc in diagrams.prefix(24) {
            guard let data = try? Data(contentsOf: workspace.url.appending(path: doc.path)), var diagram = try? Diagram.decode(data) else { continue }
            if diagram.nodes.contains(where: { $0.frame == nil }) { diagram.settle() }
            found[doc.path] = diagram
        }
        pictures = found
    }
}
