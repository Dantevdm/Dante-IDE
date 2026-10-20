import Foundation

/// The mark's colours: gold on lapis, the same in every theme, since a logo doesn't follow the
/// theme. scripts/make_icon.swift draws the app icon with the same values.
public enum LogoColors {
    /// The ring and the obelisk's lit face, top to bottom.
    public static let gold: [(Double, RGBA)] = [(0, RGBA(0xFFF0C2)), (0.32, RGBA(0xF5C96A)), (0.68, RGBA(0xD39A3C)), (1, RGBA(0x9A6220))]
    /// The obelisk's shaded face.
    public static let shade: [(Double, RGBA)] = [(0, RGBA(0xE2AA4E)), (0.5, RGBA(0xB27A2C)), (1, RGBA(0x6E4514))]
    public static let tipLit = RGBA(0xFFF4D6)
    public static let tipShade = RGBA(0xF2C46B)
    public static let decan = RGBA(0xF5C96A, alpha: 0.5)
    public static let carving = RGBA(0x7A4A15, alpha: 0.45)
    public static let glow = RGBA(0xFFD27A)
    public static let glowEdge = RGBA(0xE9A23B)
    public static let glint = RGBA(0xFFF7DE)
    public static let star = RGBA(0xE9FBFF)
    /// The app icon's tile, top to bottom.
    public static let lapis = [RGBA(0x15295F), RGBA(0x0B1738), RGBA(0x050A1A)]
}
