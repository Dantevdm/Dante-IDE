import DanteKit
import SwiftUI

/// A small picture of how things connect, in the Infra view's ink: nodes in columns (what
/// something leads to sits to its right, `FlowColumns`), links as curves whose dashes flow
/// and carry a packet while they're live, red where something failed, faint when idle.
/// Services, Tests and Agents draw with it.
struct FlowGraph: View {
    struct Node: Identifiable {
        var id: String
        var title: String
        var detail = ""
        var symbol: String
        var state: State = .idle
        var tint: Color?
        /// A column of its own; nil works it out from the links.
        var column: Int?
    }

    struct Link: Identifiable {
        var from: String
        var to: String
        var label = ""
        var state: State = .idle
        var id: String { "\(from)→\(to)" }
    }

    enum State { case idle, live, good, bad, off }

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let nodes: [Node]
    let links: [Link]
    var nodeWidth: CGFloat = 176
    var select: ((String) -> Void)?

    private static let nodeHeight: CGFloat = 46
    private static let rowGap: CGFloat = 14

    private var placed: [Int: [Node]] {
        let derived = FlowColumns.columns(nodes: nodes.map(\.id), links: links.map { ($0.from, $0.to) })
        return Dictionary(grouping: nodes) { $0.column ?? derived[$0.id] ?? 0 }
    }

    var body: some View {
        let columns = placed
        let tallest = columns.values.map(\.count).max() ?? 1
        let height = CGFloat(tallest) * Self.nodeHeight + CGFloat(max(0, tallest - 1)) * Self.rowGap + 24
        GeometryReader { proxy in
            let frames = layout(columns, size: proxy.size)
            let live = links.contains { $0.state == .live } || nodes.contains { $0.state == .live }
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !live || reduceMotion)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    Canvas { canvas, _ in
                        for (index, link) in links.enumerated() {
                            guard let from = frames[link.from], let to = frames[link.to] else { continue }
                            draw(link, from: from, to: to, time: time + Double(index) * 0.37, in: &canvas)
                        }
                    }
                }
                ForEach(nodes) { node in
                    if let frame = frames[node.id] {
                        face(node)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
        }
        .frame(height: height)
    }

    private func layout(_ columns: [Int: [Node]], size: CGSize) -> [String: CGRect] {
        let keys = columns.keys.sorted()
        guard !keys.isEmpty else { return [:] }
        let width = min(nodeWidth, (size.width - CGFloat(keys.count - 1) * 28) / CGFloat(keys.count))
        let step = keys.count > 1 ? (size.width - width) / CGFloat(keys.count - 1) : 0
        var frames: [String: CGRect] = [:]
        for (position, key) in keys.enumerated() {
            let members = columns[key] ?? []
            let total = CGFloat(members.count) * Self.nodeHeight + CGFloat(max(0, members.count - 1)) * Self.rowGap
            var y = (size.height - total) / 2
            let x = keys.count > 1 ? CGFloat(position) * step : (size.width - width) / 2
            for node in members {
                frames[node.id] = CGRect(x: x, y: y, width: width, height: Self.nodeHeight)
                y += Self.nodeHeight + Self.rowGap
            }
        }
        return frames
    }

    private func color(_ state: State, tint: Color? = nil) -> Color {
        switch state {
        case .live: tint ?? theme.accent.color
        case .good: theme.green.color
        case .bad: theme.red.color
        case .idle: tint ?? theme.text3.color
        case .off: theme.text3.color
        }
    }

    private func draw(_ link: Link, from: CGRect, to: CGRect, time: Double, in context: inout GraphicsContext) {
        let path = MapInk.path(LinkCurve.direct(from, to))
        let color = color(link.state)
        switch link.state {
        case .live:
            MapInk.stroke(path, color: color.opacity(0.25), width: 1.4, in: &context)
            MapInk.stroke(path, color: color.opacity(0.8), width: 1.4, dash: [5, 6], phase: reduceMotion ? 0 : -time * 22, in: &context)
            if !reduceMotion { MapInk.pulse(path, time: time, color: color, in: &context) }
        case .bad:
            MapInk.stroke(path, color: color.opacity(0.7), width: 1.4, dash: [3, 4], in: &context)
        case .off:
            MapInk.stroke(path, color: theme.line.color, width: 1.2, dash: [2, 5], in: &context)
        case .idle, .good:
            MapInk.stroke(path, color: link.state == .good ? color.opacity(0.55) : theme.line2.color, width: 1.3, in: &context)
        }
        MapInk.arrowhead(path, color: link.state == .idle || link.state == .off ? theme.line2.color : color, in: &context)
        if !link.label.isEmpty { MapInk.label(link.label, on: path, theme: theme, emphasised: link.state == .live, in: &context) }
    }

    @ViewBuilder
    private func face(_ node: Node) -> some View {
        let accent = color(node.state, tint: node.tint)
        let body = HStack(spacing: 8) {
            Image(systemName: node.symbol)
                .font(.dante(size: 11.5, weight: .medium))
                .foregroundStyle(node.state == .off ? theme.text3.color : accent)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent.opacity(node.state == .off ? 0.06 : 0.13)))
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).font(.dante(size: 12, weight: .semibold)).foregroundStyle(node.state == .off ? theme.text3.color : theme.text.color).lineLimit(1)
                if !node.detail.isEmpty {
                    Text(node.detail).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(node.state == .live || node.state == .bad ? accent.opacity(0.6) : theme.line.color, lineWidth: node.state == .live ? 1.4 : 1))
        .help(node.detail.isEmpty ? node.title : "\(node.title): \(node.detail)")
        if let select {
            Button { select(node.id) } label: { body.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            body
        }
    }
}
