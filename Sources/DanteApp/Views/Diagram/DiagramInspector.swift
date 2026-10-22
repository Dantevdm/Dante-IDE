import AppKit
import DanteKit
import SwiftUI

/// The editor's right-hand panel: the diagram's own title when nothing is selected, a node's
/// words, icon, colour and size, a link's label and look, or tools for several at once.
struct DiagramInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var document: DiagramDocument
    let editTitle: (String) -> Void

    private var diagram: Diagram { document.diagram }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let nodes = diagram.nodes.filter { document.selection.contains($0.id) }
                let links = diagram.links.filter { document.selection.contains($0.id) }
                if nodes.count == 1, links.isEmpty, let node = nodes.first {
                    NodeInspector(document: document, node: node, editTitle: editTitle)
                } else if links.count == 1, nodes.isEmpty, let link = links.first {
                    LinkInspector(document: document, link: link)
                } else if nodes.count + links.count > 1 {
                    SelectionInspector(document: document, nodes: nodes, links: links)
                } else {
                    DiagramDetails(document: document)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.panel.color)
    }
}

// MARK: Pieces

/// A label over a field, like the Map's inspectors.
private struct Field<Content: View>: View {
    @Environment(\.theme) private var theme
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            content
        }
    }
}

private struct FieldBox: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var text: String
    var mono = false
    var axis: Axis = .horizontal

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .textFieldStyle(.plain)
            .font(.dante(size: 12.5, design: mono ? .monospaced : .default))
            .foregroundStyle(theme.text.color)
            .lineLimit(axis == .vertical ? 2...6 : 1...1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.card.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.line2.color))
    }
}

/// The seven theme colours as swatches, with "none" for a quiet link.
struct HueSwatches: View {
    @Environment(\.theme) private var theme
    let selected: Diagram.Hue?
    var allowsNone = false
    let pick: (Diagram.Hue?) -> Void

    var body: some View {
        HStack(spacing: 7) {
            if allowsNone {
                swatch(nil) {
                    Circle().strokeBorder(theme.line2.color, lineWidth: 1.5)
                        .overlay(Rectangle().fill(theme.text3.color).frame(width: 1.5).rotationEffect(.degrees(45)).padding(3))
                }
            }
            ForEach(Diagram.Hue.allCases, id: \.self) { hue in
                swatch(hue) { Circle().fill(hue.rgba(theme).color) }
            }
        }
    }

    private func swatch(_ hue: Diagram.Hue?, @ViewBuilder fill: () -> some View) -> some View {
        Button { pick(hue) } label: {
            fill()
                .frame(width: 20, height: 20)
                .padding(2.5)
                .overlay(Circle().strokeBorder(selected == hue ? theme.text.color : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(hue?.name ?? "No colour")
        .accessibilityLabel(hue?.name ?? "No colour")
    }
}

/// A row of small icon buttons.
private struct InspectorTools: View {
    let tools: [(symbol: String, label: String, action: () -> Void)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                IconButton(symbol: tool.symbol, label: tool.label, size: 12, action: tool.action)
            }
        }
    }
}

private struct Rule: View {
    @Environment(\.theme) private var theme
    var body: some View { Rectangle().fill(theme.line.color).frame(height: 1) }
}

// MARK: The diagram

private struct DiagramDetails: View {
    @Environment(\.theme) private var theme
    @Bindable var document: DiagramDocument

    var body: some View {
        Eyebrow("Diagram")
        Field("Title") {
            FieldBox(placeholder: "Title", text: Binding(get: { document.diagram.title }, set: { text in
                document.change("Rename Diagram", coalescing: "diagram-title") { $0.title = text }
            }))
        }
        Field("Note") {
            FieldBox(placeholder: "A line for the reader", text: Binding(get: { document.diagram.note }, set: { text in
                document.change("Change Note", coalescing: "diagram-note") { $0.note = text }
            }), axis: .vertical)
        }
        Rule()
        let cards = document.diagram.nodes.filter { !$0.kind.isContainer }.count
        let groups = document.diagram.nodes.filter(\.kind.isContainer).count
        Text("\(cards) \(cards == 1 ? "item" : "items") in \(groups) \(groups == 1 ? "group" : "groups"), \(document.diagram.links.count) \(document.diagram.links.count == 1 ? "link" : "links")")
            .font(.dante(size: 12)).foregroundStyle(theme.text2.color)
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow("How to")
            ForEach(Self.tips, id: \.0) { symbol, text in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol).font(.dante(size: 10.5, weight: .semibold)).foregroundStyle(theme.accent.color).frame(width: 16)
                    Text(text).font(.dante(size: 12)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static let tips: [(String, String)] = [
        ("plus.square", "Add from the bar on the left, or double-click empty canvas for a card."),
        ("circle.circle", "Drag from a card's edge dot to another card to link them; drop on empty canvas for a new linked card."),
        ("square.dashed", "Drop a card on a group to put it in; the group grows to hold it. Move a group by its header."),
        ("pencil", "Double-click a card or a link's label to rename it."),
        ("rectangle.dashed", "Drag on empty canvas to select several, then align them here. ⌥ while moving skips snapping."),
        ("arrow.uturn.backward", "⌘Z undoes; changes save to the file as you go."),
    ]
}

// MARK: A node

private struct NodeInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var document: DiagramDocument
    let node: Diagram.Node
    let editTitle: (String) -> Void
    @State private var choosingIcon = false

    private func set(_ name: String, coalescing: Bool = false, _ body: @escaping (inout Diagram.Node) -> Void) {
        let id = node.id
        document.change(name, coalescing: coalescing ? "\(name):\(id)" : nil) { diagram in
            guard let index = diagram.nodes.firstIndex(where: { $0.id == id }) else { return }
            body(&diagram.nodes[index])
        }
    }

    private func text(_ name: String, _ key: WritableKeyPath<Diagram.Node, String>) -> Binding<String> {
        Binding(get: { node[keyPath: key] }, set: { value in set(name, coalescing: true) { $0[keyPath: key] = value } })
    }

    private var subtitleLabel: String {
        switch node.kind {
        case .card, .box: "What it is"
        case .stage: "Environment"
        case .source: "System"
        case .boundary, .title: "Note"
        default: "Subtitle"
        }
    }

    var body: some View {
        HStack {
            Menu {
                ForEach(Diagram.Node.Kind.allCases, id: \.self) { kind in
                    Button(kind.name) { set("Change Kind") { $0.kind = kind } }
                }
            } label: {
                Eyebrow(node.kind.name)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Change what kind of box this is")
            Spacer()
            InspectorTools(tools: [
                ("plus.square.on.square", "Duplicate (⌘D)", { duplicate() }),
                ("trash", "Delete", {
                    document.change("Delete") { $0.delete([node.id]) }
                    document.selection = []
                }),
            ])
        }
        Field(node.kind == .text ? "Words" : "Name") {
            if node.kind == .text {
                FieldBox(placeholder: "Text", text: text("Change Text", \.text), axis: .vertical)
            } else {
                FieldBox(placeholder: "Name", text: text("Rename", \.title))
            }
        }
        if [.card, .box, .stage, .source, .boundary, .title].contains(node.kind) {
            Field(subtitleLabel) { FieldBox(placeholder: subtitleLabel, text: text("Change \(subtitleLabel)", \.subtitle)) }
        }
        if node.kind == .card {
            Field("Detail (monospaced)") { FieldBox(placeholder: "stack or path", text: text("Change Detail", \.detail), mono: true) }
        }
        if node.kind == .box {
            Field("More") { FieldBox(placeholder: "Screens, routes…", text: text("Change Text", \.text), axis: .vertical) }
        }
        if node.kind == .box || node.kind == .source {
            Field(node.kind == .source ? "Branches" : "Chips") {
                FieldBox(placeholder: "comma, separated", text: Binding(get: { node.chips.joined(separator: ", ") }, set: { value in
                    set("Change Chips", coalescing: true) { $0.chips = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                }), mono: true)
            }
        }
        if node.kind == .source {
            Field("Environment") { FieldBox(placeholder: "prod", text: text("Change Environment", \.tag)) }
        }
        if node.kind != .text {
            Field("Icon") {
                HStack(spacing: 8) {
                    Image(systemName: node.icon.isEmpty ? "questionmark" : node.icon)
                        .font(.dante(size: 14))
                        .foregroundStyle(node.hue.rgba(theme).color)
                        .frame(width: 30, height: 30)
                        .background(node.hue.rgba(theme).color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Button("Choose…") { choosingIcon = true }
                        .buttonStyle(DanteButtonStyle())
                        .popover(isPresented: $choosingIcon, arrowEdge: .leading) {
                            IconPicker(selected: node.icon) { symbol in
                                set("Change Icon") { $0.icon = symbol }
                            }
                        }
                }
            }
        }
        if node.kind == .stage {
            Field("Steps (icons)") {
                FieldBox(placeholder: "hammer, checkmark.seal, paperplane", text: Binding(get: { node.icons.joined(separator: ", ") }, set: { value in
                    set("Change Steps", coalescing: true) { $0.icons = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                }), mono: true)
            }
        }
        if ![.text, .title, .person].contains(node.kind) {
            Field("Colour") { HueSwatches(selected: node.hue) { hue in if let hue { set("Change Colour") { $0.hue = hue } } } }
            Toggle("Dashed border", isOn: Binding(get: { node.dashed }, set: { value in set("Dashed Border") { $0.dashed = value } }))
                .toggleStyle(.checkbox)
                .font(.dante(size: 12.5))
                .help("For something outside the system, or not built yet")
        }
        Rule()
        Field("Position and size") {
            let r = node.rect
            HStack(spacing: 6) {
                number("X", r.minX) { value in moveTo(x: value, y: r.minY) }
                number("Y", r.minY) { value in moveTo(x: r.minX, y: value) }
                number("W", r.width) { value in resize(CGRect(x: r.minX, y: r.minY, width: value, height: r.height)) }
                number("H", r.height) { value in resize(CGRect(x: r.minX, y: r.minY, width: r.width, height: value)) }
            }
        }
        HStack(spacing: 6) {
            if node.kind.isContainer {
                Button("Fit to contents") { document.change("Fit") { $0.fit(node.id) } }
                    .buttonStyle(DanteButtonStyle())
                    .disabled(document.diagram.children(of: node.id).isEmpty)
                Button("Ungroup") {
                    document.change("Ungroup") { $0.ungroup(node.id) }
                    document.selection = []
                }
                .buttonStyle(DanteButtonStyle())
            }
            Spacer()
            InspectorTools(tools: [
                ("square.3.layers.3d.top.filled", "Bring to front", { document.change("Bring to Front") { $0.reorder([node.id], toFront: true) } }),
                ("square.3.layers.3d.bottom.filled", "Send to back", { document.change("Send to Back") { $0.reorder([node.id], toFront: false) } }),
            ])
        }
        let incoming = document.diagram.links.filter { $0.to == node.id }.compactMap { document.diagram.node($0.from)?.title }
        let outgoing = document.diagram.links.filter { $0.from == node.id }.compactMap { document.diagram.node($0.to)?.title }
        if !incoming.isEmpty || !outgoing.isEmpty {
            Rule()
            if !outgoing.isEmpty { linkList("Links to", outgoing) }
            if !incoming.isEmpty { linkList("Linked from", incoming) }
        }
    }

    private func linkList(_ label: String, _ names: [String]) -> some View {
        Field(label) {
            Text(names.joined(separator: "\n")).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func number(_ label: String, _ value: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.dante(size: 10.5, weight: .medium)).foregroundStyle(theme.text3.color)
            TextField(label, value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }), format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.plain)
                .font(.dante(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.text.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(theme.card.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.line2.color))
        }
    }

    private func moveTo(x: CGFloat, y: CGFloat) {
        let r = node.rect
        document.change("Move") { diagram in
            diagram.move([node.id], by: CGSize(width: max(0, x) - r.minX, height: max(0, y) - r.minY))
            diagram.adopt([node.id])
        }
    }

    private func resize(_ rect: CGRect) {
        document.change("Resize") { $0.resize(node.id, to: rect) }
    }

    private func duplicate() {
        var copies: Set<String> = []
        document.change("Duplicate") { copies = $0.duplicate([node.id]) }
        document.selection = copies
    }
}

// MARK: A link

private struct LinkInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var document: DiagramDocument
    let link: Diagram.Link

    private func set(_ name: String, coalescing: Bool = false, _ body: @escaping (inout Diagram.Link) -> Void) {
        let id = link.id
        document.change(name, coalescing: coalescing ? "\(name):\(id)" : nil) { diagram in
            guard let index = diagram.links.firstIndex(where: { $0.id == id }) else { return }
            body(&diagram.links[index])
        }
    }

    var body: some View {
        HStack {
            Eyebrow("Link")
            Spacer()
            InspectorTools(tools: [
                ("arrow.left.arrow.right", "Reverse", { set("Reverse Link") { swap(&$0.from, &$0.to) } }),
                ("trash", "Delete", {
                    document.change("Delete Link") { $0.delete([link.id]) }
                    document.selection = []
                }),
            ])
        }
        HStack(spacing: 6) {
            Text(document.diagram.node(link.from)?.title ?? link.from).lineLimit(1)
            Image(systemName: "arrow.right").foregroundStyle(theme.text3.color)
            Text(document.diagram.node(link.to)?.title ?? link.to).lineLimit(1)
        }
        .font(.dante(size: 13, weight: .semibold))
        .foregroundStyle(theme.text.color)
        Field("Label") {
            FieldBox(placeholder: "routes to, /catalogue…", text: Binding(get: { link.label }, set: { value in set("Change Label", coalescing: true) { $0.label = value } }))
        }
        Field("Looks like") {
            HStack(spacing: 6) {
                preset("Traffic", "Solid, coloured, with a pulse") {
                    $0.line = .solid; $0.pulse = true; $0.arrow = true; $0.width = 1.7
                    if $0.hue == nil { $0.hue = document.diagram.node($0.to)?.hue }
                }
                preset("Pipeline", "Flowing dashes, as between stages") { $0.line = .flowing; $0.pulse = false; $0.arrow = false; $0.width = 1.6; $0.hue = .blue }
                preset("Quiet", "A thin grey line") { $0.line = .solid; $0.pulse = false; $0.arrow = true; $0.width = 1.2; $0.hue = nil }
            }
        }
        Field("Line") {
            Picker("Line", selection: Binding(get: { link.line }, set: { value in set("Change Line") { $0.line = value } })) {
                ForEach(Diagram.Link.Line.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        HStack(spacing: 16) {
            Toggle("Pulse", isOn: Binding(get: { link.pulse }, set: { value in set("Pulse") { $0.pulse = value } }))
            Toggle("Arrow", isOn: Binding(get: { link.arrow }, set: { value in set("Arrow") { $0.arrow = value } }))
        }
        .toggleStyle(.checkbox)
        .font(.dante(size: 12.5))
        Field("Colour") { HueSwatches(selected: link.hue, allowsNone: true) { hue in set("Change Colour") { $0.hue = hue } } }
        Field("Width") {
            Slider(value: Binding(get: { link.width }, set: { value in set("Change Width", coalescing: true) { $0.width = (value * 10).rounded() / 10 } }), in: 0.8...4)
        }
        Field("Route") {
            Picker("Route", selection: Binding(get: { link.route }, set: { value in set("Change Route") { $0.route = value } })) {
                Text("Direct").tag(Diagram.Link.Route.auto)
                Text("Loop").tag(Diagram.Link.Route.loop)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Direct goes side to side or down; Loop curves out to the right between boxes in a column, as on the System map")
        }
    }

    private func preset(_ title: String, _ help: String, _ body: @escaping (inout Diagram.Link) -> Void) -> some View {
        Button(title) { set("Link Style", body) }
            .buttonStyle(DanteButtonStyle())
            .help(help)
    }
}

// MARK: Several

private struct SelectionInspector: View {
    @Environment(\.theme) private var theme
    @Bindable var document: DiagramDocument
    let nodes: [Diagram.Node]
    let links: [Diagram.Link]

    var body: some View {
        HStack {
            Eyebrow("\(nodes.count + links.count) selected")
            Spacer()
            IconButton(symbol: "trash", label: "Delete", size: 12) {
                let ids = document.selection
                document.change("Delete") { $0.delete(ids) }
                document.selection = []
            }
        }
        if nodes.count > 1 {
            let ids = Set(nodes.map(\.id))
            Field("Align") {
                InspectorTools(tools: [
                    ("align.horizontal.left", "Left edges", { document.change("Align") { $0.align(ids, .left) } }),
                    ("align.horizontal.center", "Middles across", { document.change("Align") { $0.align(ids, .centerX) } }),
                    ("align.horizontal.right", "Right edges", { document.change("Align") { $0.align(ids, .right) } }),
                    ("align.vertical.top", "Tops", { document.change("Align") { $0.align(ids, .top) } }),
                    ("align.vertical.center", "Middles down", { document.change("Align") { $0.align(ids, .centerY) } }),
                    ("align.vertical.bottom", "Bottoms", { document.change("Align") { $0.align(ids, .bottom) } }),
                ])
            }
            if nodes.count > 2 {
                Field("Space evenly") {
                    InspectorTools(tools: [
                        ("distribute.horizontal.center", "Across", { document.change("Distribute") { $0.distribute(ids, horizontally: true) } }),
                        ("distribute.vertical.center", "Down", { document.change("Distribute") { $0.distribute(ids, horizontally: false) } }),
                    ])
                }
            }
            Field("Colour") {
                HueSwatches(selected: Set(nodes.map(\.hue)).count == 1 ? nodes.first?.hue : nil) { hue in
                    guard let hue else { return }
                    document.change("Change Colour") { diagram in
                        for index in diagram.nodes.indices where ids.contains(diagram.nodes[index].id) { diagram.nodes[index].hue = hue }
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Group") {
                    var group: String?
                    document.change("Group") { group = $0.group(ids) }
                    if let group { document.selection = [group] }
                }
                .buttonStyle(DanteButtonStyle())
                .help("Put them in a new group (⌘G)")
                if nodes.count == 2 {
                    Button("Link them") {
                        var link: String?
                        document.change("Link") { link = $0.connect(nodes[0].id, to: nodes[1].id) }
                        if let link { document.selection = [link] }
                    }
                    .buttonStyle(DanteButtonStyle())
                    .help("A link from the first selected to the second")
                }
            }
        }
        if !links.isEmpty {
            let ids = Set(links.map(\.id))
            Field(links.count == 1 ? "The link" : "The \(links.count) links") {
                HueSwatches(selected: nil, allowsNone: true) { hue in
                    document.change("Change Colour") { diagram in
                        for index in diagram.links.indices where ids.contains(diagram.links[index].id) { diagram.links[index].hue = hue }
                    }
                }
            }
        }
    }
}

// MARK: Icons

/// SF Symbols to choose from: the library's, then common ones, with a search that also
/// takes any symbol name typed in full.
struct IconPicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let selected: String
    let pick: (String) -> Void
    @State private var query = ""

    static let common = [
        "cube", "shippingbox", "server.rack", "cpu", "memorychip", "externaldrive", "cylinder.split.1x2", "tablecells",
        "globe", "network", "cloud", "cloud.fill", "lock.shield", "key", "person.badge.key", "person.2.fill", "person.fill",
        "building.2", "building.columns", "app.badge", "macwindow", "iphone", "terminal", "doc.text", "folder", "tray.full",
        "bell.badge", "envelope", "chart.bar", "chart.line.uptrend.xyaxis", "gauge.with.dots.needle.33percent", "bolt",
        "arrow.triangle.branch", "arrow.left.arrow.right", "paperplane", "hammer", "checkmark.seal", "flag", "star",
        "sparkles", "magnifyingglass", "gearshape.2", "wrench.and.screwdriver", "puzzlepiece.extension", "link", "qrcode",
    ]

    private var symbols: [String] {
        var all: [String] = []
        for symbol in DiagramLibrary.components.map(\.icon) + Self.common where !all.contains(symbol) { all.append(symbol) }
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return all }
        let found = all.filter { symbol in
            let names = DiagramLibrary.components.filter { $0.icon == symbol }.map(\.title).joined(separator: " ").lowercased()
            return words.allSatisfy { symbol.contains($0) || names.contains($0) }
        }
        // A full symbol name typed in.
        let typed = query.trimmingCharacters(in: .whitespaces)
        if !found.contains(typed), NSImage(systemSymbolName: typed, accessibilityDescription: nil) != nil { return [typed] + found }
        return found
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search, or type a symbol name", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.dante(size: 12.5))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8), spacing: 6) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            pick(symbol)
                            dismiss()
                        } label: {
                            Image(systemName: symbol)
                                .font(.dante(size: 14))
                                .foregroundStyle(symbol == selected ? theme.onAccent.color : theme.text.color)
                                .frame(width: 34, height: 34)
                                .background(symbol == selected ? theme.accent.color : theme.raised.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(DiagramLibrary.components.first { $0.icon == symbol }?.title ?? symbol)
                    }
                }
            }
            .frame(height: 230)
        }
        .padding(14)
        .frame(width: 340)
        .background(theme.panel.color)
    }
}
