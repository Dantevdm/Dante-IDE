import DanteKit
import SwiftUI

/// A ```mermaid block in Docs, drawn natively in the theme's colours. Kinds Dante can't
/// draw yet show their source.
struct MermaidBlock: View {
    @Environment(\.theme) private var theme
    @Environment(\.isExporting) private var isExporting
    let source: String
    @State private var showsSource = false

    var body: some View {
        let diagram = Mermaid.parse(source)
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch diagram {
                case .flowchart(let chart) where !showsSource: FlowchartView(chart: chart)
                case .sequence(let sequence) where !showsSource: SequenceView(diagram: sequence)
                case .entityRelationship(let er) where !showsSource: ERView(diagram: er)
                default: CodeBlock(text: source, language: "mermaid").padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 10.5))
                Text(caption(diagram))
                Spacer()
                if case .unsupported = diagram {} else if !isExporting {
                    Button(showsSource ? "Show diagram" : "Show source") { showsSource.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent.color)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.text3.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
        }
        .background(theme.panel.color)
        .background(DotGrid(color: theme.line2.color, spacing: 16))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
    }

    private func caption(_ diagram: Mermaid) -> String {
        switch diagram {
        case .flowchart: "Flowchart"
        case .sequence: "Sequence diagram"
        case .entityRelationship: "Data model"
        case .unsupported(let kind): "Mermaid \(kind.isEmpty ? "diagram" : kind): Dante draws flowcharts, sequence and ER diagrams, so this one shows as source"
        }
    }
}

/// Centred when the diagram fits the doc's width, scrolling sideways when it doesn't.
private struct FitOrScroll<Content: View>: View {
    @Environment(\.isExporting) private var isExporting
    @Environment(\.exportWidth) private var exportWidth
    @Environment(\.theme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        if isExporting {
            // Paper can't scroll, so a wide diagram is scaled down to the page.
            let natural = Self.size(of: content.fixedSize().environment(\.theme, theme))
            let scale = natural.width > exportWidth ? exportWidth / natural.width : 1
            content.fixedSize()
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: natural.width * scale, height: natural.height * scale, alignment: .topLeading)
                .frame(maxWidth: .infinity)
        } else {
            ViewThatFits(in: .horizontal) {
                content.frame(maxWidth: .infinity)
                ScrollView(.horizontal) { content }
            }
        }
    }

    @MainActor
    private static func size(of view: some View) -> CGSize {
        var size = CGSize.zero
        ImageRenderer(content: view).render { measured, _ in size = measured }
        return size
    }
}

private struct DiagramBoundsKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Shared drawing for arrows and their labels.
private enum Ink {
    static func arrowhead(at end: CGPoint, from control: CGPoint, color: Color, in context: inout GraphicsContext) {
        let angle = atan2(end.y - control.y, end.x - control.x)
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - 8 * cos(angle - 0.42), y: end.y - 8 * sin(angle - 0.42)))
        head.addLine(to: CGPoint(x: end.x - 8 * cos(angle + 0.42), y: end.y - 8 * sin(angle + 0.42)))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    static func label(_ text: String, at point: CGPoint, theme: Theme, in context: inout GraphicsContext) {
        let resolved = context.resolve(Text(text).font(.system(size: 11)).foregroundColor(theme.text2.color))
        let size = resolved.measure(in: CGSize(width: 180, height: 60))
        let box = CGRect(x: point.x - size.width / 2 - 5, y: point.y - size.height / 2 - 2, width: size.width + 10, height: size.height + 4)
        context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(theme.panel.color))
        context.draw(resolved, in: box.insetBy(dx: 5, dy: 2))
    }

    /// The point halfway along a cubic curve.
    static func midpoint(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: 0.125 * a.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * b.x,
                y: 0.125 * a.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * b.y)
    }
}

// MARK: Flowchart

private struct FlowchartView: View {
    @Environment(\.theme) private var theme
    let chart: Flowchart

    var body: some View {
        FitOrScroll {
            layout
                .padding(.horizontal, 28)
                .padding(.vertical, chart.groups.isEmpty ? 24 : 40)
                .backgroundPreferenceValue(DiagramBoundsKey.self) { anchors in
                    GeometryReader { proxy in
                        Canvas { context, _ in
                            let frames = anchors.mapValues { proxy[$0] }
                            drawGroups(frames, in: &context)
                            for edge in chart.edges { draw(edge, frames, in: &context) }
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var layout: some View {
        if chart.direction == .down {
            VStack(spacing: 54) {
                ForEach(Array(chart.layers.enumerated()), id: \.offset) { _, layer in
                    HStack(alignment: .center, spacing: 28) { ForEach(layer) { node($0) } }
                }
            }
        } else {
            HStack(alignment: .center, spacing: 76) {
                ForEach(Array(chart.layers.enumerated()), id: \.offset) { _, layer in
                    VStack(spacing: 24) { ForEach(layer) { node($0) } }
                }
            }
        }
    }

    private func node(_ node: Flowchart.Node) -> some View {
        // Short labels keep their own width; long ones wrap at 170pt. Circles stay round.
        let label = Text(node.label)
            .font(.system(size: 12.5))
            .foregroundStyle(theme.text.color)
            .multilineTextAlignment(.center)
        let wraps = node.label.count > 24
        let diameter = CGFloat(min(max(node.label.count, 4), 14)) * 6 + 30
        return Group {
            if node.shape == .circle {
                label.lineLimit(3).minimumScaleFactor(0.8).padding(8).frame(width: diameter, height: diameter)
            } else {
                Group {
                    if wraps { label.frame(width: 170).fixedSize(horizontal: false, vertical: true) } else { label.fixedSize() }
                }
                .padding(.horizontal, node.shape == .diamond ? 26 : 14)
                .padding(.vertical, node.shape == .diamond ? 16 : (node.shape == .database ? 14 : 9))
                .frame(minWidth: 72)
            }
        }
            .background { NodeShape(shape: node.shape).fill(theme.card.color) }
            .overlay { NodeShape(shape: node.shape).stroke(theme.line2.color, lineWidth: 1.2) }
            .anchorPreference(key: DiagramBoundsKey.self, value: .bounds) { [node.id: $0] }
    }

    private func drawGroups(_ frames: [String: CGRect], in context: inout GraphicsContext) {
        for group in chart.groups {
            let members = group.nodes.compactMap { frames[$0] }
            guard let first = members.first else { continue }
            let bounds = members.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -16, dy: -16).offsetBy(dx: 0, dy: -8)
            let box = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height + 8)
            let shape = Path(roundedRect: box, cornerRadius: 10)
            context.fill(shape, with: .color(theme.raised.opacity(0.6).color))
            context.stroke(shape, with: .color(theme.line2.color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            let title = context.resolve(Text(group.title).font(.system(size: 10.5, weight: .semibold)).foregroundColor(theme.text3.color))
            context.draw(title, at: CGPoint(x: box.minX + 10, y: box.minY + 9), anchor: .leading)
        }
    }

    private func draw(_ edge: Flowchart.Edge, _ frames: [String: CGRect], in context: inout GraphicsContext) {
        guard let from = frames[edge.from], let to = frames[edge.to] else { return }
        let down = chart.direction == .down
        let start: CGPoint, end: CGPoint, c1: CGPoint, c2: CGPoint
        let forward = down ? to.minY > from.maxY : to.minX > from.maxX
        if from == to {
            // A self-loop on the trailing side.
            start = down ? CGPoint(x: from.maxX, y: from.midY - 6) : CGPoint(x: from.midX - 6, y: from.maxY)
            end = down ? CGPoint(x: from.maxX, y: from.midY + 6) : CGPoint(x: from.midX + 6, y: from.maxY)
            c1 = down ? CGPoint(x: start.x + 40, y: start.y - 20) : CGPoint(x: start.x - 20, y: start.y + 40)
            c2 = down ? CGPoint(x: end.x + 40, y: end.y + 20) : CGPoint(x: end.x + 20, y: end.y + 40)
        } else if forward {
            start = down ? CGPoint(x: from.midX, y: from.maxY) : CGPoint(x: from.maxX, y: from.midY)
            end = down ? CGPoint(x: to.midX, y: to.minY - 1) : CGPoint(x: to.minX - 1, y: to.midY)
            let bend = down ? (end.y - start.y) / 2 : (end.x - start.x) / 2
            c1 = down ? CGPoint(x: start.x, y: start.y + bend) : CGPoint(x: start.x + bend, y: start.y)
            c2 = down ? CGPoint(x: end.x, y: end.y - bend) : CGPoint(x: end.x - bend, y: end.y)
        } else {
            // Back or sideways edge: loop around the outside so it doesn't cut through boxes.
            start = down ? CGPoint(x: from.maxX, y: from.midY) : CGPoint(x: from.midX, y: from.maxY)
            end = down ? CGPoint(x: to.maxX + 1, y: to.midY) : CGPoint(x: to.midX, y: to.maxY + 1)
            let reach: CGFloat = 46
            c1 = down ? CGPoint(x: max(start.x, end.x) + reach, y: start.y) : CGPoint(x: start.x, y: max(start.y, end.y) + reach)
            c2 = down ? CGPoint(x: max(start.x, end.x) + reach, y: end.y) : CGPoint(x: end.x, y: max(start.y, end.y) + reach)
        }
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        let color = edge.style == .thick ? theme.text2.color : theme.text3.color
        let style = StrokeStyle(lineWidth: edge.style == .thick ? 2.4 : 1.3, lineCap: .round, dash: edge.style == .dotted ? [3, 4] : [])
        context.stroke(path, with: .color(color), style: style)
        if edge.arrow { Ink.arrowhead(at: end, from: c2, color: color, in: &context) }
        if let label = edge.label { Ink.label(label, at: Ink.midpoint(start, c1, c2, end), theme: theme, in: &context) }
    }
}

private struct NodeShape: Shape {
    let shape: Flowchart.Node.Shape

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .box:
            return Path(roundedRect: rect, cornerRadius: 6)
        case .round:
            return Path(roundedRect: rect, cornerRadius: rect.height / 2)
        case .circle:
            return Path(ellipseIn: rect)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        case .database:
            let lip: CGFloat = 6
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + lip))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - lip))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - lip), control: CGPoint(x: rect.midX, y: rect.maxY + lip))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + lip))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + lip), control: CGPoint(x: rect.midX, y: rect.minY - lip))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + lip), control: CGPoint(x: rect.midX, y: rect.minY + lip * 3))
            return path
        }
    }
}

// MARK: Sequence

private struct SequenceView: View {
    @Environment(\.theme) private var theme
    let diagram: SequenceDiagram

    private let column: CGFloat = 170
    private let headerHeight: CGFloat = 34
    private let margin: CGFloat = 20

    private func rowHeight(_ item: SequenceDiagram.Item) -> CGFloat {
        switch item {
        case .message(let from, let to, _, _, _): from == to ? 52 : 40
        case .note: 42
        case .blockStart: 28
        case .blockEnd: 12
        }
    }

    private var height: CGFloat {
        headerHeight * 2 + diagram.items.map(rowHeight).reduce(0, +) + 36
    }

    private func x(_ id: String) -> CGFloat {
        margin + CGFloat(diagram.index(of: id) ?? 0) * column + column / 2
    }

    var body: some View {
        let width = margin * 2 + CGFloat(max(diagram.participants.count, 1)) * column
        FitOrScroll {
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(width: width, height: height)
                .padding(.vertical, 8)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let top: CGFloat = 4
        let bottom = size.height - headerHeight - 4
        // Lifelines, then participant boxes top and bottom.
        for participant in diagram.participants {
            var line = Path()
            line.move(to: CGPoint(x: x(participant.id), y: top + headerHeight))
            line.addLine(to: CGPoint(x: x(participant.id), y: bottom))
            context.stroke(line, with: .color(theme.line2.color), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            for y in [top, bottom] { box(participant, y: y, in: &context) }
        }
        var y = top + headerHeight + 14
        var blocks: [(kind: String, label: String, top: CGFloat)] = []
        let left = margin / 2, right = size.width - margin / 2
        for item in diagram.items {
            let height = rowHeight(item)
            switch item {
            case .message(let from, let to, let text, let dashed, let arrow):
                let color = theme.text2.color
                let style = StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: dashed ? [5, 4] : [])
                var path = Path()
                if from == to {
                    let x0 = x(from)
                    path.move(to: CGPoint(x: x0, y: y + 16))
                    path.addCurve(to: CGPoint(x: x0 + 2, y: y + 40), control1: CGPoint(x: x0 + 50, y: y + 14), control2: CGPoint(x: x0 + 50, y: y + 42))
                    context.stroke(path, with: .color(color), style: style)
                    if arrow { Ink.arrowhead(at: CGPoint(x: x0 + 2, y: y + 40), from: CGPoint(x: x0 + 40, y: y + 42), color: color, in: &context) }
                    draw(text, at: CGPoint(x: x0 + 8, y: y + 6), anchor: .leading, in: &context)
                } else {
                    let start = CGPoint(x: x(from), y: y + 26), end = CGPoint(x: x(to) + (x(to) > x(from) ? -1 : 1), y: y + 26)
                    path.move(to: start)
                    path.addLine(to: end)
                    context.stroke(path, with: .color(color), style: style)
                    if arrow { Ink.arrowhead(at: end, from: start, color: color, in: &context) }
                    draw(text, at: CGPoint(x: (start.x + end.x) / 2, y: y + 14), anchor: .center, in: &context)
                }
            case .note(let over, let text):
                let xs = over.map(x)
                let minX = (xs.min() ?? margin) - (over.count > 1 ? 30 : 60), maxX = (xs.max() ?? margin) + (over.count > 1 ? 30 : 60)
                let rect = CGRect(x: minX, y: y + 6, width: maxX - minX, height: height - 12)
                context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(theme.amber.opacity(0.14).color))
                context.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(theme.amber.opacity(0.5).color), lineWidth: 1)
                draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center, in: &context)
            case .blockStart(let kind, let label):
                blocks.append((kind, label, y))
            case .blockEnd:
                guard let block = blocks.popLast() else { break }
                let rect = CGRect(x: left + CGFloat(blocks.count) * 6, y: block.top, width: right - left - CGFloat(blocks.count) * 12, height: y - block.top + 6)
                context.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(theme.accentLine.color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                let tag = context.resolve(Text(block.kind).font(.system(size: 10.5, weight: .semibold)).foregroundColor(theme.accent.color))
                let tagSize = tag.measure(in: CGSize(width: 100, height: 20))
                let tagRect = CGRect(x: rect.minX, y: rect.minY, width: tagSize.width + 12, height: 18)
                context.fill(Path(roundedRect: tagRect, cornerRadius: 5), with: .color(theme.accentTint.color))
                context.draw(tag, at: CGPoint(x: tagRect.midX, y: tagRect.midY))
                if !block.label.isEmpty {
                    draw("[\(block.label)]", at: CGPoint(x: tagRect.maxX + 6, y: tagRect.midY), anchor: .leading, in: &context)
                }
            }
            y += height
        }
    }

    private func box(_ participant: SequenceDiagram.Participant, y: CGFloat, in context: inout GraphicsContext) {
        let rect = CGRect(x: x(participant.id) - column / 2 + 12, y: y, width: column - 24, height: headerHeight)
        context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(theme.card.color))
        context.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(participant.isActor ? theme.accentLine.color : theme.line2.color), lineWidth: 1.2)
        let label = context.resolve(Text((participant.isActor ? "👤 " : "") + participant.label).font(.system(size: 12, weight: .semibold)).foregroundColor(theme.text.color))
        context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    private func draw(_ text: String, at point: CGPoint, anchor: UnitPoint, in context: inout GraphicsContext) {
        let resolved = context.resolve(Text(text).font(.system(size: 11.5)).foregroundColor(theme.text.color))
        context.draw(resolved, at: point, anchor: anchor)
    }
}

// MARK: Entity relationship

private struct ERView: View {
    @Environment(\.theme) private var theme
    let diagram: ERDiagram

    var body: some View {
        FitOrScroll {
            // Top-down, so a chain of tables fits the width of a doc.
            VStack(spacing: 78) {
                ForEach(Array(diagram.layers.enumerated()), id: \.offset) { _, layer in
                    HStack(alignment: .top, spacing: 64) { ForEach(layer) { entity($0) } }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .backgroundPreferenceValue(DiagramBoundsKey.self) { anchors in
                GeometryReader { proxy in
                    Canvas { context, _ in
                        let frames = anchors.mapValues { proxy[$0] }
                        for relationship in diagram.relationships { draw(relationship, frames, in: &context) }
                    }
                }
            }
        }
    }

    private func entity(_ entity: ERDiagram.Entity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entity.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.raised.color)
            ForEach(Array(entity.attributes.enumerated()), id: \.offset) { _, attribute in
                HStack(spacing: 8) {
                    Text(attribute.name).foregroundStyle(theme.text.color)
                    Spacer(minLength: 8)
                    Text(attribute.type).foregroundStyle(theme.text3.color)
                    if !attribute.keys.isEmpty {
                        Text(attribute.keys.joined(separator: ",")).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.accent.color)
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
            }
        }
        .frame(minWidth: 150, alignment: .leading)
        .fixedSize()
        .background(theme.card.color)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.line2.color, lineWidth: 1.2))
        .anchorPreference(key: DiagramBoundsKey.self, value: .bounds) { [entity.name: $0] }
    }

    private func draw(_ relationship: ERDiagram.Relationship, _ frames: [String: CGRect], in context: inout GraphicsContext) {
        guard let from = frames[relationship.from], let to = frames[relationship.to] else { return }
        let start: CGPoint, end: CGPoint, c1: CGPoint, c2: CGPoint
        let fromLabel: CGPoint, toLabel: CGPoint
        if to.minY > from.maxY || from.minY > to.maxY {
            let down = to.minY > from.maxY
            start = CGPoint(x: from.midX, y: down ? from.maxY : from.minY)
            end = CGPoint(x: to.midX, y: down ? to.minY : to.maxY)
            let bend = (end.y - start.y) / 2
            c1 = CGPoint(x: start.x, y: start.y + bend)
            c2 = CGPoint(x: end.x, y: end.y - bend)
            let step: CGFloat = down ? 11 : -11
            fromLabel = CGPoint(x: start.x + 16, y: start.y + step)
            toLabel = CGPoint(x: end.x + 16, y: end.y - step)
        } else {
            let rightward = to.midX >= from.midX
            start = CGPoint(x: rightward ? from.maxX : from.minX, y: from.midY)
            end = CGPoint(x: rightward ? to.minX : to.maxX, y: to.midY)
            let bend = (end.x - start.x) / 2
            c1 = CGPoint(x: start.x + bend, y: start.y)
            c2 = CGPoint(x: end.x - bend, y: end.y)
            let step: CGFloat = rightward ? 14 : -14
            fromLabel = CGPoint(x: start.x + step, y: start.y - 9)
            toLabel = CGPoint(x: end.x - step, y: end.y - 9)
        }
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        context.stroke(path, with: .color(theme.text3.color), lineWidth: 1.3)
        cardinality(relationship.fromCardinality, at: fromLabel, in: &context)
        cardinality(relationship.toCardinality, at: toLabel, in: &context)
        if !relationship.label.isEmpty {
            Ink.label(relationship.label, at: Ink.midpoint(start, c1, c2, end), theme: theme, in: &context)
        }
    }

    private func cardinality(_ text: String, at point: CGPoint, in context: inout GraphicsContext) {
        let resolved = context.resolve(Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(theme.accent.color))
        context.draw(resolved, at: point)
    }
}
