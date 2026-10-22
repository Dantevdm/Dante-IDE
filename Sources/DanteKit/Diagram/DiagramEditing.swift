import CoreGraphics
import Foundation

/// Every change the editor makes, as plain functions on the value, so undo is a copy and
/// each rule (a group grows to hold its cards, moving a group moves what's in it) is tested.
extension Diagram {
    /// Room inside a group or boundary around what it holds, and above it for the header.
    public static let inset: CGFloat = 12
    public static func headerHeight(_ kind: Node.Kind) -> CGFloat { kind == .boundary ? 40 : 32 }

    // MARK: Adding

    /// Adds a node of `kind` centred on `point` (snapped to the grid), and returns its id.
    @discardableResult
    /// With `findsRoom`, the node goes to the nearest place around `point` where it covers no card.
    public mutating func add(_ kind: Node.Kind, title: String? = nil, at point: CGPoint, findsRoom: Bool = false,
                             configure: (inout Node) -> Void = { _ in }) -> String {
        let title = title ?? Self.defaultTitle(kind)
        var node = Node(id: uniqueID(for: title), kind: kind, title: title)
        configure(&node)
        let size = node.frame.map { CGSize(width: $0.width, height: $0.height) } ?? kind.defaultSize
        var origin = CGPoint(x: Self.snapped(point.x - size.width / 2), y: Self.snapped(point.y - size.height / 2))
        if findsRoom { origin = room(for: size, near: origin) }
        node.frame = Rect(CGRect(origin: CGPoint(x: max(0, origin.x), y: max(0, origin.y)), size: size))
        nodes.append(node)
        adopt([node.id])
        return node.id
    }

    /// The nearest origin, ring by ring outwards, where a box of `size` keeps clear of every
    /// node that isn't a container (containers grow round what lands in them).
    func room(for size: CGSize, near origin: CGPoint) -> CGPoint {
        let solid = nodes.filter { !$0.kind.isContainer }.compactMap { $0.frame?.cg.insetBy(dx: -12, dy: -12) }
        func free(_ point: CGPoint) -> Bool {
            point.x >= 0 && point.y >= 0 && !solid.contains { $0.intersects(CGRect(origin: point, size: size)) }
        }
        if free(origin) { return origin }
        let step = Self.grid * 3
        for ring in 1...40 {
            let r = CGFloat(ring) * step
            var candidates: [CGPoint] = []
            for i in -ring...ring {
                let d = CGFloat(i) * step
                candidates += [CGPoint(x: origin.x + d, y: origin.y + r), CGPoint(x: origin.x + d, y: origin.y - r),
                               CGPoint(x: origin.x + r, y: origin.y + d), CGPoint(x: origin.x - r, y: origin.y + d)]
            }
            let near = candidates.filter(free).min { hypot($0.x - origin.x, $0.y - origin.y) < hypot($1.x - origin.x, $1.y - origin.y) }
            if let near { return near }
        }
        return origin
    }

    public static func defaultTitle(_ kind: Node.Kind) -> String {
        switch kind {
        case .card: "New card"
        case .box: "New part"
        case .group: "Group"
        case .boundary: "Cloud"
        case .person: "Users"
        case .stage: "New stage"
        case .source: "pipeline"
        case .title: "Delivery"
        case .text: "A note about this part of the picture."
        }
    }

    /// Joins two nodes. A second link the same way isn't added; its id comes back instead.
    @discardableResult
    public mutating func connect(_ from: String, to: String, label: String = "") -> String? {
        guard from != to, let target = node(to), node(from) != nil else { return nil }
        if let existing = links.first(where: { $0.from == from && $0.to == to }) { return existing.id }
        let id = uniqueID(for: "\(from) to \(to)")
        // Traffic towards a card is coloured like the card; into a group or a person, quiet.
        let hue: Hue? = [.card, .box, .stage].contains(target.kind) ? target.hue : nil
        links.append(.traffic(id: id, from: from, to: to, label: label, hue: hue))
        return id
    }

    // MARK: Moving and sizing

    /// Moves nodes and everything inside them, then grows the containers around them. While
    /// dragging, `grows` is off: a card can leave its group, and `adopt` settles it on drop.
    public mutating func move(_ ids: Set<String>, by offset: CGSize, grows: Bool = true) {
        guard offset != .zero else { return }
        var moving = ids
        for id in ids { moving.formUnion(descendants(of: id).map(\.id)) }
        for index in nodes.indices where moving.contains(nodes[index].id) {
            guard var frame = nodes[index].frame else { continue }
            frame.x += offset.width
            frame.y += offset.height
            nodes[index].frame = frame
        }
        if grows { for id in ids { growAncestors(of: id) } }
    }

    /// Sets a node's frame; a container never gets smaller than what it holds.
    public mutating func resize(_ id: String, to rect: CGRect) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        let kind = nodes[index].kind
        var rect = rect.standardized
        let minimum = Self.minimumSize(kind)
        rect.size.width = max(rect.width, minimum.width)
        rect.size.height = max(rect.height, minimum.height)
        if kind.isContainer, let needed = contentsFrame(of: id) {
            rect = rect.union(needed)
        }
        nodes[index].frame = Rect(rect)
        growAncestors(of: id)
    }

    public static func minimumSize(_ kind: Node.Kind) -> CGSize {
        switch kind {
        case .group: CGSize(width: 120, height: 60)
        case .boundary: CGSize(width: 160, height: 90)
        case .person: CGSize(width: 48, height: 64)
        case .title: CGSize(width: 80, height: 18)
        case .text: CGSize(width: 60, height: 20)
        default: CGSize(width: 110, height: 40)
        }
    }

    /// Where a container's contents need it to reach, with room for its header.
    func contentsFrame(of id: String) -> CGRect? {
        guard let container = node(id) else { return nil }
        let inside = children(of: id).compactMap { $0.frame?.cg }
        guard !inside.isEmpty else { return nil }
        let union = inside.reduce(CGRect.null) { $0.union($1) }
        let header = Self.headerHeight(container.kind)
        return CGRect(x: union.minX - Self.inset, y: union.minY - header, width: union.width + Self.inset * 2, height: union.height + header + Self.inset)
    }

    /// Each container holding `id` grows, if it must, to hold it.
    mutating func growAncestors(of id: String) {
        for ancestor in ancestors(of: id) {
            guard let index = nodes.firstIndex(where: { $0.id == ancestor.id }), let needed = contentsFrame(of: ancestor.id) else { continue }
            let current = nodes[index].rect
            if !current.contains(needed) { nodes[index].frame = Rect(current.union(needed)) }
        }
    }

    /// Shrinks or grows a container to just hold what's in it.
    public mutating func fit(_ id: String) {
        guard let index = nodes.firstIndex(where: { $0.id == id }), nodes[index].kind.isContainer, let needed = contentsFrame(of: id) else { return }
        nodes[index].frame = Rect(needed)
        growAncestors(of: id)
    }

    // MARK: Groups

    /// Puts each node in the innermost container its middle is over (or none), then grows
    /// that container to hold it. Containers never go inside what they hold.
    public mutating func adopt(_ ids: Set<String>) {
        for id in ids {
            guard let node = node(id), let frame = node.frame else { continue }
            let inside = Set(descendants(of: id).map(\.id)).union([id])
            let center = frame.center
            let holder = nodes
                .filter { $0.kind.isContainer && !inside.contains($0.id) && ($0.frame?.cg.contains(center) ?? false) }
                // Containers can't hold one as big as themselves.
                .filter { !node.kind.isContainer || ($0.rect.width * $0.rect.height > frame.width * frame.height) }
                .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
            guard let index = nodes.firstIndex(where: { $0.id == id }) else { continue }
            nodes[index].parent = holder?.id
            growAncestors(of: id)
        }
    }

    /// A new group around the nodes, in the container they shared.
    @discardableResult
    public mutating func group(_ ids: Set<String>, title: String = "Group") -> String? {
        let members = nodes.filter { ids.contains($0.id) && !ids.contains($0.parent ?? "") }
        guard !members.isEmpty else { return nil }
        let union = members.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        let parents = Set(members.map(\.parent))
        let id = uniqueID(for: title)
        let header = Self.headerHeight(.group)
        let frame = CGRect(x: union.minX - Self.inset, y: union.minY - header, width: union.width + Self.inset * 2, height: union.height + header + Self.inset)
        let hue = members.first?.hue ?? .blue
        // Behind the members, so they stay clickable.
        let first = nodes.firstIndex { ids.contains($0.id) } ?? nodes.endIndex
        nodes.insert(Node(id: id, kind: .group, title: title, icon: "square.stack.3d.up", hue: hue, frame: Rect(frame),
                          parent: parents.count == 1 ? parents.first! : nil), at: first)
        for index in nodes.indices where members.contains(where: { $0.id == nodes[index].id }) {
            nodes[index].parent = id
        }
        growAncestors(of: id)
        return id
    }

    /// Takes a container away, leaving what it held where it was.
    public mutating func ungroup(_ id: String) {
        guard let container = node(id), container.kind.isContainer else { return }
        for index in nodes.indices where nodes[index].parent == id { nodes[index].parent = container.parent }
        nodes.removeAll { $0.id == id }
        links.removeAll { $0.from == id || $0.to == id }
    }

    // MARK: Removing and copying

    /// Removes nodes with what's inside them and their links, or links by id.
    public mutating func delete(_ ids: Set<String>) {
        var gone = ids
        for id in ids { gone.formUnion(descendants(of: id).map(\.id)) }
        nodes.removeAll { gone.contains($0.id) }
        links.removeAll { gone.contains($0.id) || gone.contains($0.from) || gone.contains($0.to) }
    }

    /// Copies of the nodes (with what's inside them) and the links between them, moved by
    /// `offset`. Returns the copies' ids, outermost only.
    @discardableResult
    public mutating func duplicate(_ ids: Set<String>, offset: CGSize = CGSize(width: 24, height: 24)) -> Set<String> {
        let clip = clipboard(ids)
        return paste(clip, offset: offset)
    }

    /// What Copy puts on the clipboard: the nodes, everything inside them, and the links among them.
    public func clipboard(_ ids: Set<String>) -> Diagram {
        var keep = Set(ids.filter { node($0) != nil })
        for id in ids { keep.formUnion(descendants(of: id).map(\.id)) }
        var copy = Diagram(title: title)
        copy.nodes = nodes.filter { keep.contains($0.id) }.map { node in
            var node = node
            if let parent = node.parent, !keep.contains(parent) { node.parent = nil }
            return node
        }
        copy.links = links.filter { keep.contains($0.from) && keep.contains($0.to) }
        return copy
    }

    /// Adds another diagram's nodes and links with fresh ids; returns the outermost new ids.
    @discardableResult
    public mutating func paste(_ clip: Diagram, offset: CGSize) -> Set<String> {
        var renamed: [String: String] = [:]
        var taken: Set<String> = []
        for node in clip.nodes {
            let id = uniqueID(for: node.id, taken: taken)
            renamed[node.id] = id
            taken.insert(id)
        }
        var added: Set<String> = []
        for var node in clip.nodes {
            node.id = renamed[node.id]!
            node.parent = node.parent.flatMap { renamed[$0] }
            if var frame = node.frame {
                frame.x += offset.width
                frame.y += offset.height
                node.frame = frame
            }
            if node.parent == nil { added.insert(node.id) }
            nodes.append(node)
        }
        for var link in clip.links {
            guard let from = renamed[link.from], let to = renamed[link.to] else { continue }
            link.id = uniqueID(for: "\(from) to \(to)", taken: taken)
            taken.insert(link.id)
            link.from = from
            link.to = to
            links.append(link)
        }
        adopt(added)
        return added
    }

    // MARK: Arranging

    public enum Edge: String, CaseIterable, Sendable {
        case left, centerX, right, top, centerY, bottom
    }

    /// Lines the nodes up on the first one's edge or middle (the outermost ones; what's
    /// inside moves with them).
    public mutating func align(_ ids: Set<String>, _ edge: Edge) {
        let members = outermost(ids)
        guard members.count > 1 else { return }
        let union = members.compactMap { node($0)?.rect }.reduce(CGRect.null) { $0.union($1) }
        for id in members {
            guard let rect = node(id)?.rect else { continue }
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch edge {
            case .left: dx = union.minX - rect.minX
            case .centerX: dx = union.midX - rect.midX
            case .right: dx = union.maxX - rect.maxX
            case .top: dy = union.minY - rect.minY
            case .centerY: dy = union.midY - rect.midY
            case .bottom: dy = union.maxY - rect.maxY
            }
            move([id], by: CGSize(width: dx.rounded(), height: dy.rounded()))
        }
    }

    /// Equal gaps between three or more nodes, across or down.
    public mutating func distribute(_ ids: Set<String>, horizontally: Bool) {
        let members = outermost(ids).compactMap { id in node(id).map { (id, $0.rect) } }
            .sorted { horizontally ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }
        guard members.count > 2, let first = members.first?.1, let last = members.last?.1 else { return }
        let span = horizontally ? last.maxX - first.minX : last.maxY - first.minY
        let filled = members.reduce(CGFloat(0)) { $0 + (horizontally ? $1.1.width : $1.1.height) }
        let gap = (span - filled) / CGFloat(members.count - 1)
        var cursor = horizontally ? first.minX : first.minY
        for (id, rect) in members {
            let delta = cursor - (horizontally ? rect.minX : rect.minY)
            move([id], by: horizontally ? CGSize(width: delta.rounded(), height: 0) : CGSize(width: 0, height: delta.rounded()))
            cursor += (horizontally ? rect.width : rect.height) + gap
        }
    }

    /// The ids whose containers aren't also in the set.
    public func outermost(_ ids: Set<String>) -> [String] {
        nodes.filter { ids.contains($0.id) && !ancestors(of: $0.id).contains { ids.contains($0.id) } }.map(\.id)
    }

    /// Moves a node to the front or back of its kind's layer.
    public mutating func reorder(_ ids: Set<String>, toFront: Bool) {
        let moving = nodes.filter { ids.contains($0.id) }
        nodes.removeAll { ids.contains($0.id) }
        nodes = toFront ? nodes + moving : moving + nodes
    }

    /// Shifts everything so nothing sits left of or above `margin`.
    public mutating func normalise(margin: CGFloat = 40) {
        let box = bounds
        guard !box.isNull else { return }
        let dx = box.minX < margin ? margin - box.minX : 0
        let dy = box.minY < margin ? margin - box.minY : 0
        guard dx != 0 || dy != 0 else { return }
        for index in nodes.indices {
            guard var frame = nodes[index].frame else { continue }
            frame.x += dx
            frame.y += dy
            nodes[index].frame = frame
        }
    }

    // MARK: The grid

    public static let grid: CGFloat = 8

    public static func snapped(_ value: CGFloat) -> CGFloat { (value / grid).rounded() * grid }
}
