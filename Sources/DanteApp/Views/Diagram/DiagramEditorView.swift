import AppKit
import DanteKit
import SwiftUI

/// A diagram open in Docs: a bar with its name, zoom, export and the agent; the building
/// blocks down the left; the canvas; and the inspector on the right.
struct DiagramEditorView: View {
    @Environment(\.theme) private var theme
    @Environment(\.undoManager) private var undoManager
    let session: Session
    let workspace: Workspace
    let path: String

    @State private var document: DiagramDocument
    @State private var zoom: CGFloat = 1
    @State private var viewCenter = CGPoint(x: 400, y: 300)
    @State private var editing: DiagramCanvas.InlineEdit?
    @State private var scroll = ScrollPosition()
    @State private var viewport: CGSize = .zero
    @State private var fitted = false
    @State private var showsLibrary = false
    @State private var describing: Session.DiagramDrawing?
    @AppStorage("diagramInspector") private var showsInspector = true

    init(session: Session, workspace: Workspace, path: String) {
        self.session = session
        self.workspace = workspace
        self.path = path
        _document = State(initialValue: DiagramDocument(url: workspace.url.appending(path: path), path: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(theme.line.color).frame(height: 1)
            if let error = document.loadError {
                EmptyState(symbol: "exclamationmark.triangle", title: "This diagram can’t be read", message: error) {
                    Button("Open in Code") { session.open(file: document.url) }.buttonStyle(DanteButtonStyle())
                    Button {
                        session.askClaude("Fix \(path) so it's a valid Dante diagram. The error: \(error)", instructions: DiagramGuide.format)
                    } label: { ClaudeLabel("Ask \(session.agentName) to fix it") }
                    .buttonStyle(DanteButtonStyle(primary: true))
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                HStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        canvas
                        DiagramPalette(add: add, addComponent: addComponent, showsLibrary: $showsLibrary)
                            .padding(12)
                        if document.diagram.isEmpty { emptyHint }
                    }
                    if showsInspector {
                        Rectangle().fill(theme.line.color).frame(width: 1)
                        DiagramInspector(document: document) { id in editing = .init(id: id, field: .title) }
                            .frame(width: 272)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
        }
        .background(theme.ground.color)
        .background { shortcuts }
        .onAppear { document.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in document.undoManager = manager }
        .task(id: workspace.revision) { document.reloadIfChanged() }
        .onDisappear { document.save() }
        .alert("Couldn’t save the diagram", isPresented: Binding(get: { document.saveError != nil }, set: { _ in })) {
            Button("OK") {}
        } message: {
            Text(document.saveError ?? "")
        }
    }

    // MARK: The bar

    private var bar: some View {
        HStack(spacing: 8) {
            Button { session.showDoc(DocLibrary.libraryPath) } label: {
                Label("Docs", systemImage: "chevron.left").font(.dante(size: 12.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text3.color)
            .help("Back to the library")
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.dante(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent.color)
            TextField("Title", text: Binding(get: { document.diagram.title }, set: { text in
                document.change("Rename Diagram", coalescing: "diagram-title") { $0.title = text }
            }))
            .textFieldStyle(.plain)
            .font(.dante(size: 14, weight: .semibold))
            .foregroundStyle(theme.text.color)
            .frame(minWidth: 120, maxWidth: 320)
            .fixedSize(horizontal: true, vertical: false)
            Text(document.isSaved ? "Saved" : "Saving…")
                .font(.dante(size: 11))
                .foregroundStyle(theme.text3.color)
                .help(path)
            Spacer(minLength: 8)
            zoomControls
            Menu {
                ForEach(DiagramExporter.Format.allCases) { format in
                    Button("\(format.rawValue)…") { export(format) }
                }
                Divider()
                Button("Copy as Image") { DiagramExporter.copyImage(document.diagram, theme: theme) }
                Button("Copy Mermaid") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.diagram.mermaid(), forType: .string)
                }
                Divider()
                Button("Show the File in Code") { session.open(file: document.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Save it as PNG, PDF, SVG or Mermaid, in the theme you're using")
            Menu {
                Button(document.diagram.isEmpty ? "Draw from a description…" : "Describe a change…") { describing = document.diagram.isEmpty ? .draw : .change }
                Button("Draw a future version of this…") { describing = .future }
                Divider()
                Button("Review it against the code") { ask(.review) }
                Button("Tidy the layout") { ask(.tidy) }
                Button("Explain it in a paragraph") { ask(.explain) }
            } label: {
                ClaudeLabel("Ask \(session.agentName)")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("The agent edits the diagram's file; you see each change here and can undo it")
            .popover(item: $describing, arrowEdge: .bottom) { drawing in
                VStack(alignment: .leading, spacing: 10) {
                    Text(drawing == .future ? "A future version" : drawing == .change ? "Change it" : "Draw it")
                        .font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
                    DiagramDescriptionField(
                        placeholder: drawing == .future ? "What changes? e.g. move the catalogue to its own ALB, add a Redis cache (planned)…"
                            : drawing == .change ? "What to change, in your words…" : "What should it show, in your words…",
                        button: drawing == .future ? "Draw the future version" : "Draw it") { words in
                        describing = nil
                        document.save()
                        session.drawDiagram(path, description: words, as: drawing)
                    }
                }
                .padding(16)
                .frame(width: 400)
                .background(theme.panel.color)
            }
            IconButton(symbol: "sidebar.right", label: showsInspector ? "Hide the inspector" : "Show the inspector") {
                withAnimation(.snappy(duration: 0.2)) { showsInspector.toggle() }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(theme.panel.color)
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "minus.magnifyingglass", label: "Zoom out", size: 12) { setZoom(zoom / 1.25) }
            Button { setZoom(1) } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.dante(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.text2.color)
                    .frame(width: 44)
            }
            .buttonStyle(.plain)
            .help("Actual size")
            IconButton(symbol: "plus.magnifyingglass", label: "Zoom in", size: 12) { setZoom(zoom * 1.25) }
            IconButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", label: "Zoom to fit", size: 12) { fit() }
        }
    }

    // MARK: The canvas

    private var canvas: some View {
        DiagramCanvas(document: document, zoom: $zoom, viewCenter: $viewCenter, editing: $editing, scroll: $scroll, viewport: $viewport)
            .onChange(of: viewport) { _, size in
                guard !fitted, size.width > 100 else { return }
                fitted = true
                let bounds = document.diagram.bounds
                if !bounds.isNull, bounds.maxX + DiagramCanvas.paletteRoom + 24 > size.width || bounds.maxY + 40 > size.height { fit() }
            }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.dante(size: 28))
                .foregroundStyle(theme.accent.color)
            Text("An empty canvas").font(.dante(size: 16, weight: .semibold)).foregroundStyle(theme.text.color)
            Text("Describe what to draw and \(session.agentName) draws it here. Or add cards from the bar on the left, or copy the Map (Copy and edit).")
                .font(.dante(size: 12.5))
                .foregroundStyle(theme.text2.color)
                .multilineTextAlignment(.center)
            DiagramDescriptionField(placeholder: "What should it show? e.g. users sign in through Cognito, one shared ALB routes to the four ECS apps, each with its own database…",
                                    button: "Draw it") { words in
                document.save()
                session.drawDiagram(path, description: words, as: .draw)
            }
            LinkButton("Open the Map") { session.area = .map }
        }
        .frame(maxWidth: 400)
        .padding(24)
        .background(theme.card.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line.color))
        .padding(.leading, DiagramCanvas.paletteRoom)
        .padding(.trailing, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// ⌘D, ⌘G and ⇧⌘G while the diagram is in front.
    private var shortcuts: some View {
        ZStack {
            Button("Duplicate") {
                var copies: Set<String> = []
                let ids = document.selection.filter { document.diagram.node($0) != nil }
                guard !ids.isEmpty else { return }
                document.change("Duplicate") { copies = $0.duplicate(ids) }
                document.selection = copies
            }
            .keyboardShortcut("d")
            Button("Group") {
                let ids = document.selection.filter { document.diagram.node($0) != nil }
                guard !ids.isEmpty else { return }
                var group: String?
                document.change("Group") { group = $0.group(ids) }
                if let group { document.selection = [group] }
            }
            .keyboardShortcut("g")
            Button("Ungroup") {
                let ids = document.selection.filter { document.diagram.node($0)?.kind.isContainer == true }
                guard !ids.isEmpty else { return }
                document.change("Ungroup") { diagram in for id in ids { diagram.ungroup(id) } }
                document.selection = []
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func add(_ kind: Diagram.Node.Kind) {
        var id: String?
        document.change("Add \(kind.name)") { id = $0.add(kind, at: viewCenter, findsRoom: true) }
        if let id {
            document.selection = [id]
            if kind != .text { editing = .init(id: id, field: .title) }
        }
    }

    private func addComponent(_ component: DiagramLibrary.Component) {
        var id: String?
        document.change("Add \(component.title)") { diagram in
            id = diagram.add(.card, title: component.title, at: viewCenter, findsRoom: true) { node in
                node.icon = component.icon
                node.hue = component.hue
                node.subtitle = component.title
            }
        }
        if let id {
            document.selection = [id]
            editing = .init(id: id, field: .title)
        }
    }

    private func setZoom(_ value: CGFloat) {
        let center = viewCenter
        let new = min(2.5, max(0.25, value))
        zoom = new
        // Keep the middle where it was.
        scroll.scrollTo(point: CGPoint(x: max(0, center.x * new - viewport.width / 2), y: max(0, center.y * new - viewport.height / 2)))
    }

    private func fit() {
        let bounds = document.diagram.bounds
        guard !bounds.isNull, viewport.width > 0 else { return setZoom(1) }
        let scale = min((viewport.width - DiagramCanvas.paletteRoom - 48) / bounds.width, (viewport.height - 48) / bounds.height)
        zoom = min(1.5, max(0.25, scale))
        scroll.scrollTo(point: CGPoint(x: max(0, (bounds.minX - 24) * zoom), y: max(0, (bounds.minY - 24) * zoom)))
    }

    private func export(_ format: DiagramExporter.Format) {
        document.save()
        if let error = DiagramExporter.export(format, document.diagram, from: document.url, theme: theme) {
            session.errorMessage = error
        }
    }

    private enum Request { case review, tidy, explain }

    private func ask(_ request: Request) {
        document.save()
        let file = path
        let guide = "\n\n" + DiagramGuide.format
        switch request {
        case .review:
            session.askClaude("Review \(file) against the code", instructions: "Compare the diagram in \(file) with the code and infrastructure in this repo. Tell me what it gets wrong, leaves out or shows that isn't there. Don't change the file yet." + guide)
        case .tidy:
            session.askClaude("Tidy the layout of \(file)", instructions: "Tidy the layout of the diagram in \(file): line up rows and columns, even out the gaps, keep cards inside their groups and links short, without changing what's in it. Edit the file in place." + guide)
        case .explain:
            session.askClaude("Explain the diagram in \(file) in a paragraph I could say while presenting it: what's there, how a request travels through it and what's new or planned (dashed).")
        }
    }
}

/// The building blocks, down the left of the canvas, and the library of ready-made cards.
private struct DiagramPalette: View {
    @Environment(\.theme) private var theme
    let add: (Diagram.Node.Kind) -> Void
    let addComponent: (DiagramLibrary.Component) -> Void
    @Binding var showsLibrary: Bool

    private static let kinds: [(Diagram.Node.Kind, String, String)] = [
        (.card, "rectangle.inset.topleft.filled", "Card: a resource with an icon, a kind and a detail line"),
        (.box, "rectangle.lefthalf.inset.filled", "Part: a box with a coloured stripe, as on the System map"),
        (.group, "square.stack.3d.up", "Group: a titled box that counts what's in it"),
        (.boundary, "cloud", "Boundary: a dashed frame with a title, like AWS cloud"),
        (.person, "person.2.fill", "People"),
        (.stage, "paperplane", "Pipeline stage"),
        (.source, "chevron.left.forwardslash.chevron.right", "Pipeline start: repo, branches and environment"),
        (.title, "textformat.size", "Band title"),
        (.text, "text.alignleft", "Text"),
    ]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Self.kinds, id: \.0) { kind, symbol, help in
                IconButton(symbol: symbol, label: "Add \(help)", size: 13) { add(kind) }
                if kind == .boundary || kind == .source { divider }
            }
            divider
            IconButton(symbol: "books.vertical", label: "Library: ready-made cards for cloud resources and apps", size: 13) { showsLibrary.toggle() }
                .popover(isPresented: $showsLibrary, arrowEdge: .trailing) {
                    ComponentLibrary { component in
                        addComponent(component)
                        showsLibrary = false
                    }
                }
        }
        .padding(4)
        .background(theme.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
        .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.08), radius: 8, y: 2)
    }

    private var divider: some View {
        Rectangle().fill(theme.line.color).frame(width: 18, height: 1).padding(.vertical, 3)
    }
}

/// Ready-made cards by section, with a filter.
private struct ComponentLibrary: View {
    @Environment(\.theme) private var theme
    let pick: (DiagramLibrary.Component) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Filter: load balancer, queue, sign-in…", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.dante(size: 12.5))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(DiagramLibrary.sections, id: \.self) { section in
                        let items = DiagramLibrary.components.filter { $0.section == section && matches($0) }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Eyebrow(section)
                                ForEach(items) { item in row(item) }
                            }
                        }
                    }
                }
            }
            .frame(height: 340)
        }
        .padding(14)
        .frame(width: 280)
        .background(theme.panel.color)
    }

    private func matches(_ component: DiagramLibrary.Component) -> Bool {
        let words = query.lowercased().split(separator: " ")
        return words.allSatisfy { component.title.lowercased().contains($0) || component.section.lowercased().contains($0) }
    }

    private func row(_ component: DiagramLibrary.Component) -> some View {
        let hue = component.hue.rgba(theme).color
        return Button { pick(component) } label: {
            HStack(spacing: 9) {
                Image(systemName: component.icon)
                    .font(.dante(size: 11.5, weight: .medium))
                    .foregroundStyle(hue)
                    .frame(width: 24, height: 24)
                    .background(hue.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(component.title).font(.dante(size: 12.5)).foregroundStyle(theme.text.color)
                Spacer()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
