import CoreGraphics
import Foundation

/// Dante's mark, the Vine D: a stalk for the stem, a vine growing from its tip round into the
/// bowl and ending in a tendril, leaves along it, fireflies inside. The geometry is in the app
/// icon's 1024 grid (y down) and the colours are the same in every theme, since a logo doesn't
/// follow the theme. `DanteLogo` draws it in the Mac app and `VineLogo` in the companion; scripts/make_icon.swift has a copy.
public enum Logo {
    public typealias Curve = (start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint)

    public struct Leaf: Sendable {
        public let x, y: Double
        /// Degrees, clockwise from pointing right.
        public let angle: Double
        /// Length in the 1024 grid.
        public let size: Double
        public let light: Bool
        /// How far along the vine it grows, 0…1; nil for the leaf at the stalk's tip.
        public let along: Double?
        /// Seconds its sway lags behind the first leaf's.
        public let delay: Double
    }

    public static let stalk: Curve = (CGPoint(x: 330, y: 760), CGPoint(x: 326, y: 600), CGPoint(x: 334, y: 440), CGPoint(x: 330, y: 300))
    public static let vine: [Curve] = [
        (CGPoint(x: 330, y: 300), CGPoint(x: 560, y: 250), CGPoint(x: 720, y: 380), CGPoint(x: 700, y: 520)),
        (CGPoint(x: 700, y: 520), CGPoint(x: 682, y: 650), CGPoint(x: 540, y: 740), CGPoint(x: 382, y: 722)),
    ]
    public static let tendril: [Curve] = [
        (CGPoint(x: 382, y: 722), CGPoint(x: 346, y: 716), CGPoint(x: 340, y: 684), CGPoint(x: 366, y: 672)),
        (CGPoint(x: 366, y: 672), CGPoint(x: 388, y: 662), CGPoint(x: 404, y: 684), CGPoint(x: 388, y: 696)),
    ]
    public static let stalkWidth = 54.0, vineWidth = 38.0, tendrilWidth = 12.0

    /// Outward leaves along the vine, smaller ones facing in, and one at the stalk's tip.
    public static let leaves: [Leaf] = [
        Leaf(x: 488, y: 294, angle: -49, size: 112, light: true, along: 1 / 8, delay: 0),
        Leaf(x: 609, y: 339, angle: -25, size: 108, light: false, along: 2 / 8, delay: 0.35),
        Leaf(x: 609, y: 339, angle: 93, size: 64, light: true, along: 2 / 8, delay: 0.55),
        Leaf(x: 683, y: 420, angle: 5, size: 104, light: true, along: 3 / 8, delay: 0.7),
        Leaf(x: 700, y: 520, angle: 40, size: 100, light: false, along: 4 / 8, delay: 1.05),
        Leaf(x: 700, y: 520, angle: -202, size: 64, light: true, along: 4 / 8, delay: 1.25),
        Leaf(x: 665, y: 609, angle: 67, size: 96, light: true, along: 5 / 8, delay: 1.4),
        Leaf(x: 594, y: 676, angle: 90, size: 92, light: false, along: 6 / 8, delay: 1.75),
        Leaf(x: 594, y: 676, angle: -152, size: 64, light: true, along: 6 / 8, delay: 1.95),
        Leaf(x: 496, y: 716, angle: 110, size: 88, light: true, along: 7 / 8, delay: 2.1),
        Leaf(x: 330, y: 300, angle: -118, size: 96, light: true, along: nil, delay: 0.4),
    ]
    /// A leaf pointing right from (0, 0), 120 long; scale it by `size / 120`.
    public static let leafShape: [Curve] = [
        (CGPoint(x: 0, y: 0), CGPoint(x: 25, y: -30), CGPoint(x: 85, y: -30), CGPoint(x: 120, y: 0)),
        (CGPoint(x: 120, y: 0), CGPoint(x: 85, y: 30), CGPoint(x: 25, y: 30), CGPoint(x: 0, y: 0)),
    ]

    /// Fireflies inside the bowl: centre, radius and blink delay in seconds.
    public static let fireflies: [(x: Double, y: Double, radius: Double, delay: Double)] = [
        (520, 470, 26, 0), (586, 560, 20, 1.3), (478, 590, 16, 2.4),
    ]
    public static let glowCentre = CGPoint(x: 520, y: 500), glowRadius = 300.0

    // Colours, as gradient stops.
    public static let lightLeaf: [(Double, RGBA)] = [(0, RGBA(0xE4FF9C)), (0.45, RGBA(0x8FD45A)), (1, RGBA(0x3C9A4A))]
    public static let darkLeaf: [(Double, RGBA)] = [(0, RGBA(0xB5EE7A)), (0.5, RGBA(0x5DB653)), (1, RGBA(0x2A7442))]
    /// Top to bottom, from y 250 to 810.
    public static let stalkColours: [(Double, RGBA)] = [(0, RGBA(0xD8F79A)), (0.5, RGBA(0x7CC456)), (1, RGBA(0x3A7F3E))]
    /// Across the vine's bounds, top left to bottom right.
    public static let vineColours: [(Double, RGBA)] = [(0, RGBA(0xC9F27E)), (0.6, RGBA(0x5FB24E)), (1, RGBA(0x2F7A40))]
    public static let vineBounds = CGRect(x: 330, y: 279, width: 376, height: 446)
    public static let tendrilColour = RGBA(0x7CC456)
    public static let midrib = RGBA(0xE9FFD6, alpha: 0.55)
    public static let sunlight: [(Double, RGBA)] = [(0, RGBA(0xFFE9A8, alpha: 0.3)), (0.4, RGBA(0xFFD66B, alpha: 0.09)), (1, RGBA(0xFFD66B, alpha: 0))]
    public static let firefly: [(Double, RGBA)] = [(0, RGBA(0xFFF6C4)), (0.3, RGBA(0xFFE27A, alpha: 0.8)), (1, RGBA(0xFFD24A, alpha: 0))]
    /// The app icon's tile, top to bottom, its warm light and its rim.
    public static let forest = [RGBA(0x16382A), RGBA(0x0B2016), RGBA(0x040D08)]
    public static let tileLight = RGBA(0xFFE08A, alpha: 0.22)
    public static let rim = RGBA(0xCFF5A0, alpha: 0.12)
}

/// An sRGB colour; DanteKit and the companion turn it into SwiftUI and AppKit colours.
public struct RGBA: Sendable, Equatable {
    public let red, green, blue, alpha: Double

    public init(_ hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    public func opacity(_ alpha: Double) -> RGBA {
        RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    private init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// For web pages drawn in the app's theme.
    public var css: String {
        alpha >= 1 ? String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
            : "rgba(\(Int((red * 255).rounded())),\(Int((green * 255).rounded())),\(Int((blue * 255).rounded())),\(String(format: "%.3g", alpha)))"
    }
}
