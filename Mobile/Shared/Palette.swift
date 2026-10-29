import SwiftUI
import UIKit

/// The companion's colours, from the chosen look (`Looks.shared`). Classic is the Mac's Light
/// and Dark theme (DanteKit/Theme); the others restyle the whole app. Views read these inside
/// their bodies, so a new look redraws everything, and inside `withAnimation` it fades across.
/// The widget has no settings of its own and stays Classic.
@MainActor
enum Palette {
    static let controlRadius: CGFloat = 12
    static var accent: Color { colors.accent }
    static var accentTint: Color { colors.accentTint }
    static var background: Color { colors.background }
    static var card: Color { colors.card }
    static var line: Color { colors.line }
    static var text: Color { colors.text }
    static var text2: Color { colors.text2 }
    static var text3: Color { colors.text3 }
    static var green: Color { colors.green }
    static var amber: Color { colors.amber }
    static var red: Color { colors.red }
    static var onAccent: Color { colors.onAccent }

    static var colors: LookColors { Looks.shared.look.colors }
}

/// A style for the whole app. Plain ones are flat colour; the others have a living backdrop.
enum Look: String, CaseIterable, Identifiable, Sendable {
    case classic, vine, tide, dusk, aurora, paper, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .vine: "Vine"
        case .tide: "Tide"
        case .dusk: "Dusk"
        case .aurora: "Aurora"
        case .paper: "Paper"
        case .graphite: "Graphite"
        }
    }

    var tagline: String {
        switch self {
        case .classic: "The Mac’s own colours"
        case .vine: "Forest green, drifting light and fireflies"
        case .tide: "Deep water, slow waves and rising bubbles"
        case .dusk: "A low sun and warm embers"
        case .aurora: "Ribbons of northern light"
        case .paper: "Warm paper and a serif"
        case .graphite: "Black, white and nothing else"
        }
    }

    /// Flat colour, nothing moving.
    var isPlain: Bool { [.classic, .paper, .graphite].contains(self) }

    var font: Font.Design {
        switch self {
        case .vine, .aurora: .rounded
        case .paper: .serif
        default: .default
        }
    }

    @MainActor var colors: LookColors { LookColors.of(self) }
}

/// One look's colours, each with a light and a dark value.
struct LookColors {
    let accent, accentTint, background, card, line, text, text2, text3, green, amber, red, onAccent: Color

    @MainActor private static var cache: [Look: LookColors] = [:]

    @MainActor static func of(_ look: Look) -> LookColors {
        if let made = cache[look] { return made }
        let made = make(look)
        cache[look] = made
        return made
    }

    /// Light and dark hex values; a card's alpha lets a moving backdrop show through.
    private static func make(_ look: Look) -> LookColors {
        typealias S = (UInt32, UInt32)
        func build(accent: S, tint: S, background: S, card: S, cardAlpha: (Double, Double) = (1, 1), line: S, text: S, text2: S, text3: S,
                   green: S = (0x1D7F4E, 0x5AD69A), amber: S = (0x9A5A00, 0xF2B061), red: S = (0xC2362F, 0xFF7A7A), onAccent: S) -> LookColors {
            LookColors(accent: dynamic(accent), accentTint: dynamic(tint), background: dynamic(background),
                       card: dynamic(card, alpha: cardAlpha), line: dynamic(line), text: dynamic(text), text2: dynamic(text2),
                       text3: dynamic(text3), green: dynamic(green), amber: dynamic(amber), red: dynamic(red), onAccent: dynamic(onAccent))
        }
        switch look {
        case .classic:
            return build(accent: (0x3B5BDB, 0x8FA8FF), tint: (0xE8EDFF, 0x1A2238), background: (0xF5F6F8, 0x0B0D10), card: (0xFFFFFF, 0x12161B),
                         line: (0xE1E4EA, 0x1E242C), text: (0x12151A, 0xE8EBEF), text2: (0x474F5B, 0xA3ACB8), text3: (0x5F6875, 0x7D8794),
                         onAccent: (0xFFFFFF, 0x0B0D10))
        case .vine:
            return build(accent: (0x2F7D32, 0x9BD46A), tint: (0xE0EFD6, 0x1A3320), background: (0xEEF4E8, 0x0B1A10), card: (0xFFFFFF, 0x12261A),
                         cardAlpha: (0.84, 0.8), line: (0xD3E1C8, 0x21402A), text: (0x13200F, 0xE8F3DF), text2: (0x3E5236, 0xB2C9A6),
                         text3: (0x566A4D, 0x86A07A), green: (0x2E7D32, 0x7BD88F), amber: (0x9A5A00, 0xF5C46B), red: (0xB83A2E, 0xFF8A7A),
                         onAccent: (0xFFFFFF, 0x0B1A10))
        case .tide:
            return build(accent: (0x0E7490, 0x5CD0E6), tint: (0xD4EEF4, 0x0F3440), background: (0xE8F3F7, 0x06161E), card: (0xFFFFFF, 0x0C2530),
                         cardAlpha: (0.84, 0.8), line: (0xCDE2EA, 0x173846), text: (0x0C2430, 0xE2F2F7), text2: (0x36515E, 0xA5C4CF),
                         text3: (0x52707C, 0x7A9AA6), onAccent: (0xFFFFFF, 0x06161E))
        case .dusk:
            return build(accent: (0xC2410C, 0xFF8A5B), tint: (0xFCE3D6, 0x3A1A1F), background: (0xFBF0E8, 0x170B10), card: (0xFFFFFF, 0x26141B),
                         cardAlpha: (0.84, 0.8), line: (0xF0D7C8, 0x3C2029), text: (0x2B140C, 0xF8E7E0), text2: (0x5E3A2B, 0xD3B0A4),
                         text3: (0x7A5545, 0xA5837A), onAccent: (0xFFFFFF, 0x170B10))
        case .aurora:
            return build(accent: (0x5B3DF5, 0xA08FFF), tint: (0xE6E0FF, 0x1E1A44), background: (0xEEF0FA, 0x060918), card: (0xFFFFFF, 0x10142B),
                         cardAlpha: (0.82, 0.76), line: (0xD8DBF0, 0x1E2444), text: (0x14152B, 0xE7E9FF), text2: (0x41436A, 0xAEB3DA),
                         text3: (0x5D6088, 0x8187B3), onAccent: (0xFFFFFF, 0x060918))
        case .paper:
            return build(accent: (0x9C4A1A, 0xE39A6B), tint: (0xF3E3D3, 0x3A2A1F), background: (0xF4EFE6, 0x1C1916), card: (0xFBF8F2, 0x24201C),
                         line: (0xE2D9C8, 0x342E28), text: (0x2A2420, 0xEDE6DA), text2: (0x5A4E44, 0xC0B5A6), text3: (0x75685B, 0x948876),
                         onAccent: (0xFFFFFF, 0x1C1916))
        case .graphite:
            return build(accent: (0x18181B, 0xF4F4F5), tint: (0xE7E7EA, 0x232326), background: (0xF4F4F5, 0x09090B), card: (0xFFFFFF, 0x161618),
                         line: (0xE1E1E4, 0x27272A), text: (0x09090B, 0xF4F4F5), text2: (0x45454B, 0xB4B4BB), text3: (0x63636B, 0x85858E),
                         onAccent: (0xFFFFFF, 0x09090B))
        }
    }

    private static func dynamic(_ values: (UInt32, UInt32), alpha: (Double, Double) = (1, 1)) -> Color {
        Color(UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            let value = dark ? values.1 : values.0
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: dark ? alpha.1 : alpha.0)
        })
    }
}

/// The chosen look and light or dark, kept on the device.
@MainActor @Observable
final class Looks {
    static let shared = Looks()

    enum Appearance: String, CaseIterable, Identifiable {
        case automatic, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var scheme: ColorScheme? {
            switch self {
            case .automatic: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    private(set) var look: Look
    var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    /// Bumped on each change, for the wash that sweeps the new look in.
    private(set) var changes = 0

    private init() {
        look = UserDefaults.standard.string(forKey: "look").flatMap(Look.init) ?? .classic
        appearance = UserDefaults.standard.string(forKey: "appearance").flatMap(Appearance.init) ?? .automatic
    }

    func choose(_ new: Look) {
        guard new != look else { return }
        UserDefaults.standard.set(new.rawValue, forKey: "look")
        changes += 1
        withAnimation(.easeInOut(duration: 0.9)) { look = new }
    }
}
