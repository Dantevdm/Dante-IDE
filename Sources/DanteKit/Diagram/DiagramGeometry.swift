import CoreGraphics
import Foundation

/// How a link runs between two boxes: one cubic curve. The Map's views, the diagram editor
/// and the SVG export all draw links through this, so they bend the same way everywhere.
public struct LinkCurve: Equatable, Sendable {
    public var start, control1, control2, end: CGPoint

    public init(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }

    /// The Infra view's: side to side when one is beside the other, else top to bottom.
    public static func direct(_ a: CGRect, _ b: CGRect) -> LinkCurve {
        if b.minX >= a.maxX - 4 {
            let start = CGPoint(x: a.maxX, y: a.midY), end = CGPoint(x: b.minX - 2, y: b.midY)
            let bend = max((end.x - start.x) / 2, 24)
            return LinkCurve(start: start, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y), end: end)
        }
        if b.maxX <= a.minX + 4 {
            let start = CGPoint(x: a.minX, y: a.midY), end = CGPoint(x: b.maxX + 2, y: b.midY)
            let bend = max((start.x - end.x) / 2, 24)
            return LinkCurve(start: start, control1: CGPoint(x: start.x - bend, y: start.y), control2: CGPoint(x: end.x + bend, y: end.y), end: end)
        }
        let down = b.midY > a.midY
        let start = CGPoint(x: a.midX, y: down ? a.maxY : a.minY), end = CGPoint(x: b.midX, y: down ? b.minY - 2 : b.maxY + 2)
        let bend = max(abs(end.y - start.y) / 2, 18)
        return LinkCurve(start: start, control1: CGPoint(x: start.x, y: start.y + (down ? bend : -bend)),
                         control2: CGPoint(x: end.x, y: end.y + (down ? -bend : bend)), end: end)
    }

    /// The System map's: between columns a curve from edge to edge; within a column a loop out
    /// to the right, so it doesn't run under the boxes in between.
    public static func loop(_ a: CGRect, _ b: CGRect) -> LinkCurve {
        if b.minX > a.maxX {
            let start = CGPoint(x: a.maxX, y: a.midY), end = CGPoint(x: b.minX - 2, y: b.midY)
            let bend = max((end.x - start.x) / 2, 30)
            return LinkCurve(start: start, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y), end: end)
        }
        if b.maxX < a.minX {
            let start = CGPoint(x: a.minX, y: a.midY), end = CGPoint(x: b.maxX + 2, y: b.midY)
            let bend = max((start.x - end.x) / 2, 30)
            return LinkCurve(start: start, control1: CGPoint(x: start.x - bend, y: start.y), control2: CGPoint(x: end.x + bend, y: end.y), end: end)
        }
        let start = CGPoint(x: a.maxX, y: a.midY), end = CGPoint(x: b.maxX + 2, y: b.midY)
        let reach = 22 + min(abs(end.y - start.y) / 8, 18)
        return LinkCurve(start: start, control1: CGPoint(x: start.x + reach, y: start.y), control2: CGPoint(x: end.x + reach, y: end.y), end: end)
    }

    /// The Infra view's drop from a pipeline stage down into the cloud.
    public static func drop(_ a: CGRect, _ b: CGRect) -> LinkCurve {
        let start = CGPoint(x: a.midX, y: a.maxY), end = CGPoint(x: b.midX, y: b.minY - 2)
        let bend = max((end.y - start.y) / 2, 30)
        return LinkCurve(start: start, control1: CGPoint(x: start.x, y: start.y + bend), control2: CGPoint(x: end.x, y: end.y - bend), end: end)
    }

    public static func route(_ route: Diagram.Link.Route, _ a: CGRect, _ b: CGRect) -> LinkCurve {
        route == .loop ? loop(a, b) : direct(a, b)
    }

    /// The point `t` (0…1) of the way along the curve's parameter.
    public func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                       y: a * start.y + b * control1.y + c * control2.y + d * end.y)
    }

    /// The direction it arrives in, for an arrowhead.
    public var endAngle: CGFloat {
        let before = point(at: 0.97)
        return atan2(end.y - before.y, end.x - before.x)
    }

    /// How far a point is from the curve, roughly (sampled), for clicking on a link.
    public func distance(to target: CGPoint) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for step in 0...40 {
            let p = point(at: CGFloat(step) / 40)
            best = min(best, hypot(p.x - target.x, p.y - target.y))
        }
        return best
    }

    /// "M x y C …" for an SVG path.
    public var svg: String {
        func f(_ p: CGPoint) -> String { "\(DiagramSVG.number(p.x)) \(DiagramSVG.number(p.y))" }
        return "M\(f(start)) C\(f(control1)) \(f(control2)) \(f(end))"
    }
}

/// Snapping a moving box to the grid and to the edges and middles of the boxes around it,
/// with the guide lines to show while it holds.
public enum DiagramSnap {
    public struct Guide: Equatable, Sendable, Hashable {
        /// True for a vertical line at `position` (an x); false for a horizontal one (a y).
        public var vertical: Bool
        public var position: CGFloat
        public var from: CGFloat
        public var to: CGFloat
    }

    public struct Result: Equatable, Sendable {
        public var offset: CGSize
        public var guides: [Guide]
    }

    /// How far `rect` should shift to line up with `others` (within `threshold`), or else to
    /// the grid, and the guides that show it.
    public static func snap(_ rect: CGRect, to others: [CGRect], threshold: CGFloat = 5, grid: CGFloat = Diagram.grid) -> Result {
        let xs = [rect.minX, rect.midX, rect.maxX]
        let ys = [rect.minY, rect.midY, rect.maxY]
        var bestX: (delta: CGFloat, position: CGFloat)?
        var bestY: (delta: CGFloat, position: CGFloat)?
        for other in others {
            for target in [other.minX, other.midX, other.maxX] {
                for x in xs where abs(target - x) <= threshold && abs(target - x) < abs(bestX?.delta ?? .infinity) {
                    bestX = (target - x, target)
                }
            }
            for target in [other.minY, other.midY, other.maxY] {
                for y in ys where abs(target - y) <= threshold && abs(target - y) < abs(bestY?.delta ?? .infinity) {
                    bestY = (target - y, target)
                }
            }
        }
        let dx = bestX?.delta ?? ((rect.minX / grid).rounded() * grid - rect.minX)
        let dy = bestY?.delta ?? ((rect.minY / grid).rounded() * grid - rect.minY)
        let moved = rect.offsetBy(dx: dx, dy: dy)
        var guides: [Guide] = []
        if let x = bestX?.position {
            let touching = others.filter { [$0.minX, $0.midX, $0.maxX].contains { abs($0 - x) < 0.5 } } + [moved]
            guides.append(Guide(vertical: true, position: x, from: touching.map(\.minY).min()! - 8, to: touching.map(\.maxY).max()! + 8))
        }
        if let y = bestY?.position {
            let touching = others.filter { [$0.minY, $0.midY, $0.maxY].contains { abs($0 - y) < 0.5 } } + [moved]
            guides.append(Guide(vertical: false, position: y, from: touching.map(\.minX).min()! - 8, to: touching.map(\.maxX).max()! + 8))
        }
        return Result(offset: CGSize(width: dx, height: dy), guides: guides)
    }
}
