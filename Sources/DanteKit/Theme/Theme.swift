import AppKit
import SwiftUI

/// The three app themes. Every screen uses the same tokens, so switching
/// theme changes colour and reading type, never layout.
public enum ThemeID: String, CaseIterable, Codable, Sendable {
    case dark, light, paper

    public var displayName: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .paper: "Paper"
        }
    }

    public var next: ThemeID {
        let all = ThemeID.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public var theme: Theme {
        switch self {
        case .dark: .dark
        case .light: .light
        case .paper: .paper
        }
    }
}

/// An sRGB colour that converts to both SwiftUI and AppKit.
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
    // Editor.
    public let codeBackground, lineNumber, lineNumberActive, currentLine: RGBA
    public let syntax: SyntaxPalette

    public var colorScheme: ColorScheme { isDark ? .dark : .light }
}

public extension Theme {
    static let dark = Theme(
        id: .dark, isDark: true,
        ground: RGBA(0x0B0D10), panel: RGBA(0x0F1216), card: RGBA(0x12161B), raised: RGBA(0x171C22),
        line: RGBA(0x1E242C), line2: RGBA(0x2A313B),
        text: RGBA(0xE8EBEF), text2: RGBA(0xA3ACB8), text3: RGBA(0x7D8794),
        accent: RGBA(0x8FA8FF), accentTint: RGBA(0x1A2238), accentLine: RGBA(0x2B3760), onAccent: RGBA(0x0B0D10),
        amber: RGBA(0xF2B061), green: RGBA(0x5AD69A), red: RGBA(0xFF7A7A), greenTint: RGBA(0x173326),
        done: RGBA(0x3D4A6B), track: RGBA(0x262C35),
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
        done: RGBA(0xA9B6E6), track: RGBA(0xE1E4EA),
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
        done: RGBA(0xAEB7D2), track: RGBA(0xE0D6C5),
        codeBackground: RGBA(0xF6F1E7), lineNumber: RGBA(0xADA392), lineNumberActive: RGBA(0x4D4539),
        currentLine: RGBA(0x2C4C9C, alpha: 0.06),
        syntax: SyntaxPalette(
            plain: RGBA(0x221D16), keyword: RGBA(0x6D3FB5), string: RGBA(0x2C7148), function: RGBA(0x2C4C9C),
            type: RGBA(0x1F6A78), comment: RGBA(0x7A705F), number: RGBA(0x8F530E)
        )
    )
}
