import CoreGraphics
import Foundation

/// Where each topic of a mind map goes: the central topic at the origin, main branches
/// shared between the right and the left so both sides are about as tall (the first ones on
/// the right, then round to the left, like a clock), each branch's topics stacked and
/// centred beside their parent. Folded topics hide what's under them.
public struct MindMapLayout: Equatable, Sendable {
    public enum Side: Equatable, Sendable { case center, right, left }

    public struct Place: Equatable, Sendable {
        public var frame: CGRect
        public var side: Side
        /// 0 for the central topic, 1 for main branches.
        public var depth: Int
        /// The main branch it grows from (its colour), nil for the central topic.
        public var branch: Int?
        public var parent: String?
    }

    public var places: [String: Place]
    /// Topics in drawing order (parents before children).
    public var order: [String]

    public var bounds: CGRect {
        places.values.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    public static let across: CGFloat = 44
    public static let between: CGFloat = 14

    public init(root: MindMap.Topic, size: (MindMap.Topic, Int) -> CGSize) {
        var places: [String: Place] = [:]
        var order: [String] = []
        var heights: [String: CGFloat] = [:]

        func height(_ topic: MindMap.Topic, depth: Int) -> CGFloat {
            let own = size(topic, depth).height
            guard !topic.folded, !topic.children.isEmpty else { heights[topic.id] = own; return own }
            let children = topic.children.map { height($0, depth: depth + 1) }
            let total = max(own, children.reduce(0, +) + Self.between * CGFloat(children.count - 1))
            heights[topic.id] = total
            return total
        }

        func place(_ topic: MindMap.Topic, edge: CGFloat, middle: CGFloat, side: Side, depth: Int, branch: Int, parent: String) {
            let own = size(topic, depth)
            let x = side == .right ? edge : edge - own.width
            places[topic.id] = Place(frame: CGRect(x: x, y: middle - own.height / 2, width: own.width, height: own.height),
                                     side: side, depth: depth, branch: branch, parent: parent)
            order.append(topic.id)
            guard !topic.folded, !topic.children.isEmpty else { return }
            let next = side == .right ? x + own.width + Self.across : x - Self.across
            stack(topic.children, edge: next, middle: middle, side: side, depth: depth + 1, branch: { _ in branch }, parent: topic.id)
        }

        func stack(_ topics: [MindMap.Topic], edge: CGFloat, middle: CGFloat, side: Side, depth: Int, branch: (Int) -> Int, parent: String) {
            let total = topics.map { heights[$0.id] ?? 0 }.reduce(0, +) + Self.between * CGFloat(max(0, topics.count - 1))
            var y = middle - total / 2
            for (index, topic) in topics.enumerated() {
                let h = heights[topic.id] ?? 0
                place(topic, edge: edge, middle: y + h / 2, side: side, depth: depth, branch: branch(index), parent: parent)
                y += h + Self.between
            }
        }

        let center = size(root, 0)
        places[root.id] = Place(frame: CGRect(x: -center.width / 2, y: -center.height / 2, width: center.width, height: center.height),
                                side: .center, depth: 0, branch: nil, parent: nil)
        order.append(root.id)
        if !root.folded, !root.children.isEmpty {
            let mains = root.children.map { height($0, depth: 1) }
            let split = Self.split(mains)
            let right = Array(root.children[..<split])
            // The left side reads round the clock: its last branch at the top.
            let left = Array(root.children[split...].reversed())
            stack(right, edge: center.width / 2 + Self.across, middle: 0, side: .right, depth: 1, branch: { $0 }, parent: root.id)
            stack(left, edge: -center.width / 2 - Self.across, middle: 0, side: .left, depth: 1,
                  branch: { root.children.count - 1 - $0 }, parent: root.id)
        }
        self.places = places
        self.order = order
    }

    /// How many main branches go on the right: the first `k` whose height is nearest half,
    /// at least one, and all of them when there are only two or fewer.
    static func split(_ heights: [CGFloat]) -> Int {
        guard heights.count > 2 else { return heights.count }
        let total = heights.reduce(0, +)
        var best = 1, bestGap = CGFloat.infinity, running: CGFloat = 0
        for k in 1..<heights.count {
            running += heights[k - 1]
            let gap = abs(running - (total - running))
            if gap < bestGap { best = k; bestGap = gap }
        }
        return best
    }
}
