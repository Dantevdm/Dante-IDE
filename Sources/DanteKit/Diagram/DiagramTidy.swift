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

    /// The same picture with even spacing: what's side by side stays side by side and what's
    /// stacked stays stacked, in the same order, but columns are spread so link labels fit
    /// between them, stacks close up evenly, cards get the size their text needs (a column of
    /// cards shares the widest) and every container fits what it holds.
    public func tidied() -> Diagram {
        var copy = self
        let start = bounds.isNull ? CGPoint(x: 40, y: 40) : bounds.origin
        _ = copy.arrange(children: nil, at: start)
        copy.normalise(margin: 24)
        return copy
    }

    /// Lays out what `parent` holds from `origin`, returning the size it takes.
    private mutating func arrange(children parent: String?, at origin: CGPoint) -> CGSize {
        let members = nodes.filter { $0.parent == parent }
        guard !members.isEmpty else { return .zero }
        let columns = Self.columns(of: members)
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
                    let inner = arrange(children: member.id, at: CGPoint(x: x + Self.inset, y: y + header))
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
