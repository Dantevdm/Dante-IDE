import DanteKit
import SwiftUI

/// The System map: lanes from the screens people use, through the API and the backend, to
/// the data and outside services, with arrows along the real calls.
struct SystemDiagram: View {
    @Environment(\.theme) private var theme
    let map: SystemMap
    @Binding var selected: String?
    /// Line coverage per part, when the overlay is on.
    var coverage: [String: CoverageReport.Lines]?
    /// Parts with more inside, the one being opened, and how to open one.
    var openable: Set<String> = []
    var opening: String?
    var open: (SystemMap.Part) -> Void = { _ in }
    /// The container chip on a box: its database in Data, or its service in Local.
    var openContainer: (SystemMap.Part) -> Void = { _ in }
    /// Where the boxes are, for Copy and edit.
    var recorder: MapLayoutRecorder?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.areaScroll) private var areaScroll
    /// When the selection last changed, so its links light up rather than snap.
    @State private var litAt = Date.distantPast

    static let width: CGFloat = 180
    static let gap: CGFloat = 44

    /// Data and outside services share the last column: both hang off the backend, and
    /// separate columns would send every outside arrow under the data boxes.
    private var columns: [[(lane: SystemMap.Lane, parts: [SystemMap.Part])]] {
        var result: [[(lane: SystemMap.Lane, parts: [SystemMap.Part])]] = []
        for lane in map.lanes {
            if lane.lane == .outside, let last = result.last, last[0].lane == .data {
                result[result.count - 1].append(lane)
            } else {
                result.append([lane])
            }
        }
        return result
    }

    /// A container chip once per container in the backend: on its app, else its first part.
    private func showsContainer(_ part: SystemMap.Part) -> Bool {
        guard let container = part.container else { return false }
        guard part.lane == .backend else { return true }
        let same = map.parts.filter { $0.lane == .backend && $0.container == container }
        return (same.first { $0.kind == .app } ?? same.first)?.id == part.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            diagram
                .onChange(of: selected) { _, id in
                    litAt = .now
                    guard let id else { return }
                    // The chosen box glides to the middle, across and down, once the
                    // inspector has taken its room.
                    Task {
                        try? await Task.sleep(for: .milliseconds(80))
                        guard selected == id else { return }
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
                            proxy.scrollTo(id, anchor: .center)
                            areaScroll?.scrollTo(id, anchor: .center)
                        }
                    }
                }
        }
    }

    private var diagram: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: Self.gap) {
                    ForEach(columns, id: \.first!.lane) { column in
                        LaneHeader(title: map.title(of: column[0].lane), count: column[0].parts.count)
                            .frame(width: columnWidth(column[0].lane), alignment: .leading)
                    }
                }
                // Columns centre on each other so arrows between short and long ones stay level.
                HStack(alignment: .center, spacing: Self.gap) {
                    ForEach(columns, id: \.first!.lane) { column in
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(column.enumerated()), id: \.element.lane) { index, section in
                                if index > 0 {
                                    LaneHeader(title: map.title(of: section.lane), count: section.parts.count).padding(.top, 10)
                                }
                                let tiers = tiers(of: section.lane)
                                if tiers.count > 1 {
                                    // The backend in the order the code runs: entry, the parts it uses, what they share.
                                    HStack(alignment: .center, spacing: Self.tierGap) {
                                        ForEach(Array(tiers.enumerated()), id: \.offset) { tier, parts in
                                            VStack(alignment: .leading, spacing: 12) {
                                                Text(Self.tierTitle(tier, of: tiers.count))
                                                    .font(.dante(size: 10, weight: .semibold)).tracking(0.6)
                                                    .foregroundStyle(theme.text3.color)
                                                ForEach(parts) { part in box(part, lane: section.lane) }
                                            }
                                            .frame(width: Self.width)
                                        }
                                    }
                                } else {
                                    ForEach(section.parts) { part in box(part, lane: section.lane) }
                                }
                            }
                        }
                        .frame(width: columnWidth(column[0].lane))
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 52)
            .backgroundPreferenceValue(PartBoundsKey.self) { anchors in
                GeometryReader { proxy in
                    RecordFrames(frames: anchors.mapValues { proxy[$0] }, recorder: recorder)
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                        Canvas { context, _ in
                            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                            // Lit links fade in over a third of a second.
                            let lit = reduceMotion ? 1 : min(1, max(0, timeline.date.timeIntervalSince(litAt) / 0.32))
                            let heaviest = max(map.links.map(\.weight).max() ?? 1, 1)
                            for (index, link) in map.links.enumerated() {
                                guard let from = anchors[link.from].map({ proxy[$0] }), let to = anchors[link.to].map({ proxy[$0] }) else { continue }
                                let highlighted = selected != nil && (link.from == selected || link.to == selected)
                                let dimmed = selected != nil && !highlighted
                                let width = 1.1 + 1.6 * CGFloat(link.weight) / CGFloat(heaviest)
                                let path = MapInk.path(.loop(from, to))
                                if highlighted {
                                    let accent = theme.accent.color
                                    MapInk.stroke(path, color: theme.line2.color, width: width, in: &context)
                                    // The lit line draws itself along the link, then traffic flows on it.
                                    MapInk.stroke(path.trimmedPath(from: 0, to: lit), color: accent, width: width + 0.6, in: &context)
                                    MapInk.stroke(path, color: accent.opacity(0.55 * lit), width: width + 0.6, dash: [5, 7], phase: -time * 24, in: &context)
                                    MapInk.pulse(path, time: time + Double(index % 5) * 0.37, color: accent, in: &context)
                                    MapInk.arrowhead(path, color: accent, in: &context)
                                } else {
                                    let color = theme.line2.color.opacity(dimmed ? 0.35 : 1)
                                    MapInk.stroke(path, color: color, width: width, in: &context)
                                    MapInk.arrowhead(path, color: color, in: &context)
                                    // At rest the busiest links carry a little traffic.
                                    if selected == nil, link.weight * 3 >= heaviest {
                                        MapInk.pulse(path, time: time + Double(index % 7) * 0.33, color: hue(map.part(link.to)?.lane ?? .backend), in: &context)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
        .background(theme.panel.color)
        .background(DotGrid(color: theme.line2.color, spacing: 16))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
        .overlay(alignment: .bottomLeading) {
        }
    }

    static let tierGap: CGFloat = 34

    /// Lanes split into tiers only for the backend, where the order matters most.
    private func tiers(of lane: SystemMap.Lane) -> [[SystemMap.Part]] {
        lane == .backend ? map.tiers(of: lane) : []
    }

    private func columnWidth(_ lane: SystemMap.Lane) -> CGFloat {
        let count = CGFloat(max(tiers(of: lane).count, 1))
        return Self.width * count + Self.tierGap * (count - 1)
    }

    static func tierTitle(_ tier: Int, of count: Int) -> String {
        if tier == 0 { return "STARTS HERE" }
        if tier == count - 1 { return "SHARED" }
        return "USES"
    }

    private func box(_ part: SystemMap.Part, lane: SystemMap.Lane) -> some View {
        PartBox(part: part, state: state(of: part), hue: hue(lane), showsContainer: showsContainer(part),
                coverage: coverage.map { $0[part.id]?.fraction ?? -1 },
                opens: openable.contains(part.id), isOpening: opening == part.id,
                open: { open(part) }, openContainer: { openContainer(part) }) {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                selected = selected == part.id ? nil : part.id
            }
        }
        .id(part.id)
        .anchorPreference(key: PartBoundsKey.self, value: .bounds) { [part.id: $0] }
    }

    enum PartState { case normal, selected, related, dimmed }

    private func state(of part: SystemMap.Part) -> PartState {
        guard let selected else { return .normal }
        if part.id == selected { return .selected }
        let related = map.links.contains { ($0.from == selected && $0.to == part.id) || ($0.to == selected && $0.from == part.id) }
        return related ? .related : .dimmed
    }

    func hue(_ lane: SystemMap.Lane) -> Color { Self.hue(lane, theme: theme) }

    static func hue(_ lane: SystemMap.Lane, theme: Theme) -> Color { Diagram.Hue(lane: lane).rgba(theme).color }
}

private struct PartBoundsKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct LaneHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .lineLimit(1)
                .font(.dante(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(theme.text3.color)
            Text("\(count)")
                .font(.dante(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.text3.color)
                .padding(.horizontal, 5)
                .background(theme.raised.color, in: Capsule())
        }
        .padding(.leading, 2)
    }
}

struct PartBox: View {
    @Environment(\.theme) private var theme
    let part: SystemMap.Part
    let state: SystemDiagram.PartState
    let hue: Color
    var showsContainer = true
    /// 0…1 with the overlay on; negative when the report has nothing for this part.
    var coverage: Double?
    /// Has smaller pieces inside: a mark in the corner, and a double-click opens it.
    var opens = false
    var isOpening = false
    var open: () -> Void = {}
    var openContainer: () -> Void = {}
    let action: () -> Void
    @State private var hovering = false
    @State private var hoveringChip = false

    private let shown = 8

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    PartIcon(symbol: part.kind.symbol, hue: hue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Breakable.camel(part.name))
                            .font(.dante(size: 13, weight: .semibold, design: part.lane == .api ? .monospaced : .default))
                            .foregroundStyle(theme.text.color)
                            .lineLimit(2)
                            .truncationMode(part.lane == .api ? .middle : .tail)
                            .fixedSize(horizontal: false, vertical: true)
                        if !part.detail.isEmpty {
                            Text(part.detail).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if let access = PartBox.access(of: part) {
                        Image(systemName: access.isConcern ? "lock.open.fill" : access.level == .secured ? "lock.fill" : "lock.open")
                            .font(.dante(size: 9.5, weight: .semibold))
                            .foregroundStyle(access.isConcern ? theme.amber.color : access.level == .secured ? theme.green.color : theme.text3.color)
                            .help(access.note)
                    }
                    if isOpening {
                        ProgressView().controlSize(.mini)
                    } else if opens {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.dante(size: 9, weight: .semibold))
                            .foregroundStyle(hovering ? hue : theme.text3.color)
                            .frame(width: 18, height: 18)
                            .background((hovering ? hue.opacity(0.14) : Color.clear), in: Circle())
                            .help("Open \(part.name) to see what's inside (double-click)")
                    }
                }
                if part.lane == .clients, part.id.hasPrefix("client:"), !part.items.isEmpty {
                    // Screens as one wrapped line; the inspector lists them all.
                    let names = part.items.prefix(shown).map(\.text).joined(separator: " · ")
                    Text(names + (part.items.count > shown ? " +\(part.items.count - shown)" : ""))
                        .font(.dante(size: 10.5))
                        .foregroundStyle(theme.text2.color)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 29)
                }
                if let coverage, part.lane != .data, part.lane != .outside {
                    CoverageBar(fraction: coverage).padding(.leading, 29)
                }
                if showsContainer, let container = part.container {
                    HStack(spacing: 4) {
                        Image(systemName: part.lane == .data ? "cylinder.split.1x2" : "shippingbox").font(.dante(size: 9))
                        Text(container).font(.dante(size: 10.5, design: .monospaced))
                        if hoveringChip { Image(systemName: "arrow.up.right").font(.dante(size: 8, weight: .semibold)) }
                    }
                    .foregroundStyle(hoveringChip ? hue : theme.text3.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(hoveringChip ? hue.opacity(0.14) : theme.raised.color, in: Capsule())
                    .contentShape(Capsule())
                    .onHover { hoveringChip = $0 }
                    // Over the box's own click.
                    .highPriorityGesture(TapGesture().onEnded { openContainer() })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(part.lane == .data ? "Open the \(container) database" : "Open the \(container) service")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openContainer() }
                    .padding(.leading, 29)
                    .help(part.lane == .data ? "Open the \(container) database in Data" : "Runs in the \(container) container: open it in Services")
                    .animation(.snappy(duration: 0.15), value: hoveringChip)
                }
            }
            .padding(10)
            .frame(width: SystemDiagram.width, alignment: .leading)
            .modifier(PartChrome(hue: hue, selected: state == .selected, emphasised: hovering || state == .related, dashed: part.lane == .outside))
            .opacity(state == .dimmed ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if opens { open() } })
        .onHover { hovering = $0 }
        .scaleEffect(state == .selected ? 1.03 : hovering && opens ? 1.015 : 1)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: state)
        .animation(.snappy(duration: 0.18), value: hovering)
    }

    /// A route box's access: its own, or for a group the most worrying of its routes.
    static func access(of part: SystemMap.Part) -> SystemMap.Access? {
        guard part.lane == .api else { return nil }
        let all = part.items.compactMap(\.access)
        return all.first(where: \.isConcern) ?? (all.count == 1 ? all[0] : all.allSatisfy { $0.level == .secured } ? all.first : nil)
    }

    static func symbol(_ kind: SystemMap.Kind) -> String { kind.symbol }
}

/// How much of a part the tests run: a bar and a percentage, coloured by how much.
private struct CoverageBar: View {
    @Environment(\.theme) private var theme
    let fraction: Double

    var body: some View {
        HStack(spacing: 6) {
            if fraction < 0 {
                Text("no coverage data").font(.dante(size: 10)).foregroundStyle(theme.text3.color)
            } else {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.raised.color)
                        Capsule().fill(color).frame(width: max(3, proxy.size.width * fraction))
                    }
                }
                .frame(height: 5)
                Text("\(Int((fraction * 100).rounded()))%").font(.dante(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(color)
            }
        }
        .help(fraction < 0 ? "The coverage report has no lines from this part" : "Lines the tests run")
    }

    private var color: Color {
        fraction >= 0.7 ? theme.green.color : fraction >= 0.4 ? theme.amber.color : theme.red.color
    }
}

/// A screen, or a route with its method coloured.
struct ItemLine: View {
    @Environment(\.theme) private var theme
    let item: SystemMap.Item
    let isRoute: Bool

    var body: some View {
        let words = item.text.split(separator: " ", maxSplits: 1).map(String.init)
        HStack(spacing: 5) {
            if isRoute, words.count == 2 {
                Text(words[0])
                    .font(.dante(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(methodColor(words[0]))
                    .frame(width: 34, alignment: .leading)
                Text(words[1]).font(.dante(size: 10.5, design: .monospaced)).foregroundStyle(theme.text2.color)
            } else {
                Text(item.text).font(.dante(size: 10.5, design: isRoute ? .monospaced : .default)).foregroundStyle(theme.text2.color)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": theme.green.color
        case "POST": theme.accent.color
        case "PUT", "PATCH": theme.amber.color
        case "DELETE": theme.red.color
        default: theme.text3.color
        }
    }
}

/// Counts across the top: how much of each lane there is.
struct SystemSummary: View {
    @Environment(\.theme) private var theme
    let map: SystemMap
    /// Inside a part: only what it has, and its pieces rather than backend parts.
    var compact = false

    private static func counted(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }

    var body: some View {
        let clients = map.parts.filter { $0.lane == .clients && !$0.id.hasPrefix("screen:") }
        let screens = clients.reduce(0) { $0 + $1.items.count }
        let stores = map.parts.filter { $0.lane == .data && $0.kind != .table }
        let tables = map.parts.filter { $0.kind == .table }.count
        let routeGroups = map.parts.filter { $0.lane == .api }.count
        let backend = map.parts.filter { $0.lane == .backend }.count
        let outside = map.parts.filter { $0.lane == .outside }
        let stats: [(String, String, String)] = [
            ("\(clients.count)", clients.count == 1 ? "client" : "clients", screens > 0 ? Self.counted(screens, "screen", "screens") : ""),
            ("\(map.routeCount)", map.routeCount == 1 ? "API route" : "API routes", Self.counted(routeGroups, "group", "groups")),
            ("\(backend)", compact ? (backend == 1 ? "piece" : "pieces") : backend == 1 ? "backend part" : "backend parts", ""),
            stores.isEmpty && tables > 0 ? ("\(tables)", tables == 1 ? "table" : "tables", map.parts.filter { $0.kind == .table }.map(\.name).prefix(3).joined(separator: ", "))
                : ("\(stores.count)", stores.count == 1 ? "data store" : "data stores", ([stores.map(\.name).joined(separator: ", ")] + (tables > 0 ? [Self.counted(tables, "table", "tables")] : [])).filter { !$0.isEmpty }.joined(separator: " · ")),
            outside.allSatisfy({ $0.kind == .structure }) && !outside.isEmpty
                ? ("\(outside.count)", outside.count == 1 ? "class used" : "classes used", outside.map(\.name).prefix(3).joined(separator: ", "))
                : ("\(outside.count)", outside.count == 1 ? "outside service" : "outside services", outside.map(\.name).prefix(3).joined(separator: ", ")),
        ]
        HStack(spacing: 10) {
            ForEach(stats.filter { !compact || $0.0 != "0" }, id: \.1) { value, label, note in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(value).font(.dante(size: 20, weight: .semibold)).foregroundStyle(theme.text.color)
                        Text(label).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                    }
                    Text(note.isEmpty ? " " : note).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
            }
        }
    }
}

/// The selected part: everything inside it, what it uses and what uses it.
struct SystemInspector: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let map: SystemMap
    let part: SystemMap.Part
    var coverage: CoverageReport.Lines?
    /// Opens the part to show what's inside, when it has smaller pieces.
    var open: (() -> Void)?
    /// Selects another part on the map: a database's table.
    var select: (String) -> Void = { _ in }
    let close: () -> Void
    /// The repo's SQL for a table or database, read off the main thread.
    @State private var schema: [SystemMap.TableSchema]?
    /// What could be better about the database, for its inspector and each table's.
    @State private var advice: [SchemaAdvice] = []
    @State private var copied: String?

    private var table: SystemMap.TableSchema? {
        part.kind == .table ? schema?.first { $0.name.lowercased() == part.name.lowercased() } : nil
    }

    var body: some View {
        content
            .task(id: part.id) {
                guard part.kind == .table || part.kind == .database else { return }
                let files = workspace.files
                let read = MapView.reader(root: workspace.url)
                let found = await Task.detached(priority: .userInitiated) { () -> ([SystemMap.TableSchema], [SchemaAdvice]) in
                    let tables = SystemMap.schema(files: files, read: read)
                    return (tables, SchemaAdvice.analyse(tables, files: files, read: read))
                }.value
                schema = found.0
                advice = found.1
            }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Eyebrow(map.title(of: part.lane))
                    Spacer()
                    IconButton(symbol: "xmark", label: "Close", size: 10, action: close)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(part.name).font(.dante(size: 18, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(part.detail).font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                if let web = webApp {
                    if let launch = session.webLaunch, launch.name == web.client.name {
                        WebLaunchCard(session: session, launch: launch)
                    } else {
                        Button { session.openInBrowser(folder: web.client.path ?? "", name: web.client.name, screen: web.screen) } label: {
                            Label(web.screen == nil ? "Open in browser" : "Open \(web.screen!.name) in browser", systemImage: "safari").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(DanteButtonStyle(primary: open == nil))
                        .help("Opens it in your browser on localhost. If its dev server isn’t running, Dante says so and starts it first.")
                    }
                }
                if part.kind == .table, let table {
                    TableDetail(session: session, workspace: workspace, map: map, table: table, copied: $copied, copy: copy)
                } else if part.kind == .database, let schema, !schema.isEmpty {
                    DatabaseDetail(session: session, part: part, schema: schema, copied: $copied, copy: copy)
                }
                if part.kind == .table || part.kind == .database, schema?.isEmpty == false {
                    let shown = part.kind == .table ? advice.filter { $0.table?.lowercased() == part.name.lowercased() } : advice
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Eyebrow("Suggestions")
                            Spacer()
                            if !shown.isEmpty {
                                Text("\(shown.count)").font(.dante(size: 10.5, design: .monospaced))
                                    .foregroundStyle(shown.contains { $0.weight == .warning } ? theme.amber.color : theme.text3.color)
                            }
                        }
                        SchemaSuggestions(session: session, workspace: workspace, advice: shown, limit: part.kind == .table ? 8 : 5)
                    }
                    .transition(.opacity)
                }
                if part.lane == .api, part.items.contains(where: { $0.access != nil }) {
                    AccessSection(session: session, workspace: workspace, part: part)
                }
                if !part.items.isEmpty, !(part.kind == .table && table != nil) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(part.lane == .api ? "Routes" : part.lane == .clients ? "Screens" : part.kind == .database ? "Tables"
                                : part.kind == .table ? "Columns" : part.kind == .function || part.kind == .structure && part.path == nil ? "Declared" : "Inside")
                        ForEach(part.items, id: \.self) { item in
                            HStack(spacing: 6) {
                                Button {
                                    if let file = item.file {
                                        session.open(file: workspace.url.appending(path: file), line: item.line ?? 1)
                                    } else if part.kind == .database, map.part("table:" + item.text) != nil {
                                        select("table:" + item.text)
                                    }
                                } label: {
                                    HStack {
                                        if let access = item.access {
                                            Image(systemName: access.isConcern ? "lock.open.fill" : access.level == .secured ? "lock.fill" : "lock.open")
                                                .font(.dante(size: 9))
                                                .foregroundStyle(access.isConcern ? theme.amber.color : access.level == .secured ? theme.green.color : theme.text3.color)
                                                .frame(width: 11)
                                        }
                                        ItemLine(item: item, isRoute: part.lane == .api)
                                        Spacer(minLength: 0)
                                        if item.file != nil {
                                            Image(systemName: "arrow.up.right").font(.dante(size: 9)).foregroundStyle(theme.text3.color)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(item.file == nil && !(part.kind == .database && map.part("table:" + item.text) != nil))
                                .help((item.access.map { $0.note + "\n" } ?? "") + help(for: item))
                                // Beside the row, not in it: a button inside a button gives the click to the row.
                                if part.lane == .clients, part.id.hasPrefix("client:"), part.kind == .web {
                                    IconButton(symbol: "safari", label: "Open \(item.text) in the browser", size: 10) {
                                        session.openInBrowser(folder: part.path ?? "", name: part.name, screen: (item.text, item.file))
                                    }
                                }
                            }
                        }
                    }
                }
                if let item = part.items.first, let file = item.file, let line = item.line, let end = item.end {
                    CodeExcerpt(url: workspace.url.appending(path: file), lines: line...max(line, end))
                }
                if let path = part.path, SystemMap.isCode(path) {
                    Button { session.open(file: workspace.url.appending(path: path)) } label: {
                        Label("Open \((path as NSString).lastPathComponent)", systemImage: "doc.text").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DanteButtonStyle())
                }
                if !part.env.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow("Environment")
                        ForEach(part.env, id: \.self) { name in
                            HStack(spacing: 6) {
                                Image(systemName: SystemMap.isSecret(name) ? "lock.fill" : "dollarsign")
                                    .font(.dante(size: 9.5))
                                    .foregroundStyle(SystemMap.isSecret(name) ? theme.amber.color : theme.text3.color)
                                    .frame(width: 12)
                                Text(name).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2.color).textSelection(.enabled)
                            }
                            .help(SystemMap.isSecret(name) ? "Looks like a secret: keep it out of the repo" : "")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    if let path = part.path { row("Path", path, mono: true) }
                    if let coverage { row("Coverage", "\(Int((coverage.fraction * 100).rounded()))% of \(coverage.total) lines") }
                    if let container = part.container { row("Runs in", "\(container) container", mono: false) }
                    row("Uses", map.uses(part.id).map(\.name).joined(separator: ", ").nonEmpty ?? "nothing found")
                    row("Used by", map.usedBy(part.id).map(\.name).joined(separator: ", ").nonEmpty ?? "nothing found")
                }
                if let open {
                    Button(action: open) {
                        Label(part.kind == .table ? "Trace back from \(part.name)" : "Open \(part.name)",
                              systemImage: part.kind == .table ? "arrow.uturn.left" : "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .help(part.kind == .table ? "See the code that reads and writes it, back through the services to the routes that reach it"
                          : "See the pieces inside it, how they connect, and the routes and tables each one owns")
                }
                Button {
                    session.askClaude(prompt)
                } label: {
                    ClaudeLabel("Ask \(session.agentName) to walk through it").frame(maxWidth: .infinity)
                }
                .buttonStyle(DanteButtonStyle(primary: open == nil))
            }
            .padding(20)
        }
        .background(theme.panel.color)
    }

    /// Puts text on the pasteboard and says so on the button for a moment.
    private func copy(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.snappy) { copied = what }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if copied == what { withAnimation(.snappy) { copied = nil } }
        }
    }

    /// A web frontend, or one of its screens, that can open in the browser.
    private var webApp: (client: SystemMap.Part, screen: (name: String, file: String?)?)? {
        guard part.lane == .clients, part.kind == .web else { return nil }
        if part.id.hasPrefix("client:") { return (part, nil) }
        guard let client = map.parts.first(where: { $0.id.hasPrefix("client:") && $0.items.contains { $0.file == part.path && $0.text == part.name } }) else { return nil }
        return (client, (part.name, part.path))
    }

    private func help(for item: SystemMap.Item) -> String {
        guard let file = item.file else { return "" }
        guard let line = item.line else { return "Open \(file)" }
        return "Open \(file):\(line)"
    }

    private var prompt: String {
        let users = map.usedBy(part.id).map(\.name).joined(separator: ", ")
        let uses = map.uses(part.id).map(\.name).joined(separator: ", ")
        switch part.lane {
        case .api:
            return "Walk me through the \(part.name) routes: what each one does, what it reads and writes, and how the frontend uses them. Routes: \(part.items.map(\.text).joined(separator: "; "))."
        case .outside:
            return "How does this project use \(part.name)? Show where it's called\(users.isEmpty ? "" : " (in \(users))"), what's sent, how failures and retries are handled, and where the credentials come from (without printing any)."
        case .data:
            return "Walk me through how the project uses \(part.name)\(users.isEmpty ? "" : " from \(users)"): the schema, where it's read and written, and migrations."
        default:
            return "Walk me through \(part.name)\(part.path.map { " (\($0))" } ?? ""): what it's responsible for and its main entry points\(uses.isEmpty ? "" : ", and how it uses \(uses)")."
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
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
}

/// A method's code in the inspector, read from disk, at most 40 lines.
private struct CodeExcerpt: View {
    @Environment(\.theme) private var theme
    let url: URL
    let lines: ClosedRange<Int>
    @State private var text: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow("Code")
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(text.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(lines.lowerBound + index)").foregroundStyle(theme.text3.color).frame(minWidth: 22, alignment: .trailing)
                            Text(line.isEmpty ? " " : line).foregroundStyle(theme.text2.color)
                        }
                        .font(.dante(size: 10.5, design: .monospaced))
                    }
                    if lines.count > text.count, !text.isEmpty {
                        Text("…").font(.dante(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3.color).padding(.leading, 30)
                    }
                }
                .padding(10)
            }
            .background(theme.card.color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line.color))
        }
        .task(id: url.path + "\(lines)") {
            let (url, lines) = (url, lines)
            text = await Task.detached {
                guard let all = try? String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n"), lines.lowerBound <= all.count else { return [] }
                let shown = Array(all[(lines.lowerBound - 1)..<min(lines.upperBound, all.count, lines.lowerBound + 39)])
                // Without the indentation they all share.
                let indent = shown.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
                return shown.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
            }.value
        }
    }
}

enum Breakable {
    /// "ShopPortalTargetGroup" may wrap between its words, and a path at its slashes.
    static func camel(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for character in name {
            if let previous, (character.isUppercase && previous.isLowercase) || previous == "/" || previous == "_" { result.append("\u{200B}") }
            result.append(character)
            previous = character
        }
        return result
    }
}

/// Opening a web app from the Map, step by step: how it runs, starting it (once the person
/// agrees), waiting for its port, and the page opening in the browser.
struct WebLaunchCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let launch: WebLaunch

    private enum Mark { case pending, active, done, skipped, failed }

    var body: some View {
        let target = launch.target
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow("Opening \(launch.screen ?? launch.name)" + (launch.theme.map { " in \($0.name)" } ?? ""))
                Spacer()
                IconButton(symbol: "xmark", label: launch.isDone ? "Dismiss" : "Cancel", size: 9) { session.cancelWebLaunch() }
            }
            row(mark(for: 0), "Find how \(launch.name) runs",
                target.map { "Port \(String($0.port)) (\($0.portSource)) · \($0.command)" } ?? "Reading its config…")
            if launch.wasRunning {
                row(.skipped, "Already running", "Port \(String(target?.port ?? 0)) is listening, so nothing needs starting.")
            } else {
                row(mark(for: 1), launch.installing ? "Install and start it" : "Start it", startDetail)
                if launch.step == .needsInstall, let target {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Its dependencies aren’t installed yet (no node_modules), so it would stop at once. Dante can run `\(target.tool) install` first, which downloads the packages its lockfile lists, then start it.")
                            .font(.dante(size: 12))
                            .foregroundStyle(theme.text2.color)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button { session.startAndOpen(installing: true) } label: {
                                Label("Install and start", systemImage: "arrow.down.circle").lineLimit(1).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(DanteButtonStyle(primary: true))
                            Button("Not now") { session.cancelWebLaunch() }
                                .buttonStyle(DanteButtonStyle())
                        }
                    }
                    .padding(.leading, 28)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if launch.step == .needsStart, let target {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(launch.name) isn’t running: nothing is listening on port \(String(target.port)). Dante will start it with `\(target.command)` in a new terminal tab, wait for it to come up, then open the page.")
                            .font(.dante(size: 12))
                            .foregroundStyle(theme.text2.color)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button { session.startAndOpen() } label: {
                                Label("Start it", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(DanteButtonStyle(primary: true))
                            Button("Not now") { session.cancelWebLaunch() }
                                .buttonStyle(DanteButtonStyle())
                        }
                    }
                    .padding(.leading, 28)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                row(mark(for: 2), "Wait for port \(String(target?.port ?? 0))",
                    launch.step == .waiting ? (launch.installing ? "Installing and starting · \(launch.waited) s" : "Waiting · \(launch.waited) s") : mark(for: 2) == .done ? "Up" : "")
            }
            row(mark(for: 3), "Open in your browser", target.map { (launch.pageURL ?? $0.url).absoluteString + ($0.routeFound || launch.screen == nil ? "" : " (its route wasn’t found, so the app’s home)") } ?? "")
            if case .failed(let message) = launch.step {
                Text(message).font(.dante(size: 12)).foregroundStyle(theme.red.color).fixedSize(horizontal: false, vertical: true)
                if launch.canInstall, let target {
                    Button { session.startAndOpen(installing: true) } label: {
                        Label("Install dependencies and try again", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .help("Runs `\(target.installCommand)`, then starts it again")
                }
                Button { session.showsTerminal = true } label: { Label("Show the terminal", systemImage: "terminal").frame(maxWidth: .infinity) }
                    .buttonStyle(DanteButtonStyle())
            }
            if launch.step == .opened, let target {
                Button { NSWorkspace.shared.open(target.url) } label: { Label("Open again", systemImage: "safari").frame(maxWidth: .infinity) }
                    .buttonStyle(DanteButtonStyle())
            }
        }
        .padding(14)
        .background(theme.card.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(launch.step == .opened ? theme.green.color.opacity(0.5) : theme.accentLine.color))
        .animation(.snappy(duration: 0.25), value: launch.step)
    }

    private var startDetail: String {
        switch launch.step {
        case .finding, .needsStart, .needsInstall: ""
        case .starting: launch.installing ? "Installing, then starting, in a terminal tab…" : "Running it in a terminal tab…"
        default: launch.target.map { "`\(Session.launchCommand($0, installing: launch.installing))` in the \($0.name) terminal tab" } ?? ""
        }
    }

    /// Steps: 0 find, 1 start, 2 wait, 3 open.
    private func mark(for index: Int) -> Mark {
        let current: Int
        switch launch.step {
        case .finding: current = 0
        case .needsStart, .needsInstall: current = 1
        case .starting: current = 1
        case .waiting: current = 2
        case .opening: current = 3
        case .opened: return .done
        case .failed: current = launch.target == nil ? 0 : launch.wasRunning ? 3 : 2
            if index == current { return .failed }
        }
        if index < current { return .done }
        if index == current { return launch.step == .needsStart || launch.step == .needsInstall ? .pending : .active }
        return .pending
    }

    private func row(_ mark: Mark, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                switch mark {
                case .active: ProgressView().controlSize(.small)
                case .done, .skipped: Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.green.color).transition(.scale.combined(with: .opacity))
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(theme.red.color)
                case .pending: Image(systemName: "circle").foregroundStyle(theme.text3.color)
                }
            }
            .font(.dante(size: 14))
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dante(size: 12.5, weight: mark == .active ? .semibold : .medium))
                    .foregroundStyle(mark == .pending ? theme.text3.color : theme.text.color)
                if !detail.isEmpty {
                    Text(detail).font(.dante(size: 11, design: detail.contains("http") || detail.contains("·") ? .monospaced : .default))
                        .foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }
}

/// A table from the repo's SQL: its columns and keys, where it's declared, what points at it,
/// and copying it at each level (a column, the table, a query).
private struct TableDetail: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let map: SystemMap
    let table: SystemMap.TableSchema
    @Binding var copied: String?
    let copy: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button { session.showInData(service: map.parts.first { $0.kind == .database }?.container, table: table.name) } label: {
                    Label("Browse in Data", systemImage: "tablecells").frame(maxWidth: .infinity)
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .help("Open \(table.name) in Local › Data and show its rows")
                CopyMenu(copied: copied, items: [
                    ("CREATE TABLE", "The CREATE TABLE and the migrations that changed it", table.ddl),
                    ("As Markdown", "A table of its columns, for docs and pull requests", table.markdown),
                    ("SELECT query", "SELECT its columns, LIMIT 100", table.select),
                    ("Column names", "Comma-separated", table.columns.map(\.name).joined(separator: ", ")),
                ], copy: copy)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Eyebrow("Columns")
                    Spacer()
                    Text("\(table.columns.count)").font(.dante(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                }
                ForEach(table.columns, id: \.name) { column in
                    ColumnRow(column: column) { copy($0, column.name) }
                }
            }
            if !table.referencedBy.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Referenced by")
                    ForEach(table.referencedBy, id: \.self) { reference in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.dante(size: 9)).foregroundStyle(theme.text3.color)
                            Text("\(reference.table).\(reference.column)").font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2.color)
                        }
                    }
                }
            }
            Button { session.open(file: workspace.url.appending(path: table.file), line: table.line) } label: {
                Label("\((table.file as NSString).lastPathComponent):\(table.line)", systemImage: "doc.text").frame(maxWidth: .infinity)
            }
            .buttonStyle(DanteButtonStyle())
            .help("Where its CREATE TABLE is: \(table.file)" + (table.statements.count > 1 ? ", changed by \(table.statements.count - 1) later statement\(table.statements.count == 2 ? "" : "s")" : ""))
        }
    }
}

/// One column: key marks, name and type, what it references. Right-click copies.
private struct ColumnRow: View {
    @Environment(\.theme) private var theme
    let column: SystemMap.Column
    let copy: (String) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: column.primaryKey ? "key.fill" : column.references != nil ? "link" : "circle.fill")
                .font(.dante(size: column.primaryKey || column.references != nil ? 9 : 4))
                .foregroundStyle(column.primaryKey ? theme.amber.color : column.references != nil ? theme.accent.color : theme.text3.color)
                .frame(width: 12)
            Text(column.name).font(.dante(size: 12, weight: column.primaryKey ? .semibold : .regular, design: .monospaced)).foregroundStyle(theme.text.color)
            Text(column.type).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
            if !column.notNull, !column.primaryKey { Text("null").font(.dante(size: 9.5)).foregroundStyle(theme.text3.color.opacity(0.7)) }
            Spacer(minLength: 4)
            if let target = column.references {
                Text("→ \(target)").font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.accent.color).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(hovering ? theme.raised.color : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Name") { copy(column.name) }
            Button("Copy Name and Type") { copy("\(column.name) \(column.type)") }
        }
        .help("Right-click to copy")
    }
}

/// The database as the repo's SQL defines it: every table's schema to copy, and Data.
private struct DatabaseDetail: View {
    @Environment(\.theme) private var theme
    let session: Session
    let part: SystemMap.Part
    let schema: [SystemMap.TableSchema]
    @Binding var copied: String?
    let copy: (String, String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { session.showInData(service: part.container) } label: {
                Label("Open in Data", systemImage: "cylinder.split.1x2").frame(maxWidth: .infinity)
            }
            .buttonStyle(DanteButtonStyle(primary: true))
            .help("Connect to it in Local › Data: browse tables, run queries and read plans")
            CopyMenu(copied: copied, items: [
                ("Whole schema", "Every table's CREATE TABLE, ALTERs and indexes (\(schema.count) tables)", schema.map(\.ddl).joined(separator: "\n\n")),
                ("ER diagram", "The tables and their foreign keys as Mermaid", "```mermaid\n" + SystemMap.mermaidER(schema) + "\n```"),
                ("As Markdown", "Each table's columns", schema.map(\.markdown).joined(separator: "\n\n")),
                ("Table names", "One per line", schema.map(\.name).joined(separator: "\n")),
            ], copy: copy)
        }
    }
}

/// A Copy button with a menu of what to copy; says "Copied" for a moment after.
private struct CopyMenu: View {
    @Environment(\.theme) private var theme
    let copied: String?
    let items: [(title: String, help: String, text: String)]
    let copy: (String, String) -> Void

    var body: some View {
        Menu {
            ForEach(items, id: \.title) { item in
                Button(item.title) { copy(item.text, item.title) }
                    .help(item.help)
            }
        } label: {
            Label(copied == nil ? "Copy" : "Copied", systemImage: copied == nil ? "doc.on.doc" : "checkmark")
                .contentTransition(.symbolEffect(.replace))
        }
        .menuStyle(.button)
        .buttonStyle(DanteButtonStyle())
        .fixedSize()
        .help(copied.map { "Copied \($0)" } ?? "Copy it as SQL, Markdown or a query")
    }
}

/// Who may call the group's routes: the open ones with why, and asking the agent about the
/// ones nothing explains.
private struct AccessSection: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let part: SystemMap.Part

    var body: some View {
        let routes = part.items.filter { $0.access != nil }
        let open = routes.filter { $0.access?.level == .open }
        let concerns = open.filter { $0.access?.isConcern == true }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow("Access")
                Spacer()
                Text(open.isEmpty ? "all \(routes.count) secured" : "\(open.count) of \(routes.count) open")
                    .font(.dante(size: 10.5)).foregroundStyle(concerns.isEmpty ? theme.text3.color : theme.amber.color)
            }
            ForEach(open, id: \.self) { item in
                if let access = item.access {
                    Button {
                        if let file = access.file ?? item.file { session.open(file: workspace.url.appending(path: file), line: access.line ?? item.line ?? 1) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: access.isConcern ? "exclamationmark.triangle.fill" : "checkmark.circle")
                                    .font(.dante(size: 10)).foregroundStyle(access.isConcern ? theme.amber.color : theme.green.color)
                                Text(item.text).font(.dante(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(theme.text.color).lineLimit(1)
                            }
                            Text(access.note).font(.dante(size: 11)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 16)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(access.isConcern ? theme.amber.color.opacity(0.08) : theme.raised.color.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open where this is decided")
                }
            }
            if !concerns.isEmpty {
                Button {
                    let list = concerns.map { "\($0.text) (\($0.file ?? "?"):\($0.line ?? 0)): \($0.access?.note ?? "")" }.joined(separator: "\n")
                    session.askClaude("These endpoints look open to anyone, with nothing in their paths to explain it. For each, check whether it should be public (and why), and if not, protect it the way the project protects its other endpoints. Ask before changing security configuration.\n\n" + list)
                } label: {
                    ClaudeLabel("Ask \(session.agentName) to check \(concerns.count == 1 ? "it" : "them")").frame(maxWidth: .infinity)
                }
                .buttonStyle(DanteButtonStyle())
            }
        }
    }
}
