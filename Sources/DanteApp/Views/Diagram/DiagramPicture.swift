import DanteKit
import SwiftUI

/// A diagram drawn in the Map's style: containers at the back, then the links with their
/// pulses, then everything else. The editor draws it under its handles; Docs' thumbnails
/// and the PNG and PDF exports draw it still.
struct DiagramPicture: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let diagram: Diagram
    /// The diagram point drawn at the view's top-left.
    var origin: CGPoint = .zero
    var size: CGSize
    var animated = true
    /// Lit like a selected link on the Map.
    var selectedLinks: Set<String> = []
    /// Nodes under the pointer: their borders warm up as on the Map.
    var hovered: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(diagram.drawingOrder.filter(\.kind.isContainer)) { node in place(node) }
            links
            ForEach(diagram.drawingOrder.filter { !$0.kind.isContainer }) { node in place(node) }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func place(_ node: Diagram.Node) -> some View {
        let rect = node.rect
        return DiagramNodeView(node: node, count: diagram.count(of: node.id), hovered: hovered == node.id)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .offset(x: rect.minX - origin.x, y: rect.minY - origin.y)
    }

    @ViewBuilder private var links: some View {
        if animated && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                canvas(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            // Still: each pulse caught partway along, so a picture still shows the traffic.
            canvas(time: 1.3)
        }
    }

    private func canvas(time: Double) -> some View {
        Canvas { context, _ in
            context.translateBy(x: -origin.x, y: -origin.y)
            Self.drawLinks(diagram, selected: selectedLinks, theme: theme, time: time, in: &context)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// Every link: its line, arrowhead, pulse and label.
    static func drawLinks(_ diagram: Diagram, selected: Set<String>, theme: Theme, time: Double, in context: inout GraphicsContext) {
        for (index, link) in diagram.drawableLinks.enumerated() {
            guard let from = diagram.node(link.from), let to = diagram.node(link.to) else { continue }
            let path = MapInk.path(.route(link.route, from.rect, to.rect))
            let lit = selected.contains(link.id)
            let base = link.hue.map { $0.rgba(theme).color.opacity(0.85) } ?? theme.line2.color
            let color = lit ? theme.accent.color : base
            let width = CGFloat(link.width) + (lit ? 0.6 : 0)
            switch link.line {
            case .solid: MapInk.stroke(path, color: color, width: width, in: &context)
            case .dashed: MapInk.stroke(path, color: color, width: width, dash: [5, 4], in: &context)
            case .flowing: MapInk.stroke(path, color: color, width: width, dash: [6, 6], phase: -time * 22, in: &context)
            }
            if link.arrow { MapInk.arrowhead(path, color: lit ? theme.accent.color : (link.hue?.rgba(theme).color ?? theme.line2.color), in: &context) }
            if link.pulse {
                let hue = (link.hue ?? to.hue).rgba(theme).color
                MapInk.pulse(path, time: time + Double(index % 7) * 0.33, color: lit ? theme.accent.color : hue, in: &context)
            }
            MapInk.label(link.label, on: path, theme: theme, emphasised: lit, in: &context)
        }
    }
}

/// One node, drawn with the same pieces as the Map.
struct DiagramNodeView: View {
    @Environment(\.theme) private var theme
    let node: Diagram.Node
    let count: Int
    var hovered = false

    var body: some View {
        let hue = node.hue.rgba(theme).color
        let rect = node.rect
        switch node.kind {
        case .card:
            ResourceFace(icon: node.icon, title: node.title, kind: node.subtitle, detail: node.detail, hue: hue, dashed: node.dashed,
                         emphasised: hovered, width: rect.width, height: rect.height)
        case .box:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    PartIcon(symbol: node.icon, hue: hue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Breakable.camel(node.title))
                            .font(.dante(size: 13, weight: .semibold))
                            .foregroundStyle(theme.text.color)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if !node.subtitle.isEmpty {
                            Text(node.subtitle).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !node.text.isEmpty {
                    Text(node.text)
                        .font(.dante(size: 10.5))
                        .foregroundStyle(theme.text2.color)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 29)
                }
                if !node.chips.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(node.chips.prefix(3).enumerated()), id: \.offset) { _, chip in
                            MapChip(text: chip, symbol: node.icon == "cylinder.split.1x2" ? "cylinder.split.1x2" : "shippingbox")
                        }
                    }
                    .padding(.leading, 29)
                }
            }
            .padding(10)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .modifier(PartChrome(hue: hue, emphasised: hovered, dashed: node.dashed))
        case .group:
            GroupHeader(symbol: node.icon, title: node.title, count: count, hue: hue)
                .padding(12)
                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                .modifier(GroupPanel(hue: hue, dashed: node.dashed))
        case .boundary:
            VStack(alignment: .leading, spacing: 0) {
                BandTitle(symbol: node.icon, title: node.title, note: node.subtitle)
                    .frame(height: Diagram.boundaryTitleRoom - 12, alignment: .top)
                    .padding(.bottom, 12)
                Color.clear.modifier(BoundaryPanel())
            }
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        case .person:
            PeopleBadge(symbol: node.icon, title: node.title)
                .frame(width: rect.width, height: rect.height, alignment: .top)
        case .stage:
            StageFace(symbol: node.icon, title: node.title, environment: node.subtitle, steps: node.icons.map { ($0, "") },
                      emphasised: hovered, dashed: node.dashed, width: rect.width, height: rect.height)
        case .source:
            SourceFace(symbol: node.icon, title: node.title, system: node.subtitle, branches: node.chips, environment: node.tag,
                       width: rect.width, height: rect.height)
        case .title:
            BandTitle(symbol: node.icon, title: node.title, note: node.subtitle)
                .frame(width: rect.width, height: rect.height, alignment: .leading)
        case .text:
            Text(node.text.isEmpty ? node.title : node.text)
                .font(.dante(size: 12.5))
                .foregroundStyle(theme.text2.color)
                .lineSpacing(2)
                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        }
    }
}

/// The picture on its backdrop, still, for thumbnails and exports.
struct DiagramStill: View {
    @Environment(\.theme) private var theme
    let diagram: Diagram
    var padding: CGFloat = 32
    var showsTitle = false

    var frame: CGRect {
        let bounds = diagram.bounds.isNull ? CGRect(x: 0, y: 0, width: 240, height: 140) : diagram.bounds
        return bounds.insetBy(dx: -padding, dy: -padding)
    }

    var body: some View {
        let frame = frame
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                VStack(alignment: .leading, spacing: 3) {
                    Text(diagram.title).font(.dante(size: 20, weight: .semibold)).foregroundStyle(theme.text.color)
                    if !diagram.note.isEmpty { Text(diagram.note).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color) }
                }
                .padding(.horizontal, padding)
                .padding(.top, padding)
            }
            DiagramPicture(diagram: diagram, origin: frame.origin, size: frame.size, animated: false)
        }
        .background(theme.panel.color)
        .background(DotGrid(color: theme.line2.color, spacing: 16))
    }
}
