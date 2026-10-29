import AppKit
import SwiftUI

/// The app themes. Every screen uses the same tokens, so switching theme changes colour and
/// reading type, never layout. Vine, Tide, Dusk and Aurora also have a moving scene behind
/// the pages (`scene`); each look comes light and at night, as on the companion.
public enum ThemeID: String, CaseIterable, Codable, Sendable {
    case dark, light, paper
    case graphite, graphiteNight, vine, vineNight, tide, tideNight, dusk, duskNight, aurora, auroraNight

    public var displayName: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .paper: "Paper"
        case .graphite: "Graphite"
        case .graphiteNight: "Graphite Night"
        case .vine: "Vine"
        case .vineNight: "Vine Night"
        case .tide: "Tide"
        case .tideNight: "Tide Night"
        case .dusk: "Dusk"
        case .duskNight: "Dusk Night"
        case .aurora: "Aurora"
        case .auroraNight: "Aurora Night"
        }
    }

    /// What moves behind the pages.
    public enum Scene: String, Sendable { case none, vine, tide, dusk, aurora }

    public var scene: Scene {
        switch self {
        case .vine, .vineNight: .vine
        case .tide, .tideNight: .tide
        case .dusk, .duskNight: .dusk
        case .aurora, .auroraNight: .aurora
        default: .none
        }
    }

    public var tagline: String {
        switch self {
        case .dark, .light: "The classic colours"
        case .paper: "Warm paper"
        case .graphite, .graphiteNight: "Black, white and nothing else"
        case .vine, .vineNight: "Forest green, drifting light and fireflies"
        case .tide, .tideNight: "Deep water, slow waves and rising bubbles"
        case .dusk, .duskNight: "A low sun and warm embers"
        case .aurora, .auroraNight: "Ribbons of northern light"
        }
    }

    /// The same look's other half (light ↔ night), or nil for Paper.
    public var counterpart: ThemeID? {
        switch self {
        case .light: .dark
        case .dark: .light
        case .paper: nil
        case .graphite: .graphiteNight
        case .graphiteNight: .graphite
        case .vine: .vineNight
        case .vineNight: .vine
        case .tide: .tideNight
        case .tideNight: .tide
        case .dusk: .duskNight
        case .duskNight: .dusk
        case .aurora: .auroraNight
        case .auroraNight: .aurora
        }
    }

    /// The SF Symbol for the theme menus.
    public var symbol: String {
        switch self {
        case .dark: "moon"
        case .light: "sun.max"
        case .paper: "book"
        case .graphite, .graphiteNight: "circle.lefthalf.filled"
        case .vine, .vineNight: "leaf"
        case .tide, .tideNight: "water.waves"
        case .dusk, .duskNight: "sun.horizon"
        case .aurora, .auroraNight: "sparkles"
        }
    }

    /// One per look, light first: the gallery's tiles.
    public static let looks: [ThemeID] = [.light, .paper, .graphite, .vine, .tide, .dusk, .aurora]

    public var next: ThemeID {
        let all = ThemeID.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public var theme: Theme {
        switch self {
        case .dark: .dark
        case .light: .light
        case .paper: .paper
        case .graphite: .graphite
        case .graphiteNight: .graphiteNight
        case .vine: .vine
        case .vineNight: .vineNight
        case .tide: .tide
        case .tideNight: .tideNight
        case .dusk: .dusk
        case .duskNight: .duskNight
        case .aurora: .aurora
        case .auroraNight: .auroraNight
        }
    }
}

/// `RGBA` (DanteCore) as SwiftUI and AppKit colours.
extension RGBA {
    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

public struct SyntaxPalette: Sendable, Equatable {
    public let plain, keyword, string, function, type, comment, number: RGBA
}

public struct Theme: Sendable, Equatable {
    public let id: ThemeID
    public let isDark: Bool

    // Surfaces, back to front.
    public let ground, panel, card, raised: RGBA
    public let line, line2: RGBA
    // Text, strongest to weakest.
    public let text, text2, text3: RGBA
    // One accent per theme; amber, green and red are kept for status.
    public let accent, accentTint, accentLine, onAccent: RGBA
    public let amber, green, red, greenTint, done, track: RGBA
    /// Dims the window behind overlays such as the command palette.
    public let scrim: RGBA
    // Editor.
    public let codeBackground, lineNumber, lineNumberActive, currentLine: RGBA
    public let syntax: SyntaxPalette

    public var colorScheme: ColorScheme { isDark ? .dark : .light }

    /// Claude's own colour (Clay), the same in every theme, for the Claude mark.
    public var claude: RGBA { RGBA(0xD97757) }
}

public extension Theme {
    static let dark = Theme(
        id: .dark, isDark: true,
        ground: RGBA(0x0B0D10), panel: RGBA(0x0F1216), card: RGBA(0x12161B), raised: RGBA(0x171C22),
        line: RGBA(0x1E242C), line2: RGBA(0x2A313B),
        text: RGBA(0xE8EBEF), text2: RGBA(0xA3ACB8), text3: RGBA(0x7D8794),
        accent: RGBA(0x8FA8FF), accentTint: RGBA(0x1A2238), accentLine: RGBA(0x2B3760), onAccent: RGBA(0x0B0D10),
        amber: RGBA(0xF2B061), green: RGBA(0x5AD69A), red: RGBA(0xFF7A7A), greenTint: RGBA(0x173326),
        done: RGBA(0x3D4A6B), track: RGBA(0x262C35), scrim: RGBA(0x050608, alpha: 0.62),
        codeBackground: RGBA(0x0D1014), lineNumber: RGBA(0x4F5864), lineNumberActive: RGBA(0x9AA3AF),
        currentLine: RGBA(0x8FA8FF, alpha: 0.06),
        syntax: SyntaxPalette(
            plain: RGBA(0xE8EBEF), keyword: RGBA(0xC3A6FF), string: RGBA(0x9BD5A8), function: RGBA(0x8FA8FF),
            type: RGBA(0x7FD1E0), comment: RGBA(0x76808C), number: RGBA(0xF2B061)
        )
    )

    static let light = Theme(
        id: .light, isDark: false,
        ground: RGBA(0xF5F6F8), panel: RGBA(0xECEEF2), card: RGBA(0xFFFFFF), raised: RGBA(0xF4F5F8),
        line: RGBA(0xE1E4EA), line2: RGBA(0xCDD3DC),
        text: RGBA(0x12151A), text2: RGBA(0x474F5B), text3: RGBA(0x5F6875),
        accent: RGBA(0x3B5BDB), accentTint: RGBA(0xE8EDFF), accentLine: RGBA(0xC3CFFB), onAccent: RGBA(0xFFFFFF),
        amber: RGBA(0x9A5A00), green: RGBA(0x1D7F4E), red: RGBA(0xC2362F), greenTint: RGBA(0xDDF3E7),
        done: RGBA(0xA9B6E6), track: RGBA(0xE1E4EA), scrim: RGBA(0x141820, alpha: 0.25),
        codeBackground: RGBA(0xFBFBFD), lineNumber: RGBA(0xA3AAB4), lineNumberActive: RGBA(0x474F5B),
        currentLine: RGBA(0x3B5BDB, alpha: 0.06),
        syntax: SyntaxPalette(
            plain: RGBA(0x12151A), keyword: RGBA(0x7C3AED), string: RGBA(0x1D7F4E), function: RGBA(0x3B5BDB),
            type: RGBA(0x0E7490), comment: RGBA(0x6B7480), number: RGBA(0x9A5A00)
        )
    )

    static let paper = Theme(
        id: .paper, isDark: false,
        ground: RGBA(0xF3EEE4), panel: RGBA(0xEBE4D7), card: RGBA(0xFAF7F0), raised: RGBA(0xF0EADF),
        line: RGBA(0xE0D6C5), line2: RGBA(0xCFC3AE),
        text: RGBA(0x221D16), text2: RGBA(0x4D4539), text3: RGBA(0x6B6152),
        accent: RGBA(0x2C4C9C), accentTint: RGBA(0xE3E4EC), accentLine: RGBA(0xC2C8DD), onAccent: RGBA(0xFAF7F0),
        amber: RGBA(0x8F530E), green: RGBA(0x2C7148), red: RGBA(0xA8382B), greenTint: RGBA(0xDCEADD),
        done: RGBA(0xAEB7D2), track: RGBA(0xE0D6C5), scrim: RGBA(0x3C2D14, alpha: 0.2),
        codeBackground: RGBA(0xF6F1E7), lineNumber: RGBA(0xADA392), lineNumberActive: RGBA(0x4D4539),
        currentLine: RGBA(0x2C4C9C, alpha: 0.06),
        syntax: SyntaxPalette(
            plain: RGBA(0x221D16), keyword: RGBA(0x6D3FB5), string: RGBA(0x2C7148), function: RGBA(0x2C4C9C),
            type: RGBA(0x1F6A78), comment: RGBA(0x7A705F), number: RGBA(0x8F530E)
        )
    )

    static let graphite = Theme(
        id: .graphite, isDark: false,
        ground: RGBA(0xF4F4F5), panel: RGBA(0xEBEBED), card: RGBA(0xFFFFFF), raised: RGBA(0xF7F7F8),
        line: RGBA(0xE1E1E4), line2: RGBA(0xCCCCD1),
        text: RGBA(0x09090B), text2: RGBA(0x45454B), text3: RGBA(0x63636B),
        accent: RGBA(0x18181B), accentTint: RGBA(0xE7E7EA), accentLine: RGBA(0xC8C8CE), onAccent: RGBA(0xFFFFFF),
        amber: RGBA(0x92400E), green: RGBA(0x166534), red: RGBA(0xB91C1C), greenTint: RGBA(0xE2F0E6),
        done: RGBA(0xB4B4BB), track: RGBA(0xE1E1E4), scrim: RGBA(0x09090B, alpha: 0.25),
        codeBackground: RGBA(0xFFFFFF), lineNumber: RGBA(0xA1A1AA), lineNumberActive: RGBA(0x45454B),
        currentLine: RGBA(0x18181B, alpha: 0.05),
        syntax: SyntaxPalette(plain: RGBA(0x09090B), keyword: RGBA(0x52525B), string: RGBA(0x166534), function: RGBA(0x18181B), type: RGBA(0x3F3F46), comment: RGBA(0x8E8E96), number: RGBA(0x92400E))
    )

    static let graphiteNight = Theme(
        id: .graphiteNight, isDark: true,
        ground: RGBA(0x09090B), panel: RGBA(0x0E0E10), card: RGBA(0x161618), raised: RGBA(0x1C1C1F),
        line: RGBA(0x27272A), line2: RGBA(0x3A3A3F),
        text: RGBA(0xF4F4F5), text2: RGBA(0xB4B4BB), text3: RGBA(0x85858E),
        accent: RGBA(0xF4F4F5), accentTint: RGBA(0x232326), accentLine: RGBA(0x3F3F46), onAccent: RGBA(0x09090B),
        amber: RGBA(0xF2B061), green: RGBA(0x6EE7A0), red: RGBA(0xFF7A7A), greenTint: RGBA(0x15291D),
        done: RGBA(0x52525B), track: RGBA(0x27272A), scrim: RGBA(0x000000, alpha: 0.62),
        codeBackground: RGBA(0x0C0C0E), lineNumber: RGBA(0x52525B), lineNumberActive: RGBA(0xA1A1AA),
        currentLine: RGBA(0xF4F4F5, alpha: 0.05),
        syntax: SyntaxPalette(plain: RGBA(0xF4F4F5), keyword: RGBA(0xD4D4D8), string: RGBA(0x9BE3B5), function: RGBA(0xFFFFFF), type: RGBA(0xC4C4CC), comment: RGBA(0x71717A), number: RGBA(0xF2B061))
    )

    static let vine = Theme(
        id: .vine, isDark: false,
        ground: RGBA(0xEEF4E8), panel: RGBA(0xE5EDDD), card: RGBA(0xFFFFFF), raised: RGBA(0xF3F7EF),
        line: RGBA(0xD3E1C8), line2: RGBA(0xBFD0B2),
        text: RGBA(0x13200F), text2: RGBA(0x3E5236), text3: RGBA(0x566A4D),
        accent: RGBA(0x2F7D32), accentTint: RGBA(0xE0EFD6), accentLine: RGBA(0xB9D8A8), onAccent: RGBA(0xFFFFFF),
        amber: RGBA(0x9A5A00), green: RGBA(0x2E7D32), red: RGBA(0xB83A2E), greenTint: RGBA(0xDDF0D6),
        done: RGBA(0xA8C79B), track: RGBA(0xD3E1C8), scrim: RGBA(0x13200F, alpha: 0.25),
        codeBackground: RGBA(0xFAFCF7), lineNumber: RGBA(0xA2B097), lineNumberActive: RGBA(0x3E5236),
        currentLine: RGBA(0x2F7D32, alpha: 0.06),
        syntax: SyntaxPalette(plain: RGBA(0x13200F), keyword: RGBA(0x7A3E9D), string: RGBA(0x2E7D32), function: RGBA(0x2F6B8A), type: RGBA(0x0E7490), comment: RGBA(0x6E7D66), number: RGBA(0x9A5A00))
    )

    static let vineNight = Theme(
        id: .vineNight, isDark: true,
        ground: RGBA(0x0B1A10), panel: RGBA(0x0E2014), card: RGBA(0x12261A), raised: RGBA(0x173020),
        line: RGBA(0x21402A), line2: RGBA(0x2C5236),
        text: RGBA(0xE8F3DF), text2: RGBA(0xB2C9A6), text3: RGBA(0x86A07A),
        accent: RGBA(0x9BD46A), accentTint: RGBA(0x1A3320), accentLine: RGBA(0x2E5A33), onAccent: RGBA(0x0B1A10),
        amber: RGBA(0xF5C46B), green: RGBA(0x7BD88F), red: RGBA(0xFF8A7A), greenTint: RGBA(0x173326),
        done: RGBA(0x3D5A3F), track: RGBA(0x21402A), scrim: RGBA(0x030805, alpha: 0.62),
        codeBackground: RGBA(0x0D1D12), lineNumber: RGBA(0x4F6A52), lineNumberActive: RGBA(0xA8C49B),
        currentLine: RGBA(0x9BD46A, alpha: 0.06),
        syntax: SyntaxPalette(plain: RGBA(0xE8F3DF), keyword: RGBA(0xD7A6FF), string: RGBA(0x9BD46A), function: RGBA(0x7FC8E0), type: RGBA(0x6FD8C0), comment: RGBA(0x7A9478), number: RGBA(0xF5C46B))
    )

    static let tide = Theme(
        id: .tide, isDark: false,
        ground: RGBA(0xE8F3F7), panel: RGBA(0xDDEBF1), card: RGBA(0xFFFFFF), raised: RGBA(0xF1F8FB),
        line: RGBA(0xCDE2EA), line2: RGBA(0xB4D0DB),
        text: RGBA(0x0C2430), text2: RGBA(0x36515E), text3: RGBA(0x52707C),
        accent: RGBA(0x0E7490), accentTint: RGBA(0xD4EEF4), accentLine: RGBA(0xA8DBE7), onAccent: RGBA(0xFFFFFF),
        amber: RGBA(0x9A5A00), green: RGBA(0x1D7F4E), red: RGBA(0xC2362F), greenTint: RGBA(0xDDF3E7),
        done: RGBA(0x9CC7D4), track: RGBA(0xCDE2EA), scrim: RGBA(0x0C2430, alpha: 0.25),
        codeBackground: RGBA(0xFAFDFE), lineNumber: RGBA(0x9DB4BD), lineNumberActive: RGBA(0x36515E),
        currentLine: RGBA(0x0E7490, alpha: 0.06),
        syntax: SyntaxPalette(plain: RGBA(0x0C2430), keyword: RGBA(0x6D28D9), string: RGBA(0x1D7F4E), function: RGBA(0x0E7490), type: RGBA(0x0369A1), comment: RGBA(0x64808B), number: RGBA(0x9A5A00))
    )

    static let tideNight = Theme(
        id: .tideNight, isDark: true,
        ground: RGBA(0x06161E), panel: RGBA(0x081C26), card: RGBA(0x0C2530), raised: RGBA(0x112E3B),
        line: RGBA(0x173846), line2: RGBA(0x214756),
        text: RGBA(0xE2F2F7), text2: RGBA(0xA5C4CF), text3: RGBA(0x7A9AA6),
        accent: RGBA(0x5CD0E6), accentTint: RGBA(0x0F3440), accentLine: RGBA(0x1C5566), onAccent: RGBA(0x06161E),
        amber: RGBA(0xF2B061), green: RGBA(0x5AD69A), red: RGBA(0xFF7A7A), greenTint: RGBA(0x0F3326),
        done: RGBA(0x2E5A66), track: RGBA(0x173846), scrim: RGBA(0x020A0E, alpha: 0.62),
        codeBackground: RGBA(0x081A23), lineNumber: RGBA(0x46636E), lineNumberActive: RGBA(0x9DBFCB),
        currentLine: RGBA(0x5CD0E6, alpha: 0.06),
        syntax: SyntaxPalette(plain: RGBA(0xE2F2F7), keyword: RGBA(0xC3A6FF), string: RGBA(0x8FE3B0), function: RGBA(0x5CD0E6), type: RGBA(0x7FB8FF), comment: RGBA(0x6E8C97), number: RGBA(0xF2B061))
    )

    static let dusk = Theme(
        id: .dusk, isDark: false,
        ground: RGBA(0xFBF0E8), panel: RGBA(0xF5E4D8), card: RGBA(0xFFFFFF), raised: RGBA(0xFDF6F1),
        line: RGBA(0xF0D7C8), line2: RGBA(0xE4C0AC),
        text: RGBA(0x2B140C), text2: RGBA(0x5E3A2B), text3: RGBA(0x7A5545),
        accent: RGBA(0xC2410C), accentTint: RGBA(0xFCE3D6), accentLine: RGBA(0xF4BFA3), onAccent: RGBA(0xFFFFFF),
        amber: RGBA(0x9A5A00), green: RGBA(0x1D7F4E), red: RGBA(0xB42318), greenTint: RGBA(0xDDF3E7),
        done: RGBA(0xE3B49C), track: RGBA(0xF0D7C8), scrim: RGBA(0x2B140C, alpha: 0.25),
        codeBackground: RGBA(0xFFFBF8), lineNumber: RGBA(0xC2A091), lineNumberActive: RGBA(0x5E3A2B),
        currentLine: RGBA(0xC2410C, alpha: 0.06),
        syntax: SyntaxPalette(plain: RGBA(0x2B140C), keyword: RGBA(0x9D2B6B), string: RGBA(0x3F7A2A), function: RGBA(0xC2410C), type: RGBA(0x8A4B0F), comment: RGBA(0x8C6A5C), number: RGBA(0xB45309))
    )

    static let duskNight = Theme(
        id: .duskNight, isDark: true,
        ground: RGBA(0x170B10), panel: RGBA(0x1D0E15), card: RGBA(0x26141B), raised: RGBA(0x2F1922),
        line: RGBA(0x3C2029), line2: RGBA(0x4D2A35),
        text: RGBA(0xF8E7E0), text2: RGBA(0xD3B0A4), text3: RGBA(0xA5837A),
        accent: RGBA(0xFF8A5B), accentTint: RGBA(0x3A1A1F), accentLine: RGBA(0x5E2B2E), onAccent: RGBA(0x170B10),
        amber: RGBA(0xF5C46B), green: RGBA(0x7BD88F), red: RGBA(0xFF7A7A), greenTint: RGBA(0x1F2A1E),
        done: RGBA(0x6B3A3A), track: RGBA(0x3C2029), scrim: RGBA(0x080305, alpha: 0.62),
        codeBackground: RGBA(0x1A0C12), lineNumber: RGBA(0x6E4C52), lineNumberActive: RGBA(0xD3B0A4),
        currentLine: RGBA(0xFF8A5B, alpha: 0.06),
        syntax: SyntaxPalette(plain: RGBA(0xF8E7E0), keyword: RGBA(0xFF9EC7), string: RGBA(0xB5E08A), function: RGBA(0xFF8A5B), type: RGBA(0xFFC27A), comment: RGBA(0x9A7A72), number: RGBA(0xF5C46B))
    )

    static let aurora = Theme(
        id: .aurora, isDark: false,
        ground: RGBA(0xEEF0FA), panel: RGBA(0xE4E7F5), card: RGBA(0xFFFFFF), raised: RGBA(0xF5F6FC),
        line: RGBA(0xD8DBF0), line2: RGBA(0xC2C7E6),
        text: RGBA(0x14152B), text2: RGBA(0x41436A), text3: RGBA(0x5D6088),
        accent: RGBA(0x5B3DF5), accentTint: RGBA(0xE6E0FF), accentLine: RGBA(0xC7BCFB), onAccent: RGBA(0xFFFFFF),
        amber: RGBA(0x9A5A00), green: RGBA(0x1D7F4E), red: RGBA(0xC2362F), greenTint: RGBA(0xDDF3E7),
        done: RGBA(0xB3A8EE), track: RGBA(0xD8DBF0), scrim: RGBA(0x14152B, alpha: 0.25),
        codeBackground: RGBA(0xFBFBFE), lineNumber: RGBA(0xA3A6C4), lineNumberActive: RGBA(0x41436A),
        currentLine: RGBA(0x5B3DF5, alpha: 0.06),
        syntax: SyntaxPalette(plain: RGBA(0x14152B), keyword: RGBA(0x5B3DF5), string: RGBA(0x0F8A5F), function: RGBA(0x2563EB), type: RGBA(0x0E7490), comment: RGBA(0x6B6E92), number: RGBA(0xA35A00))
    )

    static let auroraNight = Theme(
        id: .auroraNight, isDark: true,
        ground: RGBA(0x060918), panel: RGBA(0x090D1F), card: RGBA(0x10142B), raised: RGBA(0x151A36),
        line: RGBA(0x1E2444), line2: RGBA(0x2A3157),
        text: RGBA(0xE7E9FF), text2: RGBA(0xAEB3DA), text3: RGBA(0x8187B3),
        accent: RGBA(0xA08FFF), accentTint: RGBA(0x1E1A44), accentLine: RGBA(0x3A3275), onAccent: RGBA(0x060918),
        amber: RGBA(0xF2B061), green: RGBA(0x5AE6A8), red: RGBA(0xFF7A9A), greenTint: RGBA(0x10302A),
        done: RGBA(0x3D3A6B), track: RGBA(0x1E2444), scrim: RGBA(0x02030A, alpha: 0.62),
        codeBackground: RGBA(0x080B1C), lineNumber: RGBA(0x4A5080), lineNumberActive: RGBA(0xA6ACD8),
        currentLine: RGBA(0xA08FFF, alpha: 0.06),
        syntax: SyntaxPalette(plain: RGBA(0xE7E9FF), keyword: RGBA(0xC3A6FF), string: RGBA(0x7EF0C0), function: RGBA(0x8FB8FF), type: RGBA(0x7FE0F0), comment: RGBA(0x7479A6), number: RGBA(0xF2B061))
    )
}
