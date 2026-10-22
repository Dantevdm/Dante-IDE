import SwiftUI
import UIKit

/// The Mac's Light and Dark theme colours (DanteKit/Theme), for the companion. Light unless
/// the phone is in dark mode.
enum Palette {
    static let accent = dynamic(light: 0x3B5BDB, dark: 0x8FA8FF)
    static let accentTint = dynamic(light: 0xE8EDFF, dark: 0x1A2238)
    static let background = dynamic(light: 0xF5F6F8, dark: 0x0B0D10)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x12161B)
    static let line = dynamic(light: 0xE1E4EA, dark: 0x1E242C)
    static let text = dynamic(light: 0x12151A, dark: 0xE8EBEF)
    static let text2 = dynamic(light: 0x474F5B, dark: 0xA3ACB8)
    static let text3 = dynamic(light: 0x5F6875, dark: 0x7D8794)
    static let green = dynamic(light: 0x1D7F4E, dark: 0x5AD69A)
    static let amber = dynamic(light: 0x9A5A00, dark: 0xF2B061)
    static let red = dynamic(light: 0xC2362F, dark: 0xFF7A7A)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0B0D10)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}
