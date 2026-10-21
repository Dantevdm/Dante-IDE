import Foundation
import Yams

/// How a project looks and sounds, for its decks, videos and explainers: `.dante/brand.yaml`.
/// Without one, `detect` reads the project's own colours, fonts and logo (CSS variables,
/// Tailwind config, a logo file), so a first piece already looks like the product.
public struct BrandKit: Equatable, Sendable {
    public struct Colors: Equatable, Sendable {
        // Light by default: a project's own colours or brand.yaml can make it dark.
        public var background = "#f6f6f3"
        public var surface = "#ffffff"
        public var text = "#14161b"
        public var muted = "#5b6472"
        public var accent = "#3b5bdb"
        public var accent2 = "#0f9f8f"
        public var warning = "#b86e00"

        public init() {}

        var all: [(String, String)] {
            [("background", background), ("surface", surface), ("text", text), ("muted", muted),
             ("accent", accent), ("accent2", accent2), ("warning", warning)]
        }
    }

    public enum Pace: String, Sendable, CaseIterable {
        /// Long holds, slow eases: a keynote.
        case calm
        /// Quick cuts and springs: a launch.
        case lively
        /// Slow camera moves, depth, light: a film.
        case cinematic
    }

    public var name: String
    public var colors = Colors()
    /// Display (headlines), body and mono families. Geist ships with Dante.
    public var display = "Geist"
    public var body = "Geist"
    public var mono = "Geist Mono"
    /// Project-relative path to the logo (SVG or PNG).
    public var logo: String?
    public var pace: Pace = .cinematic
    /// The default easing, a CSS/GSAP name.
    public var ease = "expo.inOut"
    /// 3D: post-processing the scenes may use.
    public var bloom = true
    public var grain = true
    public var particles = true
    /// How narration and on-screen words should read.
    public var tone = "Clear, confident and plain. Short sentences. No hype."
    /// Kokoro voice for narration ("" for the one chosen in Settings).
    public var voice = ""
    /// Read from brand.yaml rather than guessed.
    public var isSaved = false

    public init(name: String) { self.name = name }

    public static let path = ".dante/brand.yaml"

    public static func parse(_ text: String, name: String) -> BrandKit {
        let meta = ((try? Yams.load(yaml: text)) as? [String: Any]) ?? [:]
        var kit = BrandKit(name: (meta["name"] as? String)?.nonEmptyTrimmed ?? name)
        kit.isSaved = true
        let colors = (meta["colors"] as? [String: Any]) ?? (meta["colours"] as? [String: Any]) ?? [:]
        func color(_ key: String...) -> String? {
            key.lazy.compactMap { (colors[$0] as? String).flatMap(Self.cssColor) }.first
        }
        kit.colors.background = color("background", "bg") ?? kit.colors.background
        kit.colors.surface = color("surface", "card", "panel") ?? kit.colors.surface
        kit.colors.text = color("text", "foreground", "fg") ?? kit.colors.text
        kit.colors.muted = color("muted", "secondary") ?? kit.colors.muted
        kit.colors.accent = color("accent", "primary", "brand") ?? kit.colors.accent
        kit.colors.accent2 = color("accent2", "secondary-accent", "highlight") ?? kit.colors.accent2
        kit.colors.warning = color("warning", "alert") ?? kit.colors.warning
        let fonts = (meta["fonts"] as? [String: Any]) ?? [:]
        kit.display = (fonts["display"] as? String)?.nonEmptyTrimmed ?? (fonts["heading"] as? String)?.nonEmptyTrimmed ?? kit.display
        kit.body = (fonts["body"] as? String)?.nonEmptyTrimmed ?? (fonts["text"] as? String)?.nonEmptyTrimmed ?? kit.body
        kit.mono = (fonts["mono"] as? String)?.nonEmptyTrimmed ?? (fonts["code"] as? String)?.nonEmptyTrimmed ?? kit.mono
        if let logo = (meta["logo"] as? String)?.nonEmptyTrimmed, !logo.contains("..") { kit.logo = logo }
        let motion = (meta["motion"] as? [String: Any]) ?? [:]
        if let pace = (motion["pace"] as? String).flatMap({ Pace(rawValue: $0.lowercased()) }) { kit.pace = pace }
        if let ease = (motion["ease"] as? String)?.nonEmptyTrimmed { kit.ease = ease }
        let three = (meta["3d"] as? [String: Any]) ?? (meta["three"] as? [String: Any]) ?? [:]
        if let bloom = three["bloom"] as? Bool { kit.bloom = bloom }
        if let grain = three["grain"] as? Bool { kit.grain = grain }
        if let particles = three["particles"] as? Bool { kit.particles = particles }
        let voice = (meta["voice"] as? [String: Any]) ?? [:]
        if let tone = (voice["tone"] as? String)?.nonEmptyTrimmed { kit.tone = tone }
        if let narrator = (voice["narrator"] as? String)?.nonEmptyTrimmed { kit.voice = narrator }
        return kit
    }

    /// The kit as YAML, for writing a guessed one out to edit.
    public var yaml: String {
        func q(_ text: String) -> String { MotionPiece.quoted(text) }
        return """
        # How \(name) looks and sounds in its decks, videos and explainers.
        name: \(q(name))
        colors:
        \(colors.all.map { "  \($0.0): \(q($0.1))" }.joined(separator: "\n"))
        fonts:
          display: \(q(display))
          body: \(q(body))
          mono: \(q(mono))
        \(logo.map { "logo: \(q($0))" } ?? "# logo: docs/brand/logo.svg")
        motion:
          pace: \(pace.rawValue)        # calm, lively or cinematic
          ease: \(q(ease))
        3d:
          bloom: \(bloom)
          grain: \(grain)
          particles: \(particles)
        voice:
          tone: \(q(tone))
          narrator: \(q(voice))     # a Kokoro voice, or empty for the one in Settings

        """
    }

    /// CSS custom properties for the scene: `--brand-accent` and friends.
    public var css: String {
        var lines = colors.all.map { "  --brand-\($0.0): \($0.1);" }
        lines.append("  --brand-display: \(Self.family(display));")
        lines.append("  --brand-body: \(Self.family(body));")
        lines.append("  --brand-mono: \(Self.family(mono));")
        return ":root {\n" + lines.joined(separator: "\n") + "\n}"
    }

    /// The kit as JSON for `dante.brand` in the scene.
    public var json: [String: Any] {
        var colorMap: [String: String] = [:]
        for (key, value) in colors.all { colorMap[key] = value }
        var object: [String: Any] = [
            "name": name, "colors": colorMap,
            "fonts": ["display": display, "body": body, "mono": mono],
            "motion": ["pace": pace.rawValue, "ease": ease],
            "three": ["bloom": bloom, "grain": grain, "particles": particles],
            "tone": tone,
        ]
        if let logo { object["logo"] = logo }
        return object
    }

    static func family(_ name: String) -> String {
        let fallback = name.lowercased().contains("mono") ? "ui-monospace, monospace" : "system-ui, sans-serif"
        return "\"\(name)\", \(fallback)"
    }

    /// A colour as `#rrggbb`, from hex (3, 6 or 8 digits) or `rgb(…)`; nil for anything else.
    static func cssColor(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") {
            let hex = text.dropFirst()
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            switch hex.count {
            case 3: return "#" + hex.map { "\($0)\($0)" }.joined()
            case 6: return "#" + hex
            case 8: return "#" + hex.prefix(6)
            default: return nil
            }
        }
        if let match = text.firstMatch(of: /rgba?\(\s*(\d{1,3})[\s,]+(\d{1,3})[\s,]+(\d{1,3})/),
           let r = Int(match.1), let g = Int(match.2), let b = Int(match.3), [r, g, b].allSatisfy({ $0 <= 255 }) {
            return String(format: "#%02x%02x%02x", r, g, b)
        }
        return nil
    }

    // MARK: Discovery

    /// The saved kit, or one guessed from the project: CSS custom properties (`--primary`,
    /// `--brand`, `--accent`, `--background`), Tailwind's `primary`/`brand` colour, the first
    /// web font a stylesheet names, and a file called logo.
    public static func load(name: String, files: [String], read: (String) -> String?) -> BrandKit {
        if files.contains(path), let text = read(path) { return parse(text, name: name) }
        return detect(name: name, files: files, read: read)
    }

    public static func detect(name: String, files: [String], read: (String) -> String?) -> BrandKit {
        var kit = BrandKit(name: name)
        let lowerFiles = files.map { ($0, $0.lowercased()) }
        let ignored = ["node_modules/", "vendor/", "dist/", "build/", ".min.", "test", "coverage/"]
        let styles = lowerFiles.filter { _, lower in
            (lower.hasSuffix(".css") || lower.hasSuffix(".scss") || lower.hasSuffix(".less")) && !ignored.contains { lower.contains($0) }
        }.map(\.0).prefix(40)
        var found: [String: String] = [:]
        var fontsSeen: [String] = []
        for file in styles {
            guard let text = read(file) else { continue }
            for match in text.matches(of: /--([\w-]+)\s*:\s*(#[0-9a-fA-F]{3,8}|rgba?\([^)]*\))/) {
                let key = String(match.1).lowercased()
                guard let color = cssColor(String(match.2)) else { continue }
                for (role, names) in roleNames where found[role] == nil && names.contains(key) { found[role] = color }
            }
            for match in text.matches(of: /font-family\s*:\s*["']?([A-Za-z][\w ]+?)["']?\s*[,;]/) {
                let family = String(match.1).trimmingCharacters(in: .whitespaces)
                if !genericFonts.contains(family.lowercased()), !fontsSeen.contains(family) { fontsSeen.append(family) }
            }
        }
        if let tailwind = lowerFiles.first(where: { $0.1.range(of: #"(^|/)tailwind\.config\.(js|ts|cjs|mjs)$"#, options: .regularExpression) != nil })?.0,
           let text = read(tailwind) {
            for (role, key) in [("accent", "primary"), ("accent", "brand"), ("accent2", "secondary")] where found[role] == nil {
                // primary: '#2563eb' or primary: { DEFAULT: '#2563eb', … }
                if let match = text.firstMatch(of: try! Regex("\\b\(key)\\s*:\\s*(?:\\{[^}]*?DEFAULT\\s*:\\s*)?['\"](#[0-9a-fA-F]{3,8})['\"]")),
                   let color = (match.output[1].substring).flatMap({ cssColor(String($0)) }) {
                    found[role] = color
                }
            }
            if let match = text.firstMatch(of: /sans\s*:\s*\[\s*['"]([^'"]+)['"]/) {
                let family = String(match.1)
                if !fontsSeen.contains(family) { fontsSeen.insert(family, at: 0) }
            }
        }
        kit.colors.background = found["background"] ?? kit.colors.background
        kit.colors.surface = found["surface"] ?? kit.colors.surface
        kit.colors.text = found["text"] ?? kit.colors.text
        kit.colors.accent = found["accent"] ?? kit.colors.accent
        kit.colors.accent2 = found["accent2"] ?? kit.colors.accent2
        // A dark product keeps its dark background; give it light text and surfaces when its
        // own weren't found.
        if let background = found["background"], luminance(background) < 0.5 {
            if found["text"] == nil { kit.colors.text = "#f4f5f7"; kit.colors.muted = "#9aa3b2" }
            if found["surface"] == nil { kit.colors.surface = "#151922" }
        }
        if let family = fontsSeen.first { kit.display = family; kit.body = family }
        kit.logo = lowerFiles.filter { _, lower in
            let name = (lower as NSString).lastPathComponent
            return name.hasPrefix("logo") && [".svg", ".png"].contains { name.hasSuffix($0) } && !ignored.contains { lower.contains($0) }
        }
        .map(\.0)
        .sorted { ($0.hasSuffix(".svg") ? 0 : 1, $0.count) < ($1.hasSuffix(".svg") ? 0 : 1, $1.count) }
        .first
        return kit
    }

    static let roleNames: [(String, Set<String>)] = [
        ("accent", ["primary", "brand", "accent", "color-primary", "brand-primary", "primary-color", "theme-primary"]),
        ("accent2", ["secondary", "accent-2", "color-secondary", "brand-secondary", "highlight"]),
        ("background", ["background", "bg", "color-background", "body-bg", "bg-color"]),
        ("surface", ["surface", "card", "panel", "color-surface"]),
        ("text", ["foreground", "text", "color-text", "text-color", "fg"]),
    ]

    static let genericFonts: Set<String> = ["inherit", "initial", "sans-serif", "serif", "monospace", "system-ui", "ui-sans-serif",
                                            "ui-monospace", "-apple-system", "blinkmacsystemfont", "var", "arial", "helvetica"]

    /// Relative luminance, 0 (black) to 1 (white), of `#rrggbb`.
    static func luminance(_ hex: String) -> Double {
        let digits = hex.dropFirst()
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return 0 }
        let channel = { (shift: Int) -> Double in
            let c = Double((value >> shift) & 0xff) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
