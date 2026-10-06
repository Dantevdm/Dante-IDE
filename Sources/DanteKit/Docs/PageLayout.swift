import CoreGraphics

/// Splits a run of blocks of known heights across fixed-height pages, for exporting docs.
/// Blocks that fit on a page are never split, long ones are sliced, and a block marked
/// `keepsWithNext` (a heading) moves to the next page rather than end one alone.
public enum PageLayout {
    public struct Slice: Equatable, Sendable {
        public var block: Int
        public var page: Int
        /// Where the slice starts on its page, from the top of the usable area.
        public var y: CGFloat
        /// Where the slice starts within its block, from the block's top.
        public var offset: CGFloat
        public var height: CGFloat
    }

    public static func slices(heights: [CGFloat], keepsWithNext: [Bool] = [], usable: CGFloat, gap: CGFloat) -> [Slice] {
        var result: [Slice] = []
        var page = 0
        var y: CGFloat = 0
        func newPage() { page += 1; y = 0 }
        for (index, height) in heights.enumerated() where height > 0 {
            if y > 0, y + height > usable, height <= usable { newPage() }
            if y > 0, index < keepsWithNext.count, keepsWithNext[index],
               let next = heights[(index + 1)...].first(where: { $0 > 0 }) {
                // Blocks that fit on a page move whole, so the heading goes with them; longer ones split.
                let together = height + gap + (next <= usable ? next : min(next, 120))
                if y + together > usable, together <= usable { newPage() }
            }
            var offset: CGFloat = 0
            while offset < height {
                if y >= usable - 20 { newPage() }
                let slice = min(height - offset, usable - y)
                result.append(Slice(block: index, page: page, y: y, offset: offset, height: slice))
                offset += slice
                y += slice
            }
            y += gap
        }
        return result
    }
}
