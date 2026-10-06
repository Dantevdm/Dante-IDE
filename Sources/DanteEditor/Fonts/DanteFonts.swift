import AppKit
import CoreText
import DanteKit
import SwiftUI

/// Geist and Geist Mono, bundled with the editor module and registered for the process at
/// launch. Falls back to the system fonts when `Preferences.usesGeist` is off or a font
/// didn't load.
@MainActor
public enum DanteFonts {
    public nonisolated static let sansFamily = "Geist"
    public nonisolated static let monoFamily = "Geist Mono"

    private static var registered = false

    /// Registers the bundled fonts for this process. Safe to call more than once.
    public static func register() {
        guard !registered else { return }
        registered = true
        guard let folder = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    /// Whether the app should draw with Geist: chosen in Settings and actually loaded.
    public static var usesGeist: Bool {
        Preferences.shared.usesGeist && isAvailable
    }

    static var isAvailable: Bool {
        register()
        return NSFont(name: monoFamily, size: 12) != nil && NSFont(name: sansFamily, size: 12) != nil
    }

    /// The code font: Geist Mono, else SF Mono.
    public static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard usesGeist else { return .monospacedSystemFont(ofSize: size, weight: weight) }
        return font(family: monoFamily, size: size, weight: weight) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// The interface font: Geist, else the system font.
    public static func sans(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard usesGeist else { return .systemFont(ofSize: size, weight: weight) }
        return font(family: sansFamily, size: size, weight: weight) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// A weight of a variable family, through the weight trait (which CoreText maps to the wght axis).
    private static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size)
    }
}

extension Font {
    /// `Font.system(size:weight:design:)` in Geist or Geist Mono when they're in use. Rounded
    /// and serif designs stay with the system font.
    /// Usable from drawing code that isn't main-actor isolated; views draw on the main thread,
    /// where reading the preference also lets SwiftUI redraw when it changes.
    public nonisolated static func dante(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let geist = Thread.isMainThread ? MainActor.assumeIsolated { DanteFonts.usesGeist } : false
        guard geist, design == .default || design == .monospaced else {
            return .system(size: size, weight: weight, design: design)
        }
        let family = design == .monospaced ? DanteFonts.monoFamily : DanteFonts.sansFamily
        return .custom(family, fixedSize: size).weight(weight)
    }
}
