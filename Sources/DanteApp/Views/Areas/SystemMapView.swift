import DanteKit
import SwiftUI

/// The System map: lanes from the screens people use, through the API and the backend, to
/// the data and outside services, with arrows along the real calls.
struct SystemDiagram: View {
    @Environment(\.theme) private var theme
    let map: SystemMap
    @Binding var selected: String?

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
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: Self.gap) {
                    ForEach(columns, id: \.first!.lane) { column in
                        LaneHeader(lane: column[0].lane, count: column[0].parts.count).frame(width: Self.width, alignment: .leading)
                    }
                }
                // Columns centre on each other so arrows between short and long ones stay level.
                HStack(alignment: .center, spacing: Self.gap) {
                    ForEach(columns, id: \.first!.lane) { column in
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(column.enumerated()), id: \.element.lane) { index, section in
                                if index > 0 {
                                    LaneHeader(lane: section.lane, count: section.parts.count).padding(.top, 10)
                                }
                                ForEach(section.parts) { part in
                                    PartBox(part: part, state: state(of: part), hue: hue(section.lane), showsContainer: showsContainer(part)) {
                                        selected = selected == part.id ? nil : part.id
                                    }
                                    .anchorPreference(key: PartBoundsKey.self, value: .bounds) { [part.id: $0] }
                                }
                            }
                        }
                        .frame(width: Self.width)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 52)
            .backgroundPreferenceValue(PartBoundsKey.self) { anchors in
                GeometryReader { proxy in
                    Canvas { context, _ in
                        let heaviest = max(map.links.map(\.weight).max() ?? 1, 1)
                        for link in map.links {
                            guard let from = anchors[link.from].map({ proxy[$0] }), let to = anchors[link.to].map({ proxy[$0] }) else { continue }
                            let highlighted = selected != nil && (link.from == selected || link.to == selected)
                            let dimmed = selected != nil && !highlighted
                            let color = highlighted ? theme.accent.color : theme.line2.color.opacity(dimmed ? 0.35 : 1)
                            let width = 1.1 + 1.6 * CGFloat(link.weight) / CGFloat(heaviest)
                            arrow(from: from, to: to, color: color, width: highlighted ? width + 0.6 : width, in: &context)
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
            Text("Arrows follow calls and imports; thicker means more of them. Select a box to trace it.")
                .font(.dante(size: 11))
                .foregroundStyle(theme.text3.color)
                .padding(12)
        }
    }

    enum PartState { case normal, selected, related, dimmed }

    private func state(of part: SystemMap.Part) -> PartState {
        guard let selected else { return .normal }
        if part.id == selected { return .selected }
        let related = map.links.contains { ($0.from == selected && $0.to == part.id) || ($0.to == selected && $0.from == part.id) }
        return related ? .related : .dimmed
    }

    func hue(_ lane: SystemMap.Lane) -> Color {
        switch lane {
        case .clients: theme.accent.color
        case .api: theme.syntax.keyword.color
        case .backend: theme.syntax.type.color
        case .data: theme.amber.color
        case .outside: theme.syntax.string.color
        }
    }

    /// Between lanes: a curve from the right edge to the left edge. Within a lane: a loop
    /// out to the right, so it doesn't run under the boxes in between.
    private func arrow(from: CGRect, to: CGRect, color: Color, width: CGFloat, in context: inout GraphicsContext) {
        var path = Path()
        let end: CGPoint
        let angle: CGFloat
        if to.minX > from.maxX {
            let start = CGPoint(x: from.maxX, y: from.midY)
            end = CGPoint(x: to.minX - 2, y: to.midY)
            let bend = max((end.x - start.x) / 2, 30)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
            angle = 0
        } else if to.maxX < from.minX {
            let start = CGPoint(x: from.minX, y: from.midY)
            end = CGPoint(x: to.maxX + 2, y: to.midY)
            let bend = max((start.x - end.x) / 2, 30)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x - bend, y: start.y), control2: CGPoint(x: end.x + bend, y: end.y))
            angle = .pi
        } else {
            let start = CGPoint(x: from.maxX, y: from.midY)
            end = CGPoint(x: to.maxX + 2, y: to.midY)
            let reach = 22 + min(abs(end.y - start.y) / 8, 18)
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x + reach, y: start.y), control2: CGPoint(x: end.x + reach, y: end.y))
            angle = .pi
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - 7 * cos(angle - 0.45), y: end.y - 7 * sin(angle - 0.45)))
        head.addLine(to: CGPoint(x: end.x - 7 * cos(angle + 0.45), y: end.y - 7 * sin(angle + 0.45)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}

private struct PartBoundsKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct LaneHeader: View {
    @Environment(\.theme) private var theme
    let lane: SystemMap.Lane
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(lane.title.uppercased())
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

private struct PartBox: View {
    @Environment(\.theme) private var theme
    let part: SystemMap.Part
    let state: SystemDiagram.PartState
    let hue: Color
    var showsContainer = true
    let action: () -> Void
    @State private var hovering = false

    private let shown = 8

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: PartBox.symbol(part.kind))
                        .font(.dante(size: 11, weight: .semibold))
                        .foregroundStyle(hue)
                        .frame(width: 22, height: 22)
                        .background(hue.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(part.name)
                            .font(.dante(size: 13, weight: .semibold, design: part.lane == .api ? .monospaced : .default))
                            .foregroundStyle(theme.text.color)
                            .lineLimit(part.lane == .api ? 1 : 2)
                            .truncationMode(part.lane == .api ? .middle : .tail)
                            .fixedSize(horizontal: false, vertical: true)
                        if !part.detail.isEmpty {
                            Text(part.detail).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
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
                if showsContainer, let container = part.container {
                    HStack(spacing: 4) {
                        Image(systemName: "shippingbox").font(.dante(size: 9))
                        Text(container).font(.dante(size: 10.5, design: .monospaced))
                    }
                    .foregroundStyle(theme.text3.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.raised.color, in: Capsule())
                    .padding(.leading, 29)
                    .help("Runs in the \(container) container")
                }
            }
            .padding(10)
            .frame(width: SystemDiagram.width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(state == .selected ? theme.accentTint.color : theme.card.color))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, style: .continuous)
                    .fill(hue)
                    .frame(width: 3)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(border, style: StrokeStyle(lineWidth: state == .selected ? 1.6 : 1, dash: part.lane == .outside ? [4, 3] : []))
            )
            .opacity(state == .dimmed ? 0.4 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: state == .dimmed)
    }

    private var border: Color {
        if state == .selected { return theme.accent.color }
        if hovering || state == .related { return theme.accentLine.color }
        return theme.line2.color
    }

    static func symbol(_ kind: SystemMap.Kind) -> String {
        switch kind {
        case .web: "macwindow"
        case .mobile: "iphone"
        case .routes: "arrow.left.arrow.right"
        case .app: "terminal"
        case .package: "shippingbox"
        case .database: "cylinder.split.1x2"
        case .cache: "bolt.horizontal"
        case .container: "cube"
        case .email: "envelope"
        case .messaging: "bubble.left.and.bubble.right"
        case .ai: "sparkles"
        case .payments: "creditcard"
        case .storage: "externaldrive"
        case .monitoring: "waveform.path.ecg"
        case .service: "globe"
        }
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

    var body: some View {
        let clients = map.parts.filter { $0.lane == .clients && !$0.id.hasPrefix("screen:") }
        let screens = clients.reduce(0) { $0 + $1.items.count }
        let stats: [(String, String, String)] = [
            ("\(clients.count)", "client" + (clients.count == 1 ? "" : "s"), screens > 0 ? "\(screens) screens" : ""),
            ("\(map.routeCount)", "API routes", "\(map.parts.filter { $0.lane == .api }.count) groups"),
            ("\(map.parts.filter { $0.lane == .backend }.count)", "backend parts", ""),
            ("\(map.parts.filter { $0.lane == .data }.count)", "data stores", map.parts.filter { $0.lane == .data }.map(\.name).joined(separator: ", ")),
            ("\(map.parts.filter { $0.lane == .outside }.count)", "outside services", map.parts.filter { $0.lane == .outside }.map(\.name).prefix(3).joined(separator: ", ")),
        ]
        HStack(spacing: 10) {
            ForEach(stats, id: \.1) { value, label, note in
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
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Eyebrow(part.lane.title)
                    Spacer()
                    IconButton(symbol: "xmark", label: "Close", size: 10, action: close)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(part.name).font(.dante(size: 18, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(part.detail).font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                if !part.items.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(part.lane == .api ? "Routes" : part.lane == .clients ? "Screens" : "Inside")
                        ForEach(part.items, id: \.self) { item in
                            Button {
                                if let file = item.file { session.open(file: workspace.url.appending(path: file), line: item.line ?? 1) }
                            } label: {
                                HStack {
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
                            .disabled(item.file == nil)
                            .help(help(for: item))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    if let path = part.path { row("Path", path, mono: true) }
                    if let container = part.container { row("Runs in", "\(container) container", mono: false) }
                    row("Uses", map.uses(part.id).map(\.name).joined(separator: ", ").nonEmpty ?? "nothing found")
                    row("Used by", map.usedBy(part.id).map(\.name).joined(separator: ", ").nonEmpty ?? "nothing found")
                }
                Button {
                    session.askClaude(prompt)
                } label: {
                    Label("Ask Claude to walk through it", systemImage: "sparkle").frame(maxWidth: .infinity)
                }
                .buttonStyle(DanteButtonStyle(primary: true))
            }
            .padding(20)
        }
        .background(theme.panel.color)
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
