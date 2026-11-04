import AppKit
import DanteEditor
import DanteKit
import SwiftUI

/// A mind map open in Docs (an `.xmind` file): a bar with its sheets, the topic tools,
/// export and the agent; the map, laid out round its central topic with a colour per main
/// branch; and the chosen topic's notes, labels and link on the right.
///
/// Keys on the map: Tab adds a subtopic, Return a topic after this one, Space or a
/// double-click renames, Delete removes, the arrows move between topics (← and → follow the
/// branch on either side), ⌥↑ and ⌥↓ move a topic among its siblings, and . folds.
struct MindMapEditorView: View {
    @Environment(\.theme) private var theme
    @Environment(\.undoManager) private var undoManager
    let session: Session
    let workspace: Workspace
    let path: String

    @State private var document: MindMapDocument
    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var focus: Field?
    @AppStorage("mindMapInspector") private var showsInspector = true

    enum Field: Hashable { case map, title }

    init(session: Session, workspace: Workspace, path: String) {
        self.session = session
        self.workspace = workspace
        self.path = path
        _document = State(initialValue: MindMapDocument(url: workspace.url.appending(path: path), path: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(theme.line.color).frame(height: 1)
            if let error = document.loadError {
                EmptyState(symbol: "exclamationmark.triangle", title: "This mind map can’t be read", message: error) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
                        .buttonStyle(DanteButtonStyle())
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                HStack(spacing: 0) {
                    canvas
                    if showsInspector {
                        Rectangle().fill(theme.line.color).frame(width: 1)
                        MindMapInspector(document: document)
                            .frame(width: 260)
                    }
                }
            }
        }
        .background(theme.ground.color)
        .onAppear {
            document.undoManager = undoManager
            focus = .map
        }
        .onChange(of: undoManager) { _, manager in document.undoManager = manager }
        .task(id: workspace.revision) { document.reloadIfChanged() }
        .onDisappear { commitEdit(); document.save() }
    }

    // MARK: The bar

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(theme.accent.color)
            Text(MindMap.title(ofPath: path))
                .font(.dante(size: 13, weight: .semibold))
                .foregroundStyle(theme.text.color)
                .lineLimit(1)
            if document.map.sheets.count > 1 {
                Picker("Sheet", selection: Binding(get: { document.sheet }, set: { commitEdit(); document.sheet = $0; document.selected = document.root.id })) {
                    ForEach(Array(document.map.sheets.enumerated()), id: \.offset) { index, sheet in
                        Text(sheet.title).tag(index)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text(document.saveError ?? (document.isSaved ? "Saved" : "Saving…"))
                .font(.dante(size: 11))
                .foregroundStyle(document.saveError == nil ? theme.text3.color : theme.red.color)
            Spacer(minLength: 8)
            IconButton(symbol: "arrow.turn.down.right", label: "Add a subtopic (Tab)") { startEditing(document.addChild()) }
            IconButton(symbol: "plus.rectangle", label: "Add a topic after this one (Return)") { startEditing(document.addSibling()) }
            IconButton(symbol: document.selectedTopic?.folded == true ? "plus.circle" : "minus.circle",
                       label: "Fold or unfold this branch (.)") { document.toggleFold() }
                .disabled(document.selectedTopic?.children.isEmpty != false)
            IconButton(symbol: "trash", label: "Delete this topic (⌫)") { document.deleteSelected() }
                .disabled(document.selected == nil || document.selected == document.root.id)
            Menu {
                Button("Copy as Outline") { copy(document.map.outline(sheet: document.sheet)) }
                Button("Copy as Mermaid") { copy("```mermaid\n" + document.map.mermaid(sheet: document.sheet) + "```\n") }
                Divider()
                Button("Open in XMind") { document.save(); NSWorkspace.shared.open(document.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Copy the map as an outline or a Mermaid mind map, or open it in XMind")
            Button {
                document.save()
                session.askClaude(MindMapBrief.extend(path: path, outline: document.map.outline(sheet: document.sheet),
                                                     command: Session.danteCommand ?? "dante"))
            } label: { ClaudeLabel("Ask \(session.agentName)") }
            .buttonStyle(DanteButtonStyle())
            .help("Ask \(session.agentName) to add to the map from the project")
            IconButton(symbol: "sidebar.right", label: showsInspector ? "Hide the notes" : "Show the notes") {
                withAnimation(.easeOut(duration: 0.18)) { showsInspector.toggle() }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(theme.panel.color)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: The map

    private var canvas: some View {
        let root = document.root
        let layout = MindMapLayout(root: root) { topic, depth in Self.size(of: topic, depth: depth) }
        let bounds = layout.bounds.insetBy(dx: -60, dy: -48)
        return ZoomablePicture(largestFit: 1) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for id in layout.order {
                        guard let place = layout.places[id], let parentID = place.parent, let parent = layout.places[parentID] else { continue }
                        context.stroke(Self.link(from: parent, to: place, offset: bounds.origin),
                                       with: .color(branchColor(place.branch)),
                                       style: StrokeStyle(lineWidth: place.depth == 1 ? 2.6 : 1.6, lineCap: .round))
                    }
                }
                .frame(width: bounds.width, height: bounds.height)
                ForEach(layout.order, id: \.self) { id in
                    if let place = layout.places[id], let topic = root.find(id) {
                        topicView(topic, place: place)
                            .frame(width: place.frame.width, height: place.frame.height)
                            .offset(x: place.frame.minX - bounds.minX, y: place.frame.minY - bounds.minY)
                    }
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { commitEdit(); focus = .map }
        }
        .id("\(path):\(document.sheet)")
        .background(theme.ground.color)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .map)
        .onKeyPress(phases: .down) { press in key(press, layout: layout) }
    }

    @ViewBuilder
    private func topicView(_ topic: MindMap.Topic, place: MindMapLayout.Place) -> some View {
        let isSelected = document.selected == topic.id
        let hue = branchColor(place.branch)
        let shape = RoundedRectangle(cornerRadius: place.depth == 0 ? 12 : place.depth == 1 ? 9 : 6, style: .continuous)
        ZStack {
            switch place.depth {
            case 0: shape.fill(theme.accent.color)
            case 1: shape.fill(theme.card.color.mix(with: hue, by: theme.isDark ? 0.22 : 0.12)).overlay(shape.strokeBorder(hue, lineWidth: 1.5))
            default:
                // Deeper topics sit on a line in their branch's colour, like XMind's.
                VStack { Spacer(); Rectangle().fill(hue).frame(height: 1.6) }
            }
            if editing == topic.id {
                TextField("Topic", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Self.font(depth: place.depth))
                    .foregroundStyle(place.depth == 0 ? theme.onAccent.color : theme.text.color)
                    .multilineTextAlignment(.center)
                    .focused($focus, equals: .title)
                    .onSubmit { commitEdit(); focus = .map }
                    .onKeyPress(.escape) { editing = nil; focus = .map; return .handled }
                    .padding(.horizontal, Self.padding(depth: place.depth).width)
            } else {
                VStack(spacing: 3) {
                    HStack(spacing: 5) {
                        Text(topic.title.isEmpty ? " " : topic.title)
                            .font(Self.font(depth: place.depth))
                            .foregroundStyle(place.depth == 0 ? theme.onAccent.color : theme.text.color)
                            .multilineTextAlignment(.center)
                        if topic.notes?.isEmpty == false {
                            Image(systemName: "note.text").font(.dante(size: 10))
                                .foregroundStyle(place.depth == 0 ? theme.onAccent.color : theme.text3.color)
                        }
                        if topic.link?.isEmpty == false {
                            Image(systemName: "link").font(.dante(size: 10))
                                .foregroundStyle(place.depth == 0 ? theme.onAccent.color : theme.text3.color)
                        }
                    }
                    if !topic.labels.isEmpty {
                        Text(topic.labels.joined(separator: " · "))
                            .font(.dante(size: 9.5, weight: .medium))
                            .foregroundStyle(place.depth == 0 ? theme.onAccent.color : theme.text3.color)
                            .lineLimit(1)
                    }
                }
                .padding(.bottom, place.depth >= 2 ? 3 : 0)
            }
        }
        .overlay(shape.strokeBorder(theme.accent.color, lineWidth: isSelected ? 2 : 0).padding(-3))
        .overlay(alignment: place.side == .left ? .leading : .trailing) {
            if topic.folded, !topic.children.isEmpty {
                Button { document.toggleFold(topic.id) } label: {
                    Text("\(topic.all.count - 1)")
                        .font(.dante(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(theme.onAccent.color)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(hue))
                }
                .buttonStyle(.plain)
                .help("Unfold \(topic.all.count - 1) topics")
                .offset(x: place.side == .left ? -24 : 24)
            }
        }
        .contentShape(shape)
        .onTapGesture(count: 2) { document.selected = topic.id; startEditing(topic.id) }
        .onTapGesture { commitEdit(); document.selected = topic.id; focus = .map }
        .contextMenu {
            Button("Add Subtopic") { document.selected = topic.id; startEditing(document.addChild()) }
            Button("Add Topic After") { document.selected = topic.id; startEditing(document.addSibling()) }
            Button("Rename") { document.selected = topic.id; startEditing(topic.id) }
            if !topic.children.isEmpty { Button(topic.folded ? "Unfold" : "Fold") { document.toggleFold(topic.id) } }
            if place.depth > 0 {
                Divider()
                Button("Move Up") { document.change("Move Topic") { $0.move(topic.id, by: -1) } }
                Button("Move Down") { document.change("Move Topic") { $0.move(topic.id, by: 1) } }
                Divider()
                Button("Delete") { document.selected = topic.id; document.deleteSelected() }
            }
        }
    }

    private func branchColor(_ branch: Int?) -> Color {
        guard let branch else { return theme.accent.color }
        return Self.hues[branch % Self.hues.count].rgba(theme).color
    }

    static let hues: [Diagram.Hue] = [.blue, .purple, .teal, .green, .amber, .pink, .orange, .indigo, .cyan, .red]

    /// From the parent's side to the child's near edge (a deeper topic's line under its title).
    static func link(from parent: MindMapLayout.Place, to child: MindMapLayout.Place, offset: CGPoint) -> Path {
        let right = child.side != .left
        let startY = parent.depth >= 2 ? parent.frame.maxY : parent.frame.midY
        let start = CGPoint(x: (right ? parent.frame.maxX : parent.frame.minX) - offset.x, y: startY - offset.y)
        let endY = child.depth >= 2 ? child.frame.maxY : child.frame.midY
        let end = CGPoint(x: (right ? child.frame.minX : child.frame.maxX) - offset.x, y: endY - offset.y)
        let bend = (end.x - start.x) * 0.55
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        return path
    }

    // MARK: Sizes

    static func font(depth: Int) -> Font {
        switch depth {
        case 0: .dante(size: 18, weight: .semibold)
        case 1: .dante(size: 14, weight: .medium)
        default: .dante(size: 13)
        }
    }

    private static func nsFont(depth: Int) -> NSFont {
        switch depth {
        case 0: DanteFonts.sans(size: 18, weight: .semibold)
        case 1: DanteFonts.sans(size: 14, weight: .medium)
        default: DanteFonts.sans(size: 13)
        }
    }

    static func padding(depth: Int) -> CGSize {
        switch depth {
        case 0: CGSize(width: 24, height: 14)
        case 1: CGSize(width: 14, height: 8)
        default: CGSize(width: 6, height: 5)
        }
    }

    /// The room a topic takes: its title wrapped at 240 points, plus room for the note and
    /// link marks and a line of labels.
    static func size(of topic: MindMap.Topic, depth: Int) -> CGSize {
        let text = NSAttributedString(string: topic.title.isEmpty ? " " : topic.title, attributes: [.font: nsFont(depth: depth)])
        let measured = text.boundingRect(with: CGSize(width: 240, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let marks = CGFloat((topic.notes?.isEmpty == false ? 1 : 0) + (topic.link?.isEmpty == false ? 1 : 0)) * 15
        let pad = padding(depth: depth)
        let labels: CGFloat = topic.labels.isEmpty ? 0 : 14
        return CGSize(width: max(depth == 0 ? 120 : 44, ceil(measured.width) + marks + pad.width * 2),
                      height: ceil(measured.height) + labels + pad.height * 2 + (depth >= 2 ? 3 : 0))
    }

    // MARK: Editing and keys

    private func startEditing(_ id: String?) {
        guard let id, let topic = document.root.find(id) else { return }
        commitEdit()
        draft = topic.title
        editing = id
        DispatchQueue.main.async { focus = .title }
    }

    private func commitEdit() {
        guard let id = editing else { return }
        editing = nil
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let topic = document.root.find(id), topic.title != title, !title.isEmpty { document.rename(id, to: title) }
    }

    private func key(_ press: KeyPress, layout: MindMapLayout) -> KeyPress.Result {
        guard editing == nil else { return .ignored }
        let root = document.root
        let current = document.selected ?? root.id
        switch press.key {
        case .tab: startEditing(document.addChild()); return .handled
        case .return: startEditing(document.addSibling()); return .handled
        case .space: startEditing(current); return .handled
        case .delete, .deleteForward: document.deleteSelected(); return .handled
        case .upArrow where press.modifiers.contains(.option):
            document.change("Move Topic") { $0.move(current, by: -1) }; return .handled
        case .downArrow where press.modifiers.contains(.option):
            document.change("Move Topic") { $0.move(current, by: 1) }; return .handled
        case .upArrow, .downArrow:
            if let next = Self.neighbour(of: current, in: layout, below: press.key == .downArrow) { document.selected = next }
            return .handled
        case .leftArrow, .rightArrow:
            let side = layout.places[current]?.side ?? .center
            let outward = (press.key == .rightArrow && side != .left) || (press.key == .leftArrow && side == .left)
            if side == .center {
                // From the centre, into the nearest main branch on that side.
                let wanted: MindMapLayout.Side = press.key == .rightArrow ? .right : .left
                document.selected = root.children.first { layout.places[$0.id]?.side == wanted }?.id ?? current
            } else if outward, let topic = root.find(current), !topic.folded, let first = topic.children.first {
                document.selected = first.id
            } else if !outward, let parent = root.parent(of: current) {
                document.selected = parent.id
            }
            return .handled
        default:
            if press.characters == "." { document.toggleFold(); return .handled }
            return .ignored
        }
    }

    /// The topic above or below on the same side of the map, nearest in height.
    static func neighbour(of id: String, in layout: MindMapLayout, below: Bool) -> String? {
        guard let place = layout.places[id] else { return nil }
        let candidates = layout.places.filter { other in
            other.key != id && other.value.side == place.side && other.value.depth == place.depth
                && (below ? other.value.frame.midY > place.frame.midY : other.value.frame.midY < place.frame.midY)
        }
        return candidates.min { abs($0.value.frame.midY - place.frame.midY) < abs($1.value.frame.midY - place.frame.midY) }?.key
    }
}

/// The chosen topic's title, notes, labels and link.
private struct MindMapInspector: View {
    @Environment(\.theme) private var theme
    let document: MindMapDocument

    var body: some View {
        ScrollView {
            if let topic = document.selectedTopic {
                VStack(alignment: .leading, spacing: 14) {
                    field("Topic") {
                        TextField("Title", text: binding(topic.id, \.title, "Rename Topic"), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                    }
                    field("Notes") {
                        TextEditor(text: Binding(get: { topic.notes ?? "" }, set: { value in
                            document.change("Edit Notes", coalescing: "notes:\(topic.id)") { $0.update(topic.id) { $0.notes = value.isEmpty ? nil : value } }
                        }))
                        .font(.dante(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 120)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.card.color))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.line.color))
                    }
                    field("Labels") {
                        TextField("Comma between labels", text: Binding(get: { topic.labels.joined(separator: ", ") }, set: { value in
                            let labels = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            document.change("Edit Labels", coalescing: "labels:\(topic.id)") { $0.update(topic.id) { $0.labels = labels } }
                        }))
                        .textFieldStyle(.roundedBorder)
                    }
                    field("Link") {
                        HStack(spacing: 6) {
                            TextField("https://…", text: Binding(get: { topic.link ?? "" }, set: { value in
                                document.change("Edit Link", coalescing: "link:\(topic.id)") { $0.update(topic.id) { $0.link = value.isEmpty ? nil : value } }
                            }))
                            .textFieldStyle(.roundedBorder)
                            if let link = topic.link, let url = URL(string: link), url.scheme == "https" || url.scheme == "http" {
                                IconButton(symbol: "arrow.up.right.square", label: "Open the link") { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                    Text("\(topic.all.count - 1) topics below")
                        .font(.dante(size: 11))
                        .foregroundStyle(theme.text3.color)
                }
                .padding(14)
            } else {
                Text("Choose a topic to see its notes.")
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text3.color)
                    .padding(14)
            }
        }
        .background(theme.panel.color)
    }

    private func binding(_ id: String, _ key: WritableKeyPath<MindMap.Topic, String>, _ name: String) -> Binding<String> {
        Binding(get: { document.root.find(id)?[keyPath: key] ?? "" }, set: { value in
            document.change(name, coalescing: "\(name):\(id)") { $0.update(id) { $0[keyPath: key] = value } }
        })
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.dante(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(theme.text3.color)
            content()
        }
    }
}
