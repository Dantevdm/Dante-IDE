import CoreGraphics
import Foundation

// MARK: Mermaid

extension Diagram {
    /// A Mermaid flowchart: containers as subgraphs, cards as nodes, links with their labels.
    /// Positions don't carry over; Mermaid lays it out.
    public func mermaid() -> String {
        var used: [String: String] = [:]
        var taken: Set<String> = []
        func id(_ raw: String) -> String {
            if let known = used[raw] { return known }
            var base = String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
            if base.isEmpty || base.first!.isNumber { base = "n_" + base }
            // Words Mermaid reads as keywords.
            if ["end", "graph", "subgraph", "flowchart", "style", "class", "click"].contains(base.lowercased()) { base += "_" }
            var candidate = base
            var number = 2
            while taken.contains(candidate) { candidate = "\(base)\(number)"; number += 1 }
            taken.insert(candidate)
            used[raw] = candidate
            return candidate
        }
        func text(_ value: String) -> String {
            value.replacingOccurrences(of: "\"", with: "#quot;").replacingOccurrences(of: "\n", with: " ")
        }
        func label(_ node: Node) -> String {
            let lines = [node.title, node.subtitle].filter { !$0.isEmpty }.map(text)
            return lines.joined(separator: "<br/>")
        }
        var lines = ["flowchart LR"]
        func write(_ parent: String?, depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            for node in nodes where node.parent == parent {
                switch node.kind {
                case .group, .boundary:
                    lines.append("\(pad)subgraph \(id(node.id))[\"\(text(node.title))\"]")
                    write(node.id, depth: depth + 1)
                    lines.append("\(pad)end")
                case .person: lines.append("\(pad)\(id(node.id))((\"\(label(node))\"))")
                case .source: lines.append("\(pad)\(id(node.id))([\"\(label(node))\"])")
                case .stage: lines.append("\(pad)\(id(node.id))[/\"\(label(node))\"/]")
                case .title, .text: continue
                case .card, .box: lines.append("\(pad)\(id(node.id))[\"\(label(node))\"]")
                }
            }
        }
        write(nil, depth: 1)
        // Orphans whose container is gone.
        let known = Set(nodes.map(\.id))
        for node in nodes where node.parent.map({ !known.contains($0) }) ?? false {
            lines.append("  \(id(node.id))[\"\(label(node))\"]")
        }
        for link in drawableLinks {
            guard let from = node(link.from), let to = node(link.to), ![.title, .text].contains(from.kind), ![.title, .text].contains(to.kind) else { continue }
            let arrow = link.line == .solid ? (link.arrow ? "-->" : "---") : (link.arrow ? "-.->" : "-.-")
            let middle = link.label.isEmpty ? "" : "|\(text(link.label))|"
            lines.append("  \(id(link.from)) \(arrow)\(middle) \(id(link.to))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: SVG

/// A diagram as an SVG file, drawn like the editor draws it in the given theme. Pulses and
/// flowing dashes animate in a browser. `icon` returns an image (a data URL) for an SF Symbol
/// in a colour, which only the app can draw.
public enum DiagramSVG {
    public typealias IconSource = (_ symbol: String, _ color: RGBA, _ size: CGFloat) -> String?

    public static let padding: CGFloat = 32

    public static func render(_ diagram: Diagram, theme: Theme, icon: @escaping IconSource = { _, _, _ in nil }) -> String {
        let box = diagram.bounds.isNull ? CGRect(x: 0, y: 0, width: 200, height: 120) : diagram.bounds
        let origin = CGPoint(x: box.minX - padding, y: box.minY - padding)
        let size = CGSize(width: box.width + padding * 2, height: box.height + padding * 2)
        var out: [String] = []
        out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(number(origin.x)) \(number(origin.y)) \(number(size.width)) \(number(size.height))\" width=\"\(number(size.width))\" height=\"\(number(size.height))\" font-family=\"Geist, -apple-system, 'Helvetica Neue', sans-serif\">")
        out.append("<title>\(escape(diagram.title))</title>")
        out.append("<rect x=\"\(number(origin.x))\" y=\"\(number(origin.y))\" width=\"\(number(size.width))\" height=\"\(number(size.height))\" fill=\"\(theme.panel.css)\"/>")
        var context = Context(diagram: diagram, theme: theme, icon: icon)
        for node in diagram.drawingOrder where node.kind.isContainer { context.draw(node, into: &out) }
        context.links(into: &out)
        for node in diagram.drawingOrder where !node.kind.isContainer { context.draw(node, into: &out) }
        out.append("</svg>")
        return out.joined(separator: "\n") + "\n"
    }

    static func number(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Lines of at most `width` points at `size`, by an average letter width (Geist's), at most `limit` lines.
    static func wrap(_ text: String, width: CGFloat, size: CGFloat, mono: Bool = false, limit: Int = 2) -> [String] {
        let perLetter = size * (mono ? 0.6 : 0.55)
        let fits = max(4, Int(width / perLetter))
        var lines: [String] = []
        var current = ""
        // Camel case breaks too, as on the Map.
        let words = text.split(separator: " ").flatMap { word -> [String] in
            word.count > fits ? Diagram.camelPieces(String(word)) : [String(word)]
        }
        for word in words {
            let joined = current.isEmpty ? word : (current.hasSuffix("\u{200B}") ? current + word : current + " " + word)
            if joined.replacingOccurrences(of: "\u{200B}", with: "").count <= fits || current.isEmpty {
                current = joined
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        lines = lines.map { $0.replacingOccurrences(of: "\u{200B}", with: "") }
        if lines.count > limit {
            lines = Array(lines.prefix(limit))
            lines[limit - 1] = String(lines[limit - 1].prefix(max(1, fits - 1))) + "…"
        }
        return lines.map { $0.count > fits ? String($0.prefix(fits - 1)) + "…" : $0 }
    }

    private struct Context {
        let diagram: Diagram
        let theme: Theme
        let icon: IconSource

        func hue(_ node: Node) -> RGBA { node.hue.rgba(theme) }
        typealias Node = Diagram.Node

        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: Int = 400, color: RGBA, mono: Bool = false, tracking: CGFloat = 0, anchor: String = "start") -> String {
            "<text x=\"\(number(x))\" y=\"\(number(y))\" font-size=\"\(number(size))\" font-weight=\"\(weight)\" fill=\"\(color.css)\""
                + (mono ? " font-family=\"'Geist Mono', ui-monospace, Menlo, monospace\"" : "")
                + (tracking == 0 ? "" : " letter-spacing=\"\(number(tracking))\"")
                + (anchor == "start" ? "" : " text-anchor=\"\(anchor)\"")
                + ">\(escape(value))</text>"
        }

        func image(_ symbol: String, color: RGBA, center: CGPoint, size: CGFloat) -> String? {
            guard !symbol.isEmpty, let url = icon(symbol, color, size) else { return nil }
            return "<image href=\"\(url)\" x=\"\(number(center.x - size / 2))\" y=\"\(number(center.y - size / 2))\" width=\"\(number(size))\" height=\"\(number(size))\"/>"
        }

        func rect(_ r: CGRect, radius: CGFloat, fill: String, stroke: String? = nil, width: CGFloat = 1, dash: String? = nil) -> String {
            "<rect x=\"\(number(r.minX))\" y=\"\(number(r.minY))\" width=\"\(number(r.width))\" height=\"\(number(r.height))\" rx=\"\(number(radius))\" fill=\"\(fill)\""
                + (stroke.map { " stroke=\"\($0)\" stroke-width=\"\(number(width))\"" } ?? "")
                + (dash.map { " stroke-dasharray=\"\($0)\"" } ?? "") + "/>"
        }

        /// A header row: icon, title in capitals, then a count or a note.
        func header(_ node: Node, at point: CGPoint, color: RGBA, size: CGFloat, count: Int?, note: String, into out: inout [String]) {
            var x = point.x
            if let image = image(node.icon, color: color, center: CGPoint(x: x + 6, y: point.y - size * 0.35), size: size + 1) {
                out.append(image)
                x += 18
            }
            let title = node.title.uppercased()
            out.append(text(title, x: x, y: point.y, size: size, weight: 600, color: color, tracking: 0.9))
            x += CGFloat(title.count) * (size * 0.68 + 0.9) + 6
            if let count {
                let label = "\(count)"
                let width = CGFloat(label.count) * size * 0.62 + 10
                out.append(rect(CGRect(x: x, y: point.y - size, width: width, height: size + 4), radius: (size + 4) / 2, fill: node.hue.rgba(theme).opacity(0.14).css))
                out.append(text(label, x: x + width / 2, y: point.y, size: size, weight: 500, color: color, mono: true, anchor: "middle"))
            } else if !note.isEmpty {
                out.append(text(note, x: x, y: point.y, size: size, color: theme.text3))
            }
        }

        mutating func draw(_ node: Node, into out: inout [String]) {
            let r = node.rect
            let hue = hue(node)
            switch node.kind {
            case .boundary:
                let panel = CGRect(x: r.minX, y: r.minY + Diagram.boundaryTitleRoom, width: r.width, height: r.height - Diagram.boundaryTitleRoom)
                header(node, at: CGPoint(x: r.minX, y: r.minY + 14), color: theme.text2, size: 11, count: nil, note: node.subtitle, into: &out)
                out.append(rect(panel, radius: 16, fill: theme.card.opacity(0.35).css, stroke: theme.line2.css, width: 1.2, dash: "6 5"))
            case .group:
                out.append(rect(r, radius: 12, fill: hue.opacity(0.06).css, stroke: hue.opacity(0.28).css, dash: node.dashed ? "5 4" : nil))
                header(node, at: CGPoint(x: r.minX + 12, y: r.minY + 22), color: hue, size: 10.5, count: diagram.count(of: node.id), note: "", into: &out)
            case .card:
                out.append(rect(r, radius: 10, fill: theme.card.css, stroke: theme.line2.css, dash: node.dashed ? "4 3" : nil))
                let tile = CGRect(x: r.minX + 8, y: r.midY - 17, width: 34, height: 34)
                let gradient = "g-" + Diagram.slug(node.id)
                out.append("<defs><linearGradient id=\"\(gradient)\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(hue.opacity(0.22).css)\"/><stop offset=\"1\" stop-color=\"\(hue.opacity(0.08).css)\"/></linearGradient></defs>")
                out.append(rect(tile, radius: 8, fill: "url(#\(gradient))", stroke: hue.opacity(0.35).css))
                if let image = image(node.icon, color: hue, center: CGPoint(x: tile.midX, y: tile.midY), size: 16) { out.append(image) }
                textBlock(node, x: tile.maxX + 9, width: r.maxX - tile.maxX - 17, rect: r, titleSize: 12, into: &out)
            case .box:
                let clip = "c-" + Diagram.slug(node.id)
                out.append("<clipPath id=\"\(clip)\">" + rect(r, radius: 10, fill: "#000") + "</clipPath>")
                out.append(rect(r, radius: 10, fill: theme.card.css))
                out.append("<rect x=\"\(number(r.minX))\" y=\"\(number(r.minY))\" width=\"3\" height=\"\(number(r.height))\" fill=\"\(hue.css)\" clip-path=\"url(#\(clip))\"/>")
                out.append(rect(r, radius: 10, fill: "none", stroke: theme.line2.css, dash: node.dashed ? "4 3" : nil))
                let tile = CGRect(x: r.minX + 10, y: r.minY + 10, width: 22, height: 22)
                out.append(rect(tile, radius: 6, fill: hue.opacity(0.14).css))
                if let image = image(node.icon, color: hue, center: CGPoint(x: tile.midX, y: tile.midY), size: 12) { out.append(image) }
                var y = r.minY + 21
                for line in wrap(node.title, width: r.width - 49, size: 13) {
                    out.append(text(line, x: tile.maxX + 7, y: y, size: 13, weight: 600, color: theme.text))
                    y += 15
                }
                if !node.subtitle.isEmpty {
                    out.append(text(node.subtitle, x: tile.maxX + 7, y: y, size: 10.5, color: theme.text3))
                    y += 14
                }
                if !node.text.isEmpty {
                    for line in wrap(node.text, width: r.width - 49, size: 10.5, limit: 3) {
                        out.append(text(line, x: r.minX + 39, y: y + 2, size: 10.5, color: theme.text2))
                        y += 13
                    }
                }
                chips(node.chips, x: r.minX + 39, y: y + 4, into: &out)
            case .person:
                let circle = CGRect(x: r.midX - 23, y: r.minY, width: 46, height: 46)
                out.append("<circle cx=\"\(number(circle.midX))\" cy=\"\(number(circle.midY))\" r=\"23\" fill=\"\(theme.card.css)\" stroke=\"\(theme.line2.css)\"/>")
                if let image = image(node.icon, color: theme.text2, center: CGPoint(x: circle.midX, y: circle.midY), size: 18) { out.append(image) }
                out.append(text(node.title, x: r.midX, y: circle.maxY + 16, size: 11, weight: 500, color: theme.text2, anchor: "middle"))
            case .stage:
                out.append(rect(r, radius: 12, fill: theme.card.css, stroke: theme.line2.css, dash: node.dashed ? "4 3" : nil))
                out.append("<circle cx=\"\(number(r.minX + 22))\" cy=\"\(number(r.minY + 22))\" r=\"12\" fill=\"\(theme.accentTint.css)\"/>")
                if let image = image(node.icon, color: theme.accent, center: CGPoint(x: r.minX + 22, y: r.minY + 22), size: 12) { out.append(image) }
                var y = r.minY + (node.subtitle.isEmpty ? 26 : 20)
                for line in wrap(node.title, width: r.width - 49, size: 12.5) {
                    out.append(text(line, x: r.minX + 41, y: y, size: 12.5, weight: 600, color: theme.text))
                    y += 15
                }
                if !node.subtitle.isEmpty { out.append(text(node.subtitle, x: r.minX + 41, y: y - 2, size: 10, color: theme.text3)) }
                var x = r.minX + 10
                for symbol in node.icons.prefix(8) {
                    let tile = CGRect(x: x, y: r.maxY - 30, width: 20, height: 20)
                    out.append(rect(tile, radius: 5, fill: theme.raised.css))
                    if let image = image(symbol, color: theme.text2, center: CGPoint(x: tile.midX, y: tile.midY), size: 11) { out.append(image) }
                    x += 24
                }
            case .source:
                out.append(rect(r, radius: 10, fill: theme.card.css, stroke: theme.accentLine.css, dash: node.dashed ? "4 3" : nil))
                let tile = CGRect(x: r.minX + 10, y: r.minY + 10, width: 22, height: 22)
                out.append(rect(tile, radius: 6, fill: theme.accent.css))
                if let image = image(node.icon, color: theme.onAccent, center: CGPoint(x: tile.midX, y: tile.midY), size: 11) { out.append(image) }
                out.append(text(wrap(node.title, width: r.width - 49, size: 12.5, limit: 1).first ?? "", x: tile.maxX + 7, y: r.minY + 20, size: 12.5, weight: 600, color: theme.text))
                out.append(text(node.subtitle, x: tile.maxX + 7, y: r.minY + 33, size: 10.5, color: theme.text3))
                let end = chips(node.chips, x: r.minX + 10, y: r.minY + 42, into: &out)
                if !node.tag.isEmpty {
                    let width = CGFloat(node.tag.count) * 5.6 + 12
                    out.append(rect(CGRect(x: end, y: r.minY + 42, width: width, height: 16), radius: 8, fill: theme.accentTint.css))
                    out.append(text(node.tag, x: end + width / 2, y: r.minY + 54, size: 10, weight: 500, color: theme.accent, anchor: "middle"))
                }
            case .title:
                header(node, at: CGPoint(x: r.minX, y: r.minY + 13), color: theme.text2, size: 11, count: nil, note: node.subtitle, into: &out)
            case .text:
                var y = r.minY + 14
                for line in wrap(node.text.isEmpty ? node.title : node.text, width: r.width, size: 12.5, limit: 12) {
                    out.append(text(line, x: r.minX, y: y, size: 12.5, color: theme.text2))
                    y += 17
                }
            }
        }

        func textBlock(_ node: Node, x: CGFloat, width: CGFloat, rect r: CGRect, titleSize: CGFloat, into out: inout [String]) {
            let title = wrap(node.title, width: width, size: titleSize)
            let lines = CGFloat(title.count) * 14.5 + (node.subtitle.isEmpty ? 0 : 13.5) + (node.detail.isEmpty ? 0 : 12.5)
            var y = r.midY - lines / 2 + 11
            for line in title {
                out.append(text(line, x: x, y: y, size: titleSize, weight: 600, color: theme.text))
                y += 14.5
            }
            if !node.subtitle.isEmpty {
                out.append(text(node.subtitle, x: x, y: y - 0.5, size: 10.5, color: theme.text3))
                y += 13.5
            }
            if !node.detail.isEmpty {
                out.append(text(node.detail, x: x, y: y - 1, size: 9.5, color: theme.text3.opacity(0.85), mono: true))
            }
        }

        /// Capsules in a row; returns where the next one would go.
        @discardableResult
        func chips(_ chips: [String], x start: CGFloat, y: CGFloat, into out: inout [String]) -> CGFloat {
            var x = start
            for chip in chips {
                let width = CGFloat(chip.count) * 6 + 12
                out.append(rect(CGRect(x: x, y: y, width: width, height: 16), radius: 8, fill: theme.raised.css))
                out.append(text(chip, x: x + width / 2, y: y + 12, size: 10, color: theme.text2, mono: true, anchor: "middle"))
                x += width + 4
            }
            return x
        }

        func links(into out: inout [String]) {
            for (index, link) in diagram.drawableLinks.enumerated() {
                guard let a = diagram.node(link.from)?.rect, let b = diagram.node(link.to)?.rect else { continue }
                let curve = LinkCurve.route(link.route, a, b)
                let color = link.hue?.rgba(theme) ?? theme.line2
                let dash: String? = switch link.line {
                case .solid: nil
                case .dashed: "5 4"
                case .flowing: "6 6"
                }
                out.append("<path d=\"\(curve.svg)\" fill=\"none\" stroke=\"\(color.opacity(link.hue == nil ? 1 : 0.85).css)\" stroke-width=\"\(number(link.width))\" stroke-linecap=\"round\""
                    + (dash.map { " stroke-dasharray=\"\($0)\"" } ?? "")
                    + (link.line == .flowing ? "><animate attributeName=\"stroke-dashoffset\" from=\"0\" to=\"-24\" dur=\"1.1s\" repeatCount=\"indefinite\"/></path>" : "/>"))
                if link.arrow {
                    let end = curve.end, angle = curve.endAngle
                    let p1 = CGPoint(x: end.x - 7 * cos(angle - 0.45), y: end.y - 7 * sin(angle - 0.45))
                    let p2 = CGPoint(x: end.x - 7 * cos(angle + 0.45), y: end.y - 7 * sin(angle + 0.45))
                    out.append("<path d=\"M\(number(end.x)) \(number(end.y)) L\(number(p1.x)) \(number(p1.y)) L\(number(p2.x)) \(number(p2.y)) Z\" fill=\"\(color.css)\"/>")
                }
                if link.pulse {
                    let pulse = (link.hue ?? diagram.node(link.to)?.hue ?? .blue).rgba(theme)
                    let begin = String(format: "%.2fs", Double(index % 7) * 0.33)
                    let motion = "<animateMotion dur=\"2.4s\" begin=\"\(begin)\" repeatCount=\"indefinite\" path=\"\(curve.svg)\"/>"
                    out.append("<circle r=\"6\" cx=\"0\" cy=\"0\" fill=\"\(pulse.opacity(0.18).css)\">\(motion)</circle>")
                    out.append("<circle r=\"2.6\" cx=\"0\" cy=\"0\" fill=\"\(pulse.css)\">\(motion)</circle>")
                }
                if !link.label.isEmpty {
                    let middle = curve.point(at: 0.5)
                    let width = CGFloat(link.label.count) * 5.3 + 10
                    out.append(rect(CGRect(x: middle.x - width / 2, y: middle.y - 8, width: width, height: 16), radius: 8, fill: theme.card.css, stroke: theme.line.css, width: 0.8))
                    out.append(text(link.label, x: middle.x, y: middle.y + 3.4, size: 9.5, weight: 500, color: theme.text2, anchor: "middle"))
                }
            }
        }
    }
}

extension Diagram {
    /// "OrdersPortalFargateService" in pieces, with zero-width spaces where a line may break.
    static func camelPieces(_ word: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var previous: Character?
        for character in word {
            if character.isUppercase, let previous, previous.isLowercase, !current.isEmpty {
                pieces.append(current + "\u{200B}")
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
