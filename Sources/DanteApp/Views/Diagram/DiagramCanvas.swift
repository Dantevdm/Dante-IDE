import AppKit
import DanteKit
import SwiftUI
import UniformTypeIdentifiers

/// The editing surface: the picture with handles over it. One drag gesture reads what's
/// under the pointer from the model (a resize corner, a link dot, a card, a group's header,
/// a link, or nothing) and moves, resizes, connects or draws a selection box. Moves snap to
/// the boxes around them and to the grid; ⌥ moves freely.
struct DiagramCanvas: View {
    @Environment(\.theme) private var theme
    @Bindable var document: DiagramDocument
    @Binding var zoom: CGFloat
    /// Where the visible middle is, in diagram points: new things go there.
    @Binding var viewCenter: CGPoint
    @Binding var editing: InlineEdit?
    @Binding var scroll: ScrollPosition
    /// The visible size, for zooming to fit.
    @Binding var viewport: CGSize

    struct InlineEdit: Equatable {
        enum Field { case title, label }
        var id: String
        var field: Field
    }

    private enum Drag {
        case move(start: Diagram, ids: Set<String>, startRect: CGRect, clicked: String, wasSelected: Bool, additive: Bool)
        case resize(start: Diagram, id: String, corner: Corner, startRect: CGRect)
        case connect(from: String, to: CGPoint)
        case marquee(from: CGPoint, to: CGPoint, base: Set<String>, under: String?)
        case link(String)
    }

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    @State private var drag: Drag?
    @State private var guides: [DiagramSnap.Guide] = []
    @State private var hover: CGPoint?
    @State private var magnifyStart: CGFloat?
    @FocusState private var focused: Bool

    private var diagram: Diagram { document.diagram }
    private var selectedNodes: [Diagram.Node] { diagram.nodes.filter { document.selection.contains($0.id) } }

    /// One card selected, and not while it's being dragged: the rest fades back to show what it's linked to.
    private var focusedNode: String? {
        guard drag == nil, selectedNodes.count == 1, let node = selectedNodes.first, ![.title, .text].contains(node.kind) else { return nil }
        return node.id
    }

    static let paletteRoom: CGFloat = 64

    /// The canvas reaches past the picture so there's room to drag things out.
    private func canvasSize(_ viewport: CGSize) -> CGSize {
        let bounds = diagram.bounds.isNull ? .zero : diagram.bounds
        return CGSize(width: max(bounds.maxX + 600, viewport.width / zoom), height: max(bounds.maxY + 400, viewport.height / zoom))
    }

    var body: some View {
        GeometryReader { outer in
            let size = canvasSize(outer.size)
            ScrollView([.horizontal, .vertical]) {
                surface(size: size)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
            }
            // Room on the left for the palette that floats over the canvas.
            .contentMargins(.leading, DiagramCanvas.paletteRoom, for: .scrollContent)
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, size in viewport = size }
            .onScrollGeometryChange(for: CGPoint.self) { geometry in
                CGPoint(x: (geometry.contentOffset.x + geometry.containerSize.width / 2) / zoom,
                        y: (geometry.contentOffset.y + geometry.containerSize.height / 2) / zoom)
            } action: { _, center in
                viewCenter = center
            }
            .background(theme.panel.color)
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    if magnifyStart == nil { magnifyStart = zoom }
                    zoom = min(2.5, max(0.25, (magnifyStart ?? 1) * value.magnification))
                }
                .onEnded { _ in magnifyStart = nil })
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onDeleteCommand { deleteSelection() }
        .onMoveCommand { direction in nudge(direction) }
        .onExitCommand {
            if editing != nil { editing = nil } else { document.selection = [] }
        }
        .onCopyCommand { copyItems() }
        .onCutCommand {
            let items = copyItems()
            deleteSelection(name: "Cut")
            return items
        }
        .onPasteCommand(of: [.json]) { providers in paste(providers) }
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            document.selection = Set(diagram.nodes.map(\.id))
        }
    }

    private func surface(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            DotGrid(color: theme.line2.color.opacity(0.7), spacing: Diagram.grid * 2)
                .frame(width: size.width, height: size.height)
            DiagramPicture(diagram: diagram, size: size, selectedLinks: document.selection, hovered: hoveredNode?.id, focus: focusedNode)
            overlay(size: size)
            inlineEditor
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .coordinateSpace(.named("diagram"))
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("diagram"))
            .onChanged(dragChanged)
            .onEnded(dragEnded))
        .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named("diagram")).onEnded { doubleClick(at: $0.location) })
        .onContinuousHover(coordinateSpace: .named("diagram")) { phase in
            switch phase {
            case .active(let point): hover = point
            case .ended: hover = nil
            }
        }
        .pointerStyle(pointer)
    }

    // MARK: Hit testing

    private var hoveredNode: Diagram.Node? {
        guard drag == nil, let hover else { return nil }
        return node(at: hover).flatMap { $0.kind.isContainer && !isHeader($0, hover) ? nil : $0 }
    }

    /// The topmost node under a point: cards and people before the groups behind them.
    private func node(at point: CGPoint, excluding: Set<String> = []) -> Diagram.Node? {
        diagram.drawingOrder.reversed().first { !excluding.contains($0.id) && $0.rect.insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func isHeader(_ node: Diagram.Node, _ point: CGPoint) -> Bool {
        point.y <= node.rect.minY + Diagram.headerHeight(node.kind)
    }

    private func link(at point: CGPoint) -> Diagram.Link? {
        diagram.drawableLinks
            .compactMap { link -> (Diagram.Link, CGFloat)? in
                guard let a = diagram.node(link.from)?.rect, let b = diagram.node(link.to)?.rect else { return nil }
                return (link, LinkCurve.route(link.route, a, b).distance(to: point))
            }
            .filter { $0.1 < 7 }
            .min { $0.1 < $1.1 }?.0
    }

    /// The node whose link dots show: the one under the pointer, else the one selected.
    private var dotted: Diagram.Node? {
        if let hovered = hoveredNode, ![.title, .text].contains(hovered.kind) { return hovered }
        if selectedNodes.count == 1, let only = selectedNodes.first, ![.title, .text].contains(only.kind) { return only }
        return nil
    }

    private func dots(_ node: Diagram.Node) -> [CGPoint] {
        let r = node.kind == .boundary ? node.rect.inset(top: Diagram.boundaryTitleRoom) : node.rect
        return [CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY)]
    }

    private func dot(at point: CGPoint) -> Diagram.Node? {
        guard let node = dotted, dots(node).contains(where: { hypot($0.x - point.x, $0.y - point.y) < 8 }) else { return nil }
        return node
    }

    private func corners(_ rect: CGRect) -> [(Corner, CGPoint)] {
        [(.topLeft, CGPoint(x: rect.minX, y: rect.minY)), (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
         (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)), (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))]
    }

    private func corner(at point: CGPoint) -> (Diagram.Node, Corner)? {
        guard selectedNodes.count == 1, let node = selectedNodes.first else { return nil }
        return corners(node.rect).first { hypot($0.1.x - point.x, $0.1.y - point.y) < 7 }.map { (node, $0.0) }
    }

    private var pointer: PointerStyle {
        if let drag {
            switch drag {
            case .move: return .grabActive
            case .resize: return .default
            case .connect: return .default
            case .marquee: return .rectSelection
            case .link: return .default
            }
        }
        guard let hover else { return .default }
        if let (_, corner) = corner(at: hover) {
            switch corner {
            case .topLeft: return .frameResize(position: .topLeading)
            case .topRight: return .frameResize(position: .topTrailing)
            case .bottomLeft: return .frameResize(position: .bottomLeading)
            case .bottomRight: return .frameResize(position: .bottomTrailing)
            }
        }
        if dot(at: hover) != nil { return .link }
        if let node = node(at: hover), !node.kind.isContainer || isHeader(node, hover) { return .grabIdle }
        return .default
    }

    // MARK: Dragging

    private func dragChanged(_ value: DragGesture.Value) {
        if editing != nil { editing = nil }
        if drag == nil { drag = begin(at: value.startLocation) }
        guard let drag else { return }
        switch drag {
        case let .move(start, ids, startRect, _, _, _):
            var offset = value.translation
            let free = NSEvent.modifierFlags.contains(.option)
            if !free {
                let moving = Set(ids).union(ids.flatMap { start.descendants(of: $0).map(\.id) })
                let others = start.nodes.filter { !moving.contains($0.id) }.map(\.rect)
                let snap = DiagramSnap.snap(startRect.offsetBy(dx: offset.width, dy: offset.height), to: others)
                offset.width += snap.offset.width
                offset.height += snap.offset.height
                guides = snap.guides
            } else {
                guides = []
            }
            // Nothing goes above or left of the canvas.
            offset.width = max(offset.width, -startRect.minX)
            offset.height = max(offset.height, -startRect.minY)
            var moved = start
            moved.move(ids, by: offset, grows: false)
            document.preview(moved)
        case let .resize(start, id, corner, rect):
            var r = rect
            let dx = value.translation.width, dy = value.translation.height
            switch corner {
            case .topLeft: r = CGRect(x: rect.minX + dx, y: rect.minY + dy, width: rect.width - dx, height: rect.height - dy)
            case .topRight: r = CGRect(x: rect.minX, y: rect.minY + dy, width: rect.width + dx, height: rect.height - dy)
            case .bottomLeft: r = CGRect(x: rect.minX + dx, y: rect.minY, width: rect.width - dx, height: rect.height + dy)
            case .bottomRight: r = CGRect(x: rect.minX, y: rect.minY, width: rect.width + dx, height: rect.height + dy)
            }
            if !NSEvent.modifierFlags.contains(.option) {
                r = CGRect(x: Diagram.snapped(r.minX), y: Diagram.snapped(r.minY), width: Diagram.snapped(r.width), height: Diagram.snapped(r.height))
                if corner == .topLeft || corner == .bottomLeft { r.origin.x = rect.maxX - r.width }
                if corner == .topLeft || corner == .topRight { r.origin.y = rect.maxY - r.height }
            }
            var resized = start
            resized.resize(id, to: r)
            document.preview(resized)
        case let .connect(from, _):
            self.drag = .connect(from: from, to: value.location)
        case let .marquee(from, _, base, under):
            self.drag = .marquee(from: from, to: value.location, base: base, under: under)
            let box = CGRect(from: from, to: value.location)
            let inside = Set(diagram.nodes.filter { box.contains($0.rect) }.map(\.id))
            document.selection = base.union(inside)
        case .link:
            break
        }
    }

    private func begin(at point: CGPoint) -> Drag? {
        let additive = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
        if let (node, corner) = corner(at: point) {
            return .resize(start: diagram, id: node.id, corner: corner, startRect: node.rect)
        }
        if let node = dot(at: point) {
            return .connect(from: node.id, to: point)
        }
        if let node = node(at: point), !node.kind.isContainer || isHeader(node, point) || document.selection.contains(node.id) {
            let wasSelected = document.selection.contains(node.id)
            if additive {
                if !wasSelected { document.selection.insert(node.id) }
            } else if !wasSelected {
                document.selection = [node.id]
            }
            let ids = Set(diagram.outermost(document.selection.filter { diagram.node($0) != nil }))
            let rect = ids.compactMap { diagram.node($0)?.rect }.reduce(CGRect.null) { $0.union($1) }
            return .move(start: diagram, ids: ids, startRect: rect, clicked: node.id, wasSelected: wasSelected, additive: additive)
        }
        if let link = link(at: point) {
            if additive { document.selection.formSymmetricDifference([link.id]) } else { document.selection = [link.id] }
            return .link(link.id)
        }
        return .marquee(from: point, to: point, base: additive ? document.selection : [], under: node(at: point)?.id)
    }

    private func dragEnded(_ value: DragGesture.Value) {
        defer {
            drag = nil
            guides = []
        }
        guard let drag else { return }
        let moved = hypot(value.translation.width, value.translation.height) > 2
        switch drag {
        case let .move(start, ids, _, clicked, wasSelected, additive):
            guard moved else {
                document.preview(start)
                // A click: on a selected node it toggles (with ⇧) or selects it alone.
                if additive, wasSelected { document.selection.remove(clicked) } else if !additive { document.selection = [clicked] }
                return
            }
            var settled = diagram
            settled.adopt(ids)
            settled.normalise(margin: 24)
            document.preview(settled)
            document.commit(from: start, name: ids.count == 1 ? "Move" : "Move \(ids.count) Items")
        case let .resize(start, _, _, _):
            document.commit(from: start, name: "Resize")
        case let .connect(from, point):
            if let target = node(at: point, excluding: [from]) {
                var id: String?
                document.change("Link") { id = $0.connect(from, to: target.id) }
                if let id { document.selection = [id] }
            } else if moved, let source = diagram.node(from) {
                // Dropped on empty canvas: a new card there, linked.
                var created: String?
                document.change("Add Linked Card") { diagram in
                    let id = diagram.add(.card, at: point) { $0.hue = source.hue }
                    diagram.connect(from, to: id)
                    created = id
                }
                if let created {
                    document.selection = [created]
                    editing = InlineEdit(id: created, field: .title)
                }
            }
        case let .marquee(_, _, base, under):
            guard moved else {
                // A click on empty canvas clears; inside a group it selects the group.
                document.selection = under.map { base.union([$0]) } ?? base
                return
            }
        case .link:
            break
        }
    }

    private func doubleClick(at point: CGPoint) {
        if let node = node(at: point), !node.kind.isContainer || isHeader(node, point) {
            document.selection = [node.id]
            editing = InlineEdit(id: node.id, field: .title)
            return
        }
        if let link = link(at: point) {
            document.selection = [link.id]
            editing = InlineEdit(id: link.id, field: .label)
            return
        }
        var created: String?
        document.change("Add Card") { created = $0.add(.card, at: point) }
        if let created {
            document.selection = [created]
            editing = InlineEdit(id: created, field: .title)
        }
    }

    // MARK: Drawn over the picture

    private func overlay(size: CGSize) -> some View {
        Canvas { context, _ in
            let accent = theme.accent.color
            // Selection: an outline round each selected node, corners on a single one.
            for node in selectedNodes {
                let r = node.rect.insetBy(dx: -3, dy: -3)
                context.stroke(Path(roundedRect: r, cornerRadius: node.kind == .person ? 12 : 13), with: .color(accent), lineWidth: 1.5)
            }
            if selectedNodes.count == 1, let node = selectedNodes.first, drag == nil || isResizing {
                for (_, point) in corners(node.rect) {
                    let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                    context.fill(Path(roundedRect: handle, cornerRadius: 2), with: .color(theme.card.color))
                    context.stroke(Path(roundedRect: handle, cornerRadius: 2), with: .color(accent), lineWidth: 1.3)
                }
            }
            // Link dots on the node under the pointer.
            if drag == nil, let node = dotted {
                for point in dots(node) {
                    let near = hover.map { hypot($0.x - point.x, $0.y - point.y) < 8 } ?? false
                    let radius: CGFloat = near ? 6 : 4.5
                    let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: circle), with: .color(near ? accent : theme.card.color))
                    context.stroke(Path(ellipseIn: circle), with: .color(accent), lineWidth: 1.4)
                }
            }
            // The link being drawn, to the card under the pointer or to the pointer.
            if case let .connect(from, point)? = drag, let source = diagram.node(from) {
                let target = node(at: point, excluding: [from])
                let end = target?.rect ?? CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
                let path = MapInk.path(.direct(source.rect, end))
                MapInk.stroke(path, color: accent, width: 1.8, dash: [6, 5], in: &context)
                MapInk.arrowhead(path, color: accent, in: &context)
                if let target {
                    context.stroke(Path(roundedRect: target.rect.insetBy(dx: -3, dy: -3), cornerRadius: 13), with: .color(accent.opacity(0.6)), lineWidth: 2)
                }
            }
            // The selection box.
            if case let .marquee(from, to, _, _)? = drag, hypot(to.x - from.x, to.y - from.y) > 2 {
                let box = CGRect(from: from, to: to)
                context.fill(Path(box), with: .color(accent.opacity(0.08)))
                context.stroke(Path(box), with: .color(accent.opacity(0.7)), lineWidth: 1)
            }
            // Snap guides.
            for guide in guides {
                var path = Path()
                if guide.vertical {
                    path.move(to: CGPoint(x: guide.position, y: guide.from))
                    path.addLine(to: CGPoint(x: guide.position, y: guide.to))
                } else {
                    path.move(to: CGPoint(x: guide.from, y: guide.position))
                    path.addLine(to: CGPoint(x: guide.to, y: guide.position))
                }
                context.stroke(path, with: .color(theme.red.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private var isResizing: Bool {
        if case .resize? = drag { return true }
        return false
    }

    // MARK: Renaming in place

    @ViewBuilder private var inlineEditor: some View {
        if let editing, let frame = editorFrame(editing) {
            InlineField(text: binding(for: editing), placeholder: editing.field == .label ? "Label" : "Name") {
                self.editing = nil
                focused = true
            }
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .id(editing.id)
        }
    }

    private func editorFrame(_ editing: InlineEdit) -> CGRect? {
        switch editing.field {
        case .title:
            guard let node = diagram.node(editing.id) else { return nil }
            let r = node.rect
            let width = max(r.width - 12, 140)
            return CGRect(x: r.midX - width / 2, y: node.kind.isContainer || node.kind == .title ? r.minY + 4 : r.midY - 14, width: width, height: 28)
        case .label:
            guard let link = diagram.link(editing.id), let a = diagram.node(link.from)?.rect, let b = diagram.node(link.to)?.rect else { return nil }
            let middle = MapInk.path(.route(link.route, a, b)).trimmedPath(from: 0, to: 0.5).currentPoint ?? .zero
            return CGRect(x: middle.x - 80, y: middle.y - 14, width: 160, height: 28)
        }
    }

    private func binding(for editing: InlineEdit) -> Binding<String> {
        Binding {
            editing.field == .label ? (diagram.link(editing.id)?.label ?? "") : (diagram.node(editing.id)?.title ?? "")
        } set: { text in
            document.change(editing.field == .label ? "Change Label" : "Rename", coalescing: "inline:\(editing.id)") { diagram in
                if editing.field == .label {
                    if let index = diagram.links.firstIndex(where: { $0.id == editing.id }) { diagram.links[index].label = text }
                } else if let index = diagram.nodes.firstIndex(where: { $0.id == editing.id }) {
                    diagram.nodes[index].title = text
                }
            }
        }
    }

    // MARK: Keys

    private func deleteSelection(name: String = "Delete") {
        guard !document.selection.isEmpty else { return }
        let ids = document.selection
        document.change(name) { $0.delete(ids) }
        document.selection = []
    }

    private func nudge(_ direction: MoveCommandDirection) {
        let ids = Set(diagram.outermost(document.selection))
        guard !ids.isEmpty else { return }
        let step: CGFloat = NSEvent.modifierFlags.contains(.shift) ? Diagram.grid * 2 : 1
        let offset: CGSize = switch direction {
        case .left: CGSize(width: -step, height: 0)
        case .right: CGSize(width: step, height: 0)
        case .up: CGSize(width: 0, height: -step)
        case .down: CGSize(width: 0, height: step)
        @unknown default: .zero
        }
        document.change("Nudge", coalescing: "nudge") { $0.move(ids, by: offset) }
    }

    private func copyItems() -> [NSItemProvider] {
        let clip = diagram.clipboard(document.selection)
        guard !clip.nodes.isEmpty, let data = try? clip.encoded() else { return [] }
        return [NSItemProvider(item: data as NSData, typeIdentifier: UTType.json.identifier)]
    }

    private func paste(_ providers: [NSItemProvider]) {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.json.identifier) }) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
            guard let data, let clip = try? Diagram.decode(data), !clip.nodes.isEmpty else { return }
            Task { @MainActor in
                // Pasted where you're looking, or beside the originals when they're in view.
                let bounds = clip.bounds
                let target = viewCenter
                let offset = bounds.isNull || bounds.insetBy(dx: -200, dy: -200).contains(target)
                    ? CGSize(width: 24, height: 24) : CGSize(width: target.x - bounds.midX, height: target.y - bounds.midY)
                var added: Set<String> = []
                document.change("Paste") { added = $0.paste(clip, offset: offset) }
                document.selection = added
            }
        }
    }
}

/// A text field over the canvas for renaming in place: Return or clicking away ends it.
private struct InlineField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    let placeholder: String
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.dante(size: 12.5, weight: .semibold))
            .foregroundStyle(theme.text.color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(theme.card.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.accent.color, lineWidth: 1.5))
            .shadow(color: theme.accent.color.opacity(0.25), radius: 8)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit(done)
            .onExitCommand(perform: done)
            .onChange(of: focused) { _, now in if !now { done() } }
    }
}

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func inset(top: CGFloat) -> CGRect {
        CGRect(x: minX, y: minY + top, width: width, height: max(0, height - top))
    }
}
