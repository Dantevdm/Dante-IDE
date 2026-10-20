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
        case system = "System", modules = "Modules", services = "Services"
        var id: String { rawValue }
    }

    @State private var modules: ArchitectureGraph?
    @State private var services: ArchitectureGraph?
    @State private var system: SystemMap?
    @State private var source: Source = .system
    @State private var showsTests = false
    @State private var selected: String?
    @State private var notes: String?
    @State private var loaded = false
    @State private var coverage: CoverageReport?
    @AppStorage("mapShowsCoverage") private var showsCoverage = false
    /// The parts opened, outermost first; the map shown is the last one's inside.
    @State private var trail: [SystemMap.Part] = []
    @State private var insides: [String: SystemMap] = [:]
    /// Per shown map (by the opened part's id, "" for the whole system): parts with more inside.
    @State private var openable: [String: Set<String>] = [:]
    @State private var opening: String?
    @State private var zoomingIn = true
    @State private var zoomAnchor: UnitPoint = .center

    private var level: String { trail.last?.id ?? "" }
    private var shown: SystemMap? { trail.last.flatMap { insides[$0.id] } ?? system }

    private var showsSystem: Bool { source == .system && system?.isUseful == true }

    private var sources: [Source] {
        Source.allCases.filter { $0 == .system ? system?.isUseful == true : $0 == .modules ? modules != nil : services != nil }
    }

    private var graph: ArchitectureGraph? {
        let base = source == .services ? (services ?? modules) : (modules ?? services)
        return showsTests ? base : base?.withoutTests
    }

    var body: some View {
        HStack(spacing: 0) {
            AreaPage(
                eyebrow: nil,
                title: showsSystem || (source == .system && !loaded) ? "System map" : graph?.title ?? "Architecture",
                subtitle: nil
            ) {
                if sources.count > 1 {
                    Picker("Source", selection: $source) {
                        ForEach(sources) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: CGFloat(sources.count) * 82)
                }
                if !showsSystem, (source == .modules ? modules : services)?.nodes.contains(where: { $0.kind == .test }) == true {
                    Toggle("Tests", isOn: $showsTests).toggleStyle(.checkbox)
                }
                if showsSystem, let coverage {
                    Toggle("Coverage", isOn: $showsCoverage)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("Line coverage from \(coverage.source)\(coverage.date.map { ", written " + $0.formatted(.relative(presentation: .named)) } ?? "")")
                }
                if showsSystem, let system {
                    IconButton(symbol: "square.and.arrow.up", label: "Export as Mermaid into .dante/architecture.md") { exportMermaid(system) }
                }
                IconButton(symbol: "arrow.clockwise", label: "Regenerate") { Task { await load() } }
            } content: {
                if source == .system, system == nil, !loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 200)
                } else if showsSystem, let map = shown {
                    if !trail.isEmpty { trailBar }
                    SystemSummary(map: map, compact: !trail.isEmpty)
                        .id("summary" + level)
                    SystemDiagram(map: map, selected: $selected, coverage: showsCoverage ? coverage.map(map.coverage) : nil,
                                  openable: openable[level] ?? [], opening: opening, open: open)
                        .id("diagram" + level)
                        .transition(.asymmetric(
                            insertion: .scale(scale: zoomingIn ? 0.35 : 1.25, anchor: zoomingIn ? zoomAnchor : .center).combined(with: .opacity),
                            removal: .scale(scale: zoomingIn ? 1.25 : 0.35, anchor: zoomingIn ? .center : zoomAnchor).combined(with: .opacity)))
                    if trail.isEmpty, let graph { DriftCard(session: session, graph: graph, notes: notes) }
                } else if let graph, !graph.nodes.isEmpty {
                    DiagramCard(graph: graph, selected: $selected)
                    DriftCard(session: session, graph: graph, notes: notes)
                } else if loaded {
                    EmptyState(
                        symbol: "point.3.connected.trianglepath.dotted",
                        title: "Nothing to map yet"
                    ) {
                        Button("Ask \(session.agentName) to describe it") {
                            session.askClaude("Read the code and write .dante/architecture.md: the main parts of this system, what each owns, and how they talk to each other. Keep it to one page.")
                        }
                        .buttonStyle(DanteButtonStyle(primary: true))
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if showsSystem, let map = shown, let id = selected, let part = map.part(id) {
                Rectangle().fill(theme.line.color).frame(width: 1)
                SystemInspector(session: session, workspace: workspace, map: map, part: part, coverage: coverage.flatMap { map.coverage($0)[part.id] },
                                open: openable[level]?.contains(part.id) == true ? { open(part) } : nil) { selected = nil }
                    .frame(width: 300)
            } else if !showsSystem, let graph, let id = selected, let node = graph.node(id) {
                Rectangle().fill(theme.line.color).frame(width: 1)
                Inspector(session: session, workspace: workspace, graph: graph, node: node) { selected = nil }
                    .frame(width: 290)
            }
        }
        .background(theme.ground.color)
        .task(id: workspace.revision) { await load() }
        .onChange(of: source) {
            selected = nil
            trail = []
        }
    }

    /// Where the drill-down stands: the whole system, then each part opened.
    private var trailBar: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.left", label: "Back out of \(trail.last?.name ?? "")") { close(to: trail.count - 1) }
            crumb("System", index: 0, symbol: "point.3.connected.trianglepath.dotted")
            ForEach(Array(trail.enumerated()), id: \.element.id) { index, part in
                Image(systemName: "chevron.right").font(.dante(size: 9, weight: .semibold)).foregroundStyle(theme.text3.color)
                crumb(part.name, index: index + 1, symbol: part.lane == .clients ? "macwindow" : "shippingbox")
            }
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func crumb(_ title: String, index: Int, symbol: String) -> some View {
        let current = index == trail.count
        return Button { close(to: index) } label: {
            Label(title, systemImage: symbol)
                .font(.dante(size: 12.5, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? theme.text.color : theme.text2.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(current ? theme.accentTint.color : theme.raised.color, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(current)
    }

    /// Opens a part: builds its inside once (off the main thread), then zooms into it.
    private func open(_ part: SystemMap.Part) {
        guard opening == nil, let map = shown else { return }
        // Zoom out of the box's place: its column across, the middle down.
        let columns = map.lanes.map(\.lane)
        let column = columns.firstIndex(of: part.lane) ?? 0
        zoomAnchor = UnitPoint(x: (Double(column) + 0.5) / Double(max(columns.count, 1)), y: 0.45)
        if insides[part.id] != nil {
            show(part)
            return
        }
        opening = part.id
        let files = workspace.files
        let read = Self.reader(root: workspace.url)
        Task {
            let built = await Task.detached(priority: .userInitiated) { () -> (SystemMap, Set<String>)? in
                guard let inside = SystemMap.inside(part, files: files, read: read) else { return nil }
                return (inside, Set(inside.parts.filter { inside.opens($0, files: files) }.map(\.id)))
            }.value
            opening = nil
            guard let (inside, more) = built else { return }
            insides[part.id] = inside
            openable[part.id] = more
            session.mapCache?.insides = insides
            session.mapCache?.openable = openable
            show(part)
        }
    }

    private func show(_ part: SystemMap.Part) {
        zoomingIn = true
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
            trail.append(part)
            selected = nil
        }
    }

    /// Back out to `index` levels deep (0 is the whole system).
    private func close(to index: Int) {
        guard index < trail.count else { return }
        zoomingIn = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
            selected = trail.count > index ? trail[index].id : nil
            trail.removeLast(trail.count - index)
        }
    }

    /// Reads code and manifests for the map, never data files or large SQL dumps.
    nonisolated static func reader(root: URL) -> @Sendable (String) -> String? {
        { path in
            guard SystemMap.isReadable(path) else { return nil }
            let url = root.appending(path: path)
            // SQL is read for CREATE TABLE only; a large file is a dump, not a schema.
            if path.lowercased().hasSuffix(".sql"), ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1_000_000 { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    private func exportMermaid(_ map: SystemMap) {
        let url = workspace.danteFolder.appending(path: "architecture.md")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let current = try? String(contentsOf: url, encoding: .utf8)
            try map.exporting(into: current).write(to: url, atomically: true, encoding: .utf8)
            session.open(file: url)
        } catch {
            session.errorMessage = "Couldn’t write architecture.md: \(error.localizedDescription)"
        }
    }

    private func load() async {
        // Coming back to the Map shows what was built for this revision instead of building
        // it again, which takes seconds on a big repo.
        if let cache = session.mapCache, cache.revision == workspace.revision {
            (modules, services, system, coverage, notes) = (cache.modules, cache.services, cache.system, cache.coverage, cache.notes)
            (insides, openable) = (cache.insides, cache.openable)
            trail = trail.filter { insides[$0.id] != nil }
            if !sources.contains(source) { source = sources.first ?? .modules }
            loaded = true
            return
        }
        let revision = workspace.revision
        let root = workspace.url
        if FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            let output = await Shell.run(["swift", "package", "describe", "--type", "json"], in: root)
            modules = output.succeeded ? ArchitectureGraph.swiftPackage(describeJSON: output.stdout) : nil
        } else {
            let files = workspace.files
            modules = await Task.detached(priority: .userInitiated) {
                ArchitectureGraph.goModules(files: files) { try? String(contentsOf: root.appending(path: $0), encoding: .utf8) }
                    ?? ArchitectureGraph.folders(files)
            }.value
        }
        let compose = ComposeFile.load(projectRoot: root)
        services = compose.map(ArchitectureGraph.compose)
        let files = workspace.files
        let graph = modules
        let read = Self.reader(root: root)
        let (built, more) = await Task.detached(priority: .userInitiated) { () -> (SystemMap, Set<String>) in
            let map = SystemMap.build(files: files, read: read, compose: compose, modules: graph)
            return (map, Set(map.parts.filter { map.opens($0, files: files) }.map(\.id)))
        }.value
        system = built
        // The code changed: opened parts are built again from it, the trail kept.
        openable = ["": more]
        var rebuilt: [String: SystemMap] = [:]
        var kept: [SystemMap.Part] = []
        for part in trail {
            guard let inside = await Task.detached(priority: .userInitiated, operation: { SystemMap.inside(part, files: files, read: read) }).value else { break }
            rebuilt[part.id] = inside
            openable[part.id] = await Task.detached(priority: .userInitiated) { Set(inside.parts.filter { inside.opens($0, files: files) }.map(\.id)) }.value
            kept.append(part)
        }
        insides = rebuilt
        trail = kept
        coverage = await Task.detached(priority: .utility) { CoverageReport.load(root: root, files: files) }.value
        if !sources.contains(source) { source = sources.first ?? .modules }
        notes = try? String(contentsOf: root.appending(path: ".dante/architecture.md"), encoding: .utf8)
        if let selected, graph?.node(selected) == nil, shown?.part(selected) == nil { self.selected = nil }
        session.mapCache = MapCache(revision: revision, modules: modules, services: services, system: system, coverage: coverage, notes: notes,
                                    insides: insides, openable: openable)
        loaded = true
    }
}

/// The Map's last build for a window, so switching areas doesn't rebuild it.
struct MapCache {
    var revision: Int
    var modules: ArchitectureGraph?
    var services: ArchitectureGraph?
    var system: SystemMap?
    var coverage: CoverageReport?
    var notes: String?
    var insides: [String: SystemMap] = [:]
    var openable: [String: Set<String>] = [:]
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
                        ClaudeLabel("Ask \(session.agentName) to walk through it").frame(maxWidth: .infinity)
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
                    Text("No architecture notes yet")
                        .font(.dante(size: 12.5))
                        .foregroundStyle(theme.text2.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Draft with \(session.agentName)") {
                        session.askClaude("Write .dante/architecture.md: one short section per part of this system (\(graph.withoutTests.nodes.filter { $0.kind != .external }.map(\.name).joined(separator: ", "))), saying what it owns and what it talks to. Keep it to one page.")
                    }
                    .buttonStyle(DanteButtonStyle())
                }
            }
        }
    }
}
