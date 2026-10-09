import DanteKit
import SwiftUI

/// Map: the architecture as the repo declares it. Modules from Package.swift, services
/// from docker-compose.yml, or source folders, laid out so arrows point at what each part
/// uses. Select a box to see what it depends on and what depends on it.
struct MapView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    enum Source: String, CaseIterable, Identifiable {
        case modules = "Modules", services = "Services"
        var id: String { rawValue }
    }

    @State private var modules: ArchitectureGraph?
    @State private var services: ArchitectureGraph?
    @State private var source: Source = .modules
    @State private var showsTests = false
    @State private var selected: String?
    @State private var notes: String?
    @State private var loaded = false

    private var graph: ArchitectureGraph? {
        let base = source == .services ? (services ?? modules) : (modules ?? services)
        return showsTests ? base : base?.withoutTests
    }

    var body: some View {
        HStack(spacing: 0) {
            AreaPage(
                eyebrow: "Map · \(workspace.info.name ?? workspace.name)",
                title: graph?.title ?? "Architecture",
                subtitle: graph.map { "Generated from \($0.source). Arrows point from each part to what it uses." }
                    ?? "Dante draws the architecture from what the repo declares: Package.swift targets, docker-compose.yml services, or source folders."
            ) {
                if modules != nil, services != nil {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                if (source == .modules ? modules : services)?.nodes.contains(where: { $0.kind == .test }) == true {
                    Toggle("Tests", isOn: $showsTests).toggleStyle(.checkbox)
                }
                IconButton(symbol: "arrow.clockwise", label: "Regenerate") { Task { await load() } }
            } content: {
                if let graph, !graph.nodes.isEmpty {
                    DiagramCard(graph: graph, selected: $selected)
                    DriftCard(session: session, graph: graph, notes: notes)
                } else if loaded {
                    EmptyState(
                        symbol: "point.3.connected.trianglepath.dotted",
                        title: "Nothing to map yet",
                        message: "Dante reads Package.swift, docker-compose.yml and folders under src/ or Sources/. Claude can describe the architecture in .dante/architecture.md instead."
                    ) {
                        Button("Ask Claude to describe it") {
                            session.askClaude("Read the code and write .dante/architecture.md: the main parts of this system, what each owns, and how they talk to each other. Keep it to one page.")
                        }
                        .buttonStyle(DanteButtonStyle(primary: true))
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let graph, let id = selected, let node = graph.node(id) {
                Rectangle().fill(theme.line.color).frame(width: 1)
                Inspector(session: session, workspace: workspace, graph: graph, node: node) { selected = nil }
                    .frame(width: 290)
            }
        }
        .background(theme.ground.color)
        .task(id: workspace.revision) { await load() }
        .onChange(of: source) { selected = nil }
    }

    private func load() async {
        let root = workspace.url
        if FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            let output = await Shell.run(["swift", "package", "describe", "--type", "json"], in: root)
            modules = output.succeeded ? ArchitectureGraph.swiftPackage(describeJSON: output.stdout) : nil
        } else {
            let files = workspace.files
            modules = await Task.detached(priority: .utility) {
                ArchitectureGraph.goModules(files: files) { try? String(contentsOf: root.appending(path: $0), encoding: .utf8) }
                    ?? ArchitectureGraph.folders(files)
            }.value
        }
        services = ComposeFile.load(projectRoot: root).map(ArchitectureGraph.compose)
        if modules == nil, services != nil { source = .services }
        notes = try? String(contentsOf: root.appending(path: ".dante/architecture.md"), encoding: .utf8)
        if let selected, graph?.node(selected) == nil { self.selected = nil }
        loaded = true
    }
}

// MARK: Diagram

private struct NodeBoundsKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct DiagramCard: View {
    @Environment(\.theme) private var theme
    let graph: ArchitectureGraph
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .center, spacing: 72) {
                ForEach(Array(graph.columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: 18) {
                        ForEach(column) { node in
                            NodeBox(node: node, state: state(of: node)) {
                                selected = selected == node.id ? nil : node.id
                            }
                            .anchorPreference(key: NodeBoundsKey.self, value: .bounds) { [node.id: $0] }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
            .frame(minWidth: 0, alignment: .leading)
            .backgroundPreferenceValue(NodeBoundsKey.self) { anchors in
                GeometryReader { proxy in
                    Canvas { context, _ in
                        for edge in graph.edges {
                            guard let from = anchors[edge.from].map({ proxy[$0] }), let to = anchors[edge.to].map({ proxy[$0] }) else { continue }
                            let highlighted = selected != nil && (edge.from == selected || edge.to == selected)
                            draw(edge: (from, to), highlighted: highlighted, in: &context)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
        .background(theme.panel.color)
        .background(DotGrid(color: theme.line2.color, spacing: 16))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
        .overlay(alignment: .bottomLeading) { legend.padding(12) }
    }

    private enum NodeState { case normal, selected, related, dimmed }

    private func state(of node: ArchitectureGraph.Node) -> NodeState {
        guard let selected else { return .normal }
        if node.id == selected { return .selected }
        let related = graph.edges.contains { ($0.from == selected && $0.to == node.id) || ($0.to == selected && $0.from == node.id) }
        return related ? .related : .dimmed
    }

    private func draw(edge: (CGRect, CGRect), highlighted: Bool, in context: inout GraphicsContext) {
        let (from, to) = edge
        let forward = to.minX > from.maxX
        let start = CGPoint(x: forward ? from.maxX : from.midX, y: forward ? from.midY : (to.midY > from.midY ? from.maxY : from.minY))
        let end = CGPoint(x: forward ? to.minX - 2 : to.midX, y: forward ? to.midY : (to.midY > from.midY ? to.minY - 2 : to.maxY + 2))
        var path = Path()
        path.move(to: start)
        if forward, end.x - start.x > 120 {
            // Skips a column: arc above the boxes in between instead of running under them.
            let top = min(from.minY, to.minY) - 26
            path.addCurve(to: end, control1: CGPoint(x: start.x + 60, y: top), control2: CGPoint(x: end.x - 60, y: top))
        } else if forward {
            let bend = (end.x - start.x) / 2
            path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
        } else {
            path.addLine(to: end)
        }
        let color = highlighted ? theme.accent.color : theme.line2.color
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: highlighted ? 1.8 : 1.3, lineCap: .round))
        // Arrowhead along the final direction.
        let angle = forward ? 0 : (end.y > start.y ? CGFloat.pi / 2 : -CGFloat.pi / 2)
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - 7 * cos(angle - 0.45), y: end.y - 7 * sin(angle - 0.45)))
        head.addLine(to: CGPoint(x: end.x - 7 * cos(angle + 0.45), y: end.y - 7 * sin(angle + 0.45)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([("App", theme.accent.color), ("Module / service", theme.text3.color), ("External", theme.line2.color)], id: \.0) { label, color in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(color, lineWidth: 1.5).frame(width: 10, height: 8)
                    Text(label)
                }
            }
        }
        .font(.dante(size: 11))
        .foregroundStyle(theme.text3.color)
    }

    private struct NodeBox: View {
        @Environment(\.theme) private var theme
        let node: ArchitectureGraph.Node
        let state: NodeState
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.dante(size: 11)).foregroundStyle(node.kind == .app ? theme.accent.color : theme.text3.color)
                        Text(node.name).font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                    }
                    Text(node.detail).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(width: 184, height: 58, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(state == .selected ? theme.accentTint.color : (node.kind == .external ? theme.panel.color : theme.card.color)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(border, style: StrokeStyle(lineWidth: state == .selected ? 1.6 : 1, dash: node.kind == .external ? [4, 3] : []))
                )
                .opacity(state == .dimmed ? 0.45 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.snappy(duration: 0.15), value: state == .dimmed)
        }

        private var border: Color {
            if state == .selected { return theme.accent.color }
            if hovering || state == .related { return theme.accentLine.color }
            return node.kind == .app ? theme.accentLine.color : theme.line2.color
        }

        private var symbol: String {
            switch node.kind {
            case .app: "app.badge"
            case .library: "shippingbox"
            case .test: "testtube.2"
            case .service: "server.rack"
            case .external: "arrow.down.circle"
            case .folder: "folder"
            }
        }
    }
}

// MARK: Inspector

private struct Inspector: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let graph: ArchitectureGraph
    let node: ArchitectureGraph.Node
    let close: () -> Void

    var body: some View {
        let tasks = workspace.tasks.tasks.filter { $0.state != .done && ($0.title.localizedCaseInsensitiveContains(node.name) || ($0.note ?? "").localizedCaseInsensitiveContains(node.name)) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Eyebrow("Selected")
                    Spacer()
                    IconButton(symbol: "xmark", label: "Close", size: 10, action: close)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.name).font(.dante(size: 18, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(kindLabel).font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if let path = node.path { row("Path", value: path, mono: true) }
                    row("Size", value: node.detail, mono: true)
                    row("Depends on", value: graph.dependencies(of: node.id).map(\.name).joined(separator: ", ").nonEmpty ?? "nothing")
                    row("Used by", value: graph.dependents(of: node.id).map(\.name).joined(separator: ", ").nonEmpty ?? "nothing")
                }
                if !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Open tasks")
                        ForEach(tasks) { task in
                            Button { session.showPhase(task.phase.capitalized) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(task.id).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                                    Text(task.title).font(.dante(size: 12)).foregroundStyle(theme.text.color).lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let path = node.path, FileManager.default.fileExists(atPath: workspace.url.appending(path: path).path) {
                        Button {
                            reveal(path)
                        } label: {
                            Label("Show in explorer", systemImage: "folder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(DanteButtonStyle())
                    }
                    Button {
                        session.askClaude("Walk me through \(node.name)\(node.path.map { " (\($0))" } ?? ""): what it's responsible for, its main types and entry points, and how it's used by \(graph.dependents(of: node.id).map(\.name).joined(separator: ", ").nonEmpty ?? "the rest of the project").")
                    } label: {
                        Label("Ask Claude to walk through it", systemImage: "sparkle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                }
            }
            .padding(20)
        }
        .background(theme.panel.color)
    }

    private var kindLabel: String {
        switch node.kind {
        case .app: "App"
        case .library: "Module"
        case .test: "Tests"
        case .service: "Service"
        case .external: "External package"
        case .folder: "Folder"
        }
    }

    private func row(_ label: String, value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(theme.line.color).frame(height: 1)
            Text(label).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).padding(.top, 6)
            Text(value)
                .font(.dante(size: 12.5, design: mono ? .monospaced : .default))
                .foregroundStyle(theme.text.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
        }
    }

    /// Expands the folder and its parents in the explorer, then switches to Code.
    private func reveal(_ path: String) {
        var url = workspace.url
        for part in path.split(separator: "/") {
            url = url.appending(path: String(part))
            if let folder = workspace.root.node(for: url) {
                folder.loadChildren()
                folder.isExpanded = true
            }
        }
        session.area = .code
    }
}

private struct DriftCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let graph: ArchitectureGraph
    let notes: String?

    var body: some View {
        if let notes {
            let missing = graph.undocumented(in: notes)
            Card("Where the code and .dante/architecture.md disagree") {
                Text(missing.isEmpty ? "None found" : "\(missing.count) found")
                    .font(.dante(size: 12))
                    .foregroundStyle(missing.isEmpty ? theme.green.color : theme.amber.color)
            } content: {
                if missing.isEmpty {
                    Text("Every part on the map is mentioned in the architecture notes.").font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                }
                RowList(data: missing, padding: 9) { node in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.dante(size: 12)).foregroundStyle(theme.amber.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(node.name) isn’t documented").font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                            Text(node.path ?? node.detail).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                        }
                        Spacer()
                        Button("Add to notes") {
                            session.askClaude("\(node.name)\(node.path.map { " (\($0))" } ?? "") is in the code but .dante/architecture.md doesn't mention it. Read it and add a short entry to the architecture notes.")
                        }
                        .buttonStyle(DanteButtonStyle())
                    }
                }
            }
        } else {
            Card("Architecture notes") {
                HStack(spacing: 12) {
                    Text("Add .dante/architecture.md to describe what each part owns. Dante then flags parts of the code the notes don’t mention.")
                        .font(.dante(size: 12.5))
                        .foregroundStyle(theme.text2.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Draft with Claude") {
                        session.askClaude("Write .dante/architecture.md: one short section per part of this system (\(graph.withoutTests.nodes.filter { $0.kind != .external }.map(\.name).joined(separator: ", "))), saying what it owns and what it talks to. Keep it to one page.")
                    }
                    .buttonStyle(DanteButtonStyle())
                }
            }
        }
    }
}
