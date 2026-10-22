import CoreGraphics
import Foundation

// MARK: Tidying a drawn diagram

extension Diagram {
    /// Room between columns: cards side by side in a group, and things side by side elsewhere,
    /// with more where the links crossing the gap carry labels, so a label sits clear of the cards.
    public static let columnGap: CGFloat = 56
    public static let labelledColumnGap: CGFloat = 120
    /// Room between things stacked in a column: cards in a group, and groups.
    static let stackGap: CGFloat = 12
    static let groupStackGap: CGFloat = 32

    /// The same picture with even spacing: what's side by side stays side by side, but columns
    /// are spread so link labels fit between them, stacks close up evenly, cards get the size
    /// their text needs (a column of cards shares the widest) and every container fits what it
    /// holds. Within a stack, things move next to what they're linked to when that shortens the
    /// links, so fewer of them cross.
    ///
    /// With `only`, just those: a container tidies what's inside it, and several things in the
    /// same place are spaced among themselves from where they are; the rest stays put.
    public func tidied(only selection: Set<String>? = nil) -> Diagram {
        var copy = self
        guard let selection, !selection.isEmpty else {
            let start = bounds.isNull ? CGPoint(x: 40, y: 40) : bounds.origin
            _ = copy.arrange(nodes.filter { $0.parent == nil }, parent: nil, at: start)
            copy.normalise(margin: 24)
            return copy
        }
        // Outermost chosen things only: tidying a container covers what's in it.
        let chosen = nodes.filter { node in selection.contains(node.id) && !ancestors(of: node.id).contains { selection.contains($0.id) } }
        for container in chosen where container.kind.isContainer {
            let r = copy.node(container.id)!.rect
            let inner = copy.arrange(copy.children(of: container.id), parent: container.id,
                                     at: CGPoint(x: r.minX + Self.inset, y: r.minY + Self.headerHeight(container.kind)))
            if inner != .zero, let index = copy.nodes.firstIndex(where: { $0.id == container.id }) {
                copy.nodes[index].frame = Rect(CGRect(x: r.minX, y: r.minY, width: inner.width + Self.inset * 2,
                                                      height: inner.height + Self.headerHeight(container.kind) + Self.inset))
            }
            copy.growAncestors(of: container.id)
        }
        let loose = Dictionary(grouping: chosen.filter { !$0.kind.isContainer || chosen.count > 1 }) { $0.parent ?? "" }
        for (_, members) in loose where members.count > 1 || !members[0].kind.isContainer {
            let current = members.compactMap { copy.node($0.id) }
            let origin = current.map(\.rect).reduce(CGRect.null) { $0.union($1) }.origin
            _ = copy.arrange(current, parent: current[0].parent, at: origin)
            copy.growAncestors(of: current[0].id)
        }
        return copy
    }

    /// Laid out again from the links: what links to something comes before it, left to right,
    /// each column in the order that keeps links short, then tidied. For a picture whose
    /// arrangement doesn't follow how things connect. With `only`, inside those containers or
    /// among those things.
    public func arrangedByFlow(only selection: Set<String>? = nil) -> Diagram {
        var copy = self
        let scope: Set<String>
        if let selection, !selection.isEmpty {
            scope = Set(selection.flatMap { id in [id] + descendants(of: id).map(\.id) })
                .subtracting(selection.filter { node($0)?.kind.isContainer == true && selection.count == 1 })
        } else {
            scope = Set(nodes.map(\.id))
        }
        let before = nodes.filter { scope.contains($0.id) }.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        for index in copy.nodes.indices where scope.contains(copy.nodes[index].id) { copy.nodes[index].frame = nil }
        copy = copy.laidOut()
        // Put the rearranged part back where it was.
        let after = copy.nodes.filter { scope.contains($0.id) }.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        if !before.isNull, !after.isNull {
            let dx = before.minX - after.minX, dy = before.minY - after.minY
            for index in copy.nodes.indices where scope.contains(copy.nodes[index].id) {
                copy.nodes[index].frame = Rect(copy.nodes[index].rect.offsetBy(dx: dx, dy: dy))
            }
        }
        var result = copy.tidied(only: selection)
        for id in selection ?? [] { result.growAncestors(of: id) }
        return result
    }

    /// Lays out `members` (all with the same parent) from `origin`, returning the size they take.
    private mutating func arrange(_ members: [Node], parent: String?, at origin: CGPoint) -> CGSize {
        guard !members.isEmpty else { return .zero }
        let columns = shortened(Self.columns(of: members))
        let inGroup = parent.flatMap { node($0) }.map { $0.kind == .group } ?? false
        var x = origin.x
        var tallest: CGFloat = 0
        for (index, column) in columns.enumerated() {
            if index > 0 {
                x += inGroup ? Self.stackGap : (labelCrosses(from: columns[..<index].flatMap { $0 }, to: column) ? Self.labelledColumnGap : Self.columnGap)
            }
            // The column starts where its highest member was, so rows that lined up still do.
            var y = origin.y + (inGroup ? 0 : max(0, (column.map(\.rect.minY).min() ?? origin.y) - (members.map(\.rect.minY).min() ?? origin.y)))
            let cardWidth = column.filter { $0.kind == .card || $0.kind == .box || $0.kind == .stage }.map(Self.width(for:)).max()
            var widest: CGFloat = 0
            for (row, member) in column.enumerated() {
                if row > 0 { y += member.kind.isContainer || column[row - 1].kind.isContainer ? Self.groupStackGap : Self.stackGap }
                var size = member.rect.size
                if member.kind.isContainer {
                    let header = Self.headerHeight(member.kind)
                    let inner = arrange(children(of: member.id), parent: member.id, at: CGPoint(x: x + Self.inset, y: y + header))
                    if inner != .zero {
                        size = CGSize(width: inner.width + Self.inset * 2, height: inner.height + header + Self.inset)
                    }
                    let minimum = Self.minimumSize(member.kind)
                    size = CGSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height))
                } else if let cardWidth, member.kind == .card || member.kind == .box || member.kind == .stage {
                    size = CGSize(width: cardWidth, height: max(Self.height(for: member), member.kind == .stage ? member.kind.defaultSize.height : 0))
                }
                if let index = nodes.firstIndex(where: { $0.id == member.id }) {
                    nodes[index].frame = Rect(CGRect(origin: CGPoint(x: x, y: y), size: size))
                }
                y += size.height
                widest = max(widest, size.width)
            }
            tallest = max(tallest, y - origin.y)
            x += widest
        }
        return CGSize(width: x - origin.x, height: tallest)
    }

    /// Members grouped into columns, top to bottom: one joins a column when its middle is within
    /// the column's span, or the column's middle within its own.
    static func columns(of members: [Node]) -> [[Node]] {
        var columns: [(span: ClosedRange<CGFloat>, members: [Node])] = []
        for member in members.sorted(by: { ($0.rect.minX, $0.rect.minY) < ($1.rect.minX, $1.rect.minY) }) {
            let r = member.rect
            if let last = columns.indices.last {
                // By middles, so something that only reaches across a little (a wide boundary
                // beside a column of groups) starts a column of its own.
                let span = columns[last].span
                let middle = (span.lowerBound + span.upperBound) / 2
                if span.contains(r.midX) || (r.minX...r.maxX).contains(middle) {
                    columns[last].span = min(span.lowerBound, r.minX)...max(span.upperBound, r.maxX)
                    columns[last].members.append(member)
                    continue
                }
            }
            columns.append((r.minX...r.maxX, [member]))
        }
        return columns.map { $0.members.sorted { $0.rect.minY < $1.rect.minY } }
    }

    /// Each column's stack reordered so things sit next to what they're linked to, when that
    /// makes the links shorter: the first column keeps its order and each later one follows the
    /// columns before it, so links run straight across instead of crossing. A stack nothing
    /// links to keeps its order.
    private func shortened(_ columns: [[Node]]) -> [[Node]] {
        let level = Set(columns.flatMap { $0.map(\.id) })
        // Which member of this level holds a node, if any.
        var holder: [String: String] = [:]
        for id in level { holder[id] = id; for inner in descendants(of: id) { holder[inner.id] = id } }
        var placed: [String: CGFloat] = [:]   // members already ordered: their new middles
        func stack(_ order: [Node]) -> [String: CGFloat] {
            var y = order.first.map { _ in order.map(\.rect.minY).min()! } ?? 0
            var middles: [String: CGFloat] = [:]
            for member in order {
                middles[member.id] = y + member.rect.height / 2
                y += member.rect.height + Self.stackGap
            }
            return middles
        }
        func targets(_ member: Node) -> [CGFloat] {
            let own = Set([member.id] + descendants(of: member.id).map(\.id))
            return links.compactMap { link -> CGFloat? in
                let other: String
                if own.contains(link.from), !own.contains(link.to) { other = link.to }
                else if own.contains(link.to), !own.contains(link.from) { other = link.from }
                else { return nil }
                if let at = holder[other] { return placed[at] }   // later columns don't pull yet
                return node(other)?.rect.midY
            }
        }
        var result: [[Node]] = []
        for (index, column) in columns.enumerated() {
            var order = column
            if index > 0, column.count > 1 {
                let pulls = column.map { member -> CGFloat? in
                    let ys = targets(member)
                    return ys.isEmpty ? nil : ys.reduce(0, +) / CGFloat(ys.count)
                }
                if pulls.contains(where: { $0 != nil }) {
                    let reordered = zip(column, pulls).enumerated().sorted { a, b in
                        let ka = a.element.1 ?? a.element.0.rect.midY, kb = b.element.1 ?? b.element.0.rect.midY
                        return ka == kb ? a.offset < b.offset : ka < kb
                    }.map(\.element.0)
                    func stretch(_ candidate: [Node]) -> CGFloat {
                        let middles = stack(candidate)
                        return candidate.reduce(0) { total, member in total + targets(member).reduce(0) { $0 + abs($1 - middles[member.id]!) } }
                    }
                    if stretch(reordered) + 1 < stretch(column) { order = reordered }
                }
            }
            placed.merge(stack(order)) { $1 }
            result.append(order)
        }
        return result
    }

    /// Whether a labelled link joins something in `left` (or inside it) to something in `right`.
    private func labelCrosses(from left: [Node], to right: [Node]) -> Bool {
        func within(_ group: [Node]) -> Set<String> {
            Set(group.flatMap { [$0.id] + descendants(of: $0.id).map(\.id) })
        }
        let a = within(left), b = within(right)
        return links.contains { !$0.label.isEmpty && ((a.contains($0.from) && b.contains($0.to)) || (b.contains($0.from) && a.contains($0.to))) }
    }

    /// A card wide enough for its title on one line (12 pt semibold, beside the icon), up to a limit.
    static func width(for node: Node) -> CGFloat {
        let base = node.kind.defaultSize.width
        let needed = 66 + CGFloat(node.title.count) * 6.9
        return min(280, max(base, needed.rounded(.up)))
    }

    /// A card tall enough for its title and the lines under it.
    static func height(for node: Node) -> CGFloat {
        node.detail.isEmpty && node.subtitle.isEmpty ? 48 : node.detail.isEmpty || node.subtitle.isEmpty ? 56 : 64
    }
}
