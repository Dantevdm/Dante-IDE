import Foundation

/// A colour in a theme: `#rrggbb`, `#rgb` or an HSL triplet `H S% L%`, kept as the text it was
/// written as and the red, green and blue it means (0–1).
public struct ThemeColor: Equatable, Hashable, Sendable {
    public var text: String
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        text = ""
        text = hex
    }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            var digits = String(trimmed.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            red = Double((value >> 16) & 0xff) / 255
            green = Double((value >> 8) & 0xff) / 255
            blue = Double(value & 0xff) / 255
        } else {
            // "214 80% 32%", as grc-ui writes HSL.
            let parts = trimmed.replacingOccurrences(of: ",", with: " ").split(separator: " ").map { $0.replacingOccurrences(of: "%", with: "") }
            guard parts.count == 3, let h = Double(parts[0]), let s = Double(parts[1]), let l = Double(parts[2]),
                  (0...360).contains(h), (0...100).contains(s), (0...100).contains(l) else { return nil }
            (red, green, blue) = Self.rgb(hue: h / 360, saturation: s / 100, lightness: l / 100)
        }
        self.text = trimmed
    }

    public var hex: String {
        String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// Relative luminance (WCAG), for contrast.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The WCAG contrast ratio between two colours, 1 to 21.
    public func contrast(with other: ThemeColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func rgb(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        guard saturation > 0 else { return (lightness, lightness, lightness) }
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3))
    }
}

/// A frontend theme in the `theme.json` format (grc-ui's): one folder per look, holding the
/// file and the logos, fonts and pictures it names. Every field but `name` is optional, and a
/// theme falls back to its set's default theme field by field, except the ones that belong to
/// a customer alone (`ownFields`). Read leniently: unknown fields are kept and written back.
public struct UITheme: Identifiable, Equatable, Sendable {
    public struct FontFile: Equatable, Sendable {
        public var src: String
        public var weight: String?
        public var style: String?

        public init(src: String, weight: String? = nil, style: String? = nil) {
            self.src = src
            self.weight = weight
            self.style = style
        }
    }

    /// The folder it was read from.
    public var folder: URL?
    public var name: String
    public var customerName: String?
    public var productName: String?
    public var copyrightHolder: String?
    public var tagline: String?
    /// primary, secondary, accent, primaryForeground, sidebar, loginCta.
    public var colors: [String: ThemeColor]
    /// `status.<tone>.<part>`: success, warning, info, neutral or danger; fg, bg or border.
    public var status: [String: [String: ThemeColor]]
    public var fontFamily: String?
    public var fontFiles: [FontFile]
    /// Corner radius in points, 0–32.
    public var radius: Double?
    /// logo, logoReversed, mark, markReversed, favicon, loginArtwork: file names in the folder.
    public var assets: [String: String]
    public var loginLogoHeight: Double?
    public var loginArtworkFocus: Double?
    /// Fields this reader doesn't know, written back as they were.
    public var extra: [String: JSONValue]
    /// Fields that were there but couldn't be read.
    public var invalid: [String]

    public var id: String { folder?.path ?? name }

    public static let colorKeys = ["primary", "secondary", "accent", "primaryForeground", "sidebar", "loginCta"]
    public static let assetKeys = ["logo", "logoReversed", "mark", "markReversed", "favicon", "loginArtwork"]
    public static let statusTones = ["success", "warning", "info", "neutral", "danger"]
    /// Never borrowed from the default theme: a customer's theme without a logo shows its
    /// initials, never someone else's logo, and no copyright line rather than another's.
    public static let ownFields: Set<String> = ["customerName", "copyrightHolder", "tagline", "assets"]

    public init(name: String, folder: URL? = nil, customerName: String? = nil, productName: String? = nil, copyrightHolder: String? = nil,
                tagline: String? = nil, colors: [String: ThemeColor] = [:], status: [String: [String: ThemeColor]] = [:],
                fontFamily: String? = nil, fontFiles: [FontFile] = [], radius: Double? = nil, assets: [String: String] = [:],
                loginLogoHeight: Double? = nil, loginArtworkFocus: Double? = nil, extra: [String: JSONValue] = [:], invalid: [String] = []) {
        self.name = name
        self.folder = folder
        self.customerName = customerName
        self.productName = productName
        self.copyrightHolder = copyrightHolder
        self.tagline = tagline
        self.colors = colors
        self.status = status
        self.fontFamily = fontFamily
        self.fontFiles = fontFiles
        self.radius = radius
        self.assets = assets
        self.loginLogoHeight = loginLogoHeight
        self.loginArtworkFocus = loginArtworkFocus
        self.extra = extra
        self.invalid = invalid
    }

    // MARK: Reading

    public static func read(folder: URL) -> UITheme? {
        guard let data = try? Data(contentsOf: folder.appending(path: "theme.json")) else { return nil }
        return parse(data, folder: folder)
    }

    /// Nil unless it's a JSON object with a name or colours: a theme, not some other theme.json.
    public static func parse(_ data: Data, folder: URL? = nil) -> UITheme? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let object = value.object,
              object["name"] != nil || object["colors"] != nil else { return nil }
        var theme = UITheme(name: object["name"]?.string ?? folder?.lastPathComponent ?? "", folder: folder)
        var invalid: [String] = []
        func string(_ key: String) -> String? {
            guard let value = object[key] else { return nil }
            guard let text = value.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { invalid.append(key); return nil }
            return text
        }
        theme.customerName = string("customerName")
        theme.productName = string("productName")
        theme.copyrightHolder = string("copyrightHolder")
        theme.tagline = string("tagline")
        if let colors = object["colors"]?.object {
            for (key, value) in colors where key != "status" {
                if let text = value.string, let color = ThemeColor(text) { theme.colors[key] = color } else { invalid.append("colors.\(key)") }
            }
            for (tone, parts) in colors["status"]?.object ?? [:] {
                for (part, value) in parts.object ?? [:] {
                    if let text = value.string, let color = ThemeColor(text) { theme.status[tone, default: [:]][part] = color }
                    else { invalid.append("colors.status.\(tone).\(part)") }
                }
            }
        }
        if let font = object["font"]?.object {
            if let family = font["family"]?.string, Self.isFontList(family) { theme.fontFamily = family } else if font["family"] != nil { invalid.append("font.family") }
            for file in font["files"]?.array ?? [] {
                guard let src = file["src"]?.string, Self.isInside(src) else { invalid.append("font.files"); continue }
                theme.fontFiles.append(FontFile(src: src, weight: file["weight"]?.string ?? file["weight"]?.int.map(String.init), style: file["style"]?.string))
            }
        }
        if let radius = object["radius"] {
            let number = radius.double ?? radius.int.map(Double.init) ?? radius.string.flatMap { Double($0.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)) }
            if let number, (0...32).contains(number) { theme.radius = number } else { invalid.append("radius") }
        }
        for (key, value) in object["assets"]?.object ?? [:] {
            if let file = value.string, Self.isInside(file) { theme.assets[key] = file } else { invalid.append("assets.\(key)") }
        }
        if let height = object["loginLogoHeight"] {
            if let number = height.double ?? height.int.map(Double.init), (24...120).contains(number) { theme.loginLogoHeight = number } else { invalid.append("loginLogoHeight") }
        }
        if let focus = object["loginArtworkFocus"] {
            if let number = focus.double ?? focus.int.map(Double.init), (0...100).contains(number) { theme.loginArtworkFocus = number } else { invalid.append("loginArtworkFocus") }
        }
        let known: Set<String> = ["name", "customerName", "productName", "copyrightHolder", "tagline", "colors", "font", "radius", "assets", "loginLogoHeight", "loginArtworkFocus"]
        theme.extra = object.filter { !known.contains($0.key) }
        theme.invalid = invalid.sorted()
        return theme
    }

    /// A file name inside the theme's folder: no `..`, no leading `/`, no URL.
    public static func isInside(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("..") && !path.contains("://") && !path.hasPrefix("data:")
    }

    /// A plain CSS font-family list: names, quotes, commas and spaces only.
    public static func isFontList(_ family: String) -> Bool {
        !family.isEmpty && family.allSatisfy { $0.isLetter || $0.isNumber || " ,'\"-_".contains($0) }
    }

    // MARK: Using

    /// This theme with every field it leaves out taken from `base`, except `ownFields`.
    public func over(_ base: UITheme?) -> UITheme {
        guard let base, base.name != name || base.folder != folder else { return self }
        var theme = self
        theme.productName = productName ?? base.productName
        for (key, color) in base.colors where colors[key] == nil { theme.colors[key] = color }
        for (tone, parts) in base.status {
            for (part, color) in parts where status[tone]?[part] == nil { theme.status[tone, default: [:]][part] = color }
        }
        if fontFamily == nil {
            theme.fontFamily = base.fontFamily
            theme.fontFiles = base.fontFiles
        }
        theme.radius = radius ?? base.radius
        theme.loginLogoHeight = loginLogoHeight ?? base.loginLogoHeight
        theme.loginArtworkFocus = loginArtworkFocus ?? base.loginArtworkFocus
        return theme
    }

    public func color(_ key: String) -> ThemeColor? {
        switch key {
        case "sidebar", "loginCta": colors[key] ?? colors["primary"]
        case "primaryForeground": colors[key] ?? ThemeColor("#ffffff")
        default: colors[key]
        }
    }

    /// The first family in the font list, unquoted: "Work Sans".
    public var fontName: String? {
        fontFamily?.split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
    }

    /// Up to two letters for a theme without a mark: "AI" for Acme Insurance.
    public var initials: String {
        let words = (customerName ?? name).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(words.first?.prefix(2) ?? "")
        return String(letters).uppercased()
    }

    public func url(of asset: String) -> URL? {
        guard let file = assets[asset], let folder else { return nil }
        return folder.appending(path: file)
    }

    // MARK: Checking

    /// What's wrong with it, as `npm run check:theme` would say, given its folder's files.
    public func problems(folderName: String? = nil, exists: (String) -> Bool) -> [String] {
        var problems: [String] = []
        if name.isEmpty { problems.append("It has no name.") }
        else if !Self.isValidName(name) { problems.append("Its name “\(name)” must be lower case letters, digits and hyphens.") }
        if let folderName, !name.isEmpty, folderName != name { problems.append("Its name “\(name)” differs from its folder “\(folderName)”.") }
        problems += invalid.map { "\($0) couldn’t be read." }
        for (key, file) in assets.sorted(by: { $0.key < $1.key }) where !exists(file) { problems.append("assets.\(key) names \(file), which isn’t there.") }
        for file in fontFiles where !exists(file.src) { problems.append("font.files names \(file.src), which isn’t there.") }
        if !fontFiles.isEmpty, !fontFiles.contains(where: { exists(($0.src as NSString).deletingLastPathComponent + "/OFL.txt") || exists(($0.src as NSString).deletingLastPathComponent + "/LICENSE.txt") }) {
            problems.append("Its font files have no licence beside them (OFL.txt).")
        }
        if let primary = color("primary"), let text = color("primaryForeground"), primary.contrast(with: text) < 4.5 {
            problems.append(String(format: "Text on the primary colour has a contrast of %.1f:1; 4.5:1 is the least for reading.", primary.contrast(with: text)))
        }
        return problems
    }

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { ($0.isLetter && $0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" } && !name.hasPrefix("-")
    }

    // MARK: Writing

    /// The theme as `theme.json`, in the format's usual order, with what it left out still out.
    public var json: String {
        var lines: [(String, JSONValue)] = [("name", .string(name))]
        if let customerName { lines.append(("customerName", .string(customerName))) }
        if let productName { lines.append(("productName", .string(productName))) }
        if let copyrightHolder { lines.append(("copyrightHolder", .string(copyrightHolder))) }
        if let tagline { lines.append(("tagline", .string(tagline))) }
        var colorFields: [(String, JSONValue)] = (Self.colorKeys + colors.keys.filter { !Self.colorKeys.contains($0) }.sorted())
            .compactMap { key in colors[key].map { (key, .string($0.text)) } }
        if !status.isEmpty {
            colorFields.append(("status", .object(status.mapValues { .object($0.mapValues { .string($0.text) }) })))
        }
        if !colorFields.isEmpty { lines.append(("colors", Self.ordered(colorFields))) }
        if fontFamily != nil || !fontFiles.isEmpty {
            var font: [(String, JSONValue)] = []
            if let fontFamily { font.append(("family", .string(fontFamily))) }
            if !fontFiles.isEmpty {
                font.append(("files", .array(fontFiles.map { file in
                    var fields: [(String, JSONValue)] = [("src", .string(file.src))]
                    if let weight = file.weight { fields.append(("weight", .string(weight))) }
                    if let style = file.style { fields.append(("style", .string(style))) }
                    return Self.ordered(fields)
                })))
            }
            lines.append(("font", Self.ordered(font)))
        }
        if let radius { lines.append(("radius", .string("\(Int(radius))px"))) }
        if !assets.isEmpty {
            lines.append(("assets", Self.ordered((Self.assetKeys + assets.keys.filter { !Self.assetKeys.contains($0) }.sorted())
                .compactMap { key in assets[key].map { (key, .string($0)) } })))
        }
        if let loginLogoHeight { lines.append(("loginLogoHeight", .number(loginLogoHeight.rounded()))) }
        if let loginArtworkFocus { lines.append(("loginArtworkFocus", .number(loginArtworkFocus.rounded()))) }
        lines += extra.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return Self.write(Self.ordered(lines), indent: "") + "\n"
    }

    /// An object whose keys keep their order when written.
    private static func ordered(_ fields: [(String, JSONValue)]) -> JSONValue {
        .array([.string("\u{0}ordered")] + fields.map { .array([.string($0.0), $0.1]) })
    }

    private static func write(_ value: JSONValue, indent: String) -> String {
        let inner = indent + "  "
        if case .array(let items) = value, items.first == .string("\u{0}ordered") {
            let fields = items.dropFirst().compactMap { item -> String? in
                guard case .array(let pair) = item, pair.count == 2, let key = pair[0].string else { return nil }
                return inner + quote(key) + ": " + write(pair[1], indent: inner)
            }
            return fields.isEmpty ? "{}" : "{\n" + fields.joined(separator: ",\n") + "\n" + indent + "}"
        }
        switch value {
        case .object(let object):
            let fields = object.sorted { $0.key < $1.key }.map { inner + quote($0.key) + ": " + write($0.value, indent: inner) }
            return fields.isEmpty ? "{}" : "{\n" + fields.joined(separator: ",\n") + "\n" + indent + "}"
        case .array(let items):
            return items.isEmpty ? "[]" : "[\n" + items.map { inner + write($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        default:
            let data = (try? encoder.encode(value)) ?? Data("null".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Paths stay readable: "fonts/x.woff2", not "fonts\/x.woff2".
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }()

    private static func quote(_ text: String) -> String {
        String(decoding: (try? encoder.encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}
