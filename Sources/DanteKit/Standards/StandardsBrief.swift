import Foundation

/// What the agents are told about a project's standards and themes: a few lines in their brief,
/// and the full story from the `ui_standards` tool.
public enum StandardsBrief {
    /// For the system prompt; nil when there are no standards.
    public static func brief(_ standards: Standards) -> String? {
        guard !standards.isEmpty else { return nil }
        var lines = ["The team builds to house standards. Follow them in anything you build, and say when a request would break one."]
        let projectDocs = standards.docs.compactMap(\.path)
        if !projectDocs.isEmpty { lines.append("Standards in this project: \(projectDocs.prefix(12).joined(separator: ", ")).") }
        if standards.docs.contains(where: { $0.path == nil }) { lines.append("The company library has more; ui_standards lists and reads them.") }
        for set in standards.themeSets {
            let names = set.themes.map(\.name).joined(separator: ", ")
            switch set.place {
            case .project(let path):
                var line = "Frontend themes in \(path)/ (\(names); \(set.defaultName.map { "\($0) is the default" } ?? "no default")) use the theme.json format."
                if let variable = set.swap?.buildVariable { line += " A build picks one with \(variable)." }
                if let query = set.swap?.query { line += " In development ?\(query)=<name> swaps it live." }
                lines.append(line)
            case .library:
                lines.append("The company library's themes (\(names)) are the starting point for a new frontend: copy one into the app's themes folder rather than inventing colours.")
            }
        }
        lines.append("In UI code, colours, fonts and radii come from the theme's tokens, never typed in a component. To make a new theme, read ui_standards first and copy the smallest existing one.")
        return lines.joined(separator: " ")
    }

    /// The `ui_standards` tool's answer: everything, or one theme in full (`theme`), or one
    /// doc's text (`doc`, its title or path).
    public static func report(_ standards: Standards, theme: String? = nil, doc: String? = nil) -> String {
        if let doc {
            let wanted = doc.lowercased()
            guard let found = standards.docs.first(where: { $0.title.lowercased() == wanted || $0.path?.lowercased() == wanted || $0.url.lastPathComponent.lowercased() == wanted })
                ?? standards.docs.first(where: { $0.title.lowercased().contains(wanted) }),
                  let text = try? String(contentsOf: found.url, encoding: .utf8) else {
                return "No standards doc called \(doc). There are: \(standards.docs.map(\.title).joined(separator: ", "))."
            }
            return "# \(found.title) (\(found.path ?? found.url.path))\n\n" + String(text.prefix(30_000))
        }
        if let theme {
            for set in standards.themeSets {
                guard let found = set.themes.first(where: { $0.name == theme }) else { continue }
                let problems = set.problems(found)
                return """
                \(found.name) in \(set.title) (\(found.folder?.path ?? "")):

                \(found.json)
                As the app shows it, with \(set.defaultName ?? "no default")'s fields where it leaves them out:
                \(set.resolved(found).json)
                \(problems.isEmpty ? "No problems." : "Problems:\n" + problems.map { "- " + $0 }.joined(separator: "\n"))
                """
            }
            return "No theme called \(theme). There are: \(standards.themeSets.flatMap { $0.themes.map(\.name) }.joined(separator: ", "))."
        }
        guard !standards.isEmpty else {
            return "This project has no standards yet: no docs in docs/standards/ and no themes folder, and no company library is set in Dante's Settings › Files.\n\n" + format
        }
        var lines: [String] = []
        if !standards.docs.isEmpty {
            lines.append("Standards docs (read one with doc):")
            lines += standards.docs.map { "- \($0.title): \($0.path ?? $0.url.path)" }
        }
        for set in standards.themeSets {
            lines.append("")
            lines.append("Themes in \(set.title) (\(set.folder.path)):")
            for theme in set.themes {
                let resolved = set.resolved(theme)
                let colours = ["primary", "secondary", "accent"].compactMap { key in resolved.color(key).map { "\(key) \($0.hex)" } }.joined(separator: ", ")
                let problems = set.problems(theme)
                lines.append("- \(theme.name)\(theme.name == set.defaultName ? " (default)" : ""): \(theme.customerName ?? "no customer name"); \(colours); font \(resolved.fontName ?? "system")" + (problems.isEmpty ? "" : "; \(problems.count) problem\(problems.count == 1 ? "" : "s")"))
            }
            if let swap = set.swap {
                var how: [String] = []
                if let variable = swap.buildVariable { how.append("built with \(variable)=<name>") }
                if let query = swap.query { how.append("swapped live in development with ?\(query)=<name>") }
                lines.append("The app picks one: " + how.joined(separator: "; ") + ".")
            }
        }
        lines += ["", format]
        return lines.joined(separator: "\n")
    }

    /// The theme.json format, for making or changing a theme.
    public static let format = """
    The theme.json format: one folder per theme holding theme.json and the files it names, nothing outside it. Every field is optional except name; a theme falls back to its folder's default theme field by field, except customerName, copyrightHolder, tagline and the pictures, which are the customer's own.
    - name: lower case a-z 0-9 -, the same as the folder.
    - customerName, productName, copyrightHolder, tagline: words on the sign-in page, the title and the copyright line.
    - colors.primary (buttons, links, focus, active navigation; shades are worked out from it), colors.secondary (the far end of the brand gradient), colors.accent, colors.primaryForeground (text on primary, usually white), colors.sidebar and colors.loginCta (default to primary), colors.status.<success|warning|info|neutral|danger>.<fg|bg|border>. Colours are "#rrggbb", "#rgb" or "H S% L%".
    - font.family: a CSS font-family list; font.files: [{ "src": "fonts/x.woff2", "weight": "300 800", "style": "normal" }], with the font's licence (OFL.txt) beside it. Fonts must be licensed for web embedding.
    - radius: "6px" or 6, 0 to 32.
    - assets: logo, logoReversed (white, for dark panels), mark, markReversed, favicon, loginArtwork (a full-page sign-in picture), as file names in the folder.
    - loginLogoHeight (24–120), loginArtworkFocus (0–100).
    Text on the primary colour needs a contrast of at least 4.5:1. Never put a customer's logo in another customer's theme.
    """
}

/// Starting points for standards docs.
public enum StandardsTemplate {
    /// UI standards to fill in, naming the project's themes when it has them.
    public static func ui(themes: [ThemeSet]) -> String {
        let themeLine: String
        if let set = themes.first {
            let names = set.themes.map { "`\($0.name)`" }.joined(separator: ", ")
            themeLine = "Every screen takes its colours, font, corners and logos from a theme in `\(set.folder.lastPathComponent)/` (\(names)), never from values typed in a component. A new customer gets a new theme folder, not changes to the screens."
        } else {
            themeLine = "Every screen takes its colours, font, corners and logos from a theme (a folder with a theme.json), never from values typed in a component. A new customer gets a new theme, not changes to the screens."
        }
        return """
        # UI standards

        What every frontend we build follows. When something here and a design disagree, raise it before building.

        ## Principles

        - Clear before clever: a screen says what it's for and what to do next.
        - One way to do a thing: reuse the existing components before making new ones.
        - Fast to feel: show something at once, and say when something is loading or failed.

        ## Colour and themes

        \(themeLine)

        - Brand colour for actions and the active place, never for decoration.
        - Status colours (green, amber, red) mean something; don't use them for anything else.
        - Text on any colour meets WCAG AA contrast (4.5:1).

        ## Type

        - The theme's font, in a few sizes only:
        - Numbers that are compared line up (tabular figures).

        ## Layout

        - Spacing on a 4-point grid.
        - Works from phone width (390) to wide screens.

        ## Accessibility

        - Everything works with the keyboard, with a visible focus ring.
        - Every input has a label; every image that means something has alt text.

        ## Components

        - Buttons:
        - Forms and validation:
        - Tables:
        - Empty, loading and error states:
        """
    }
}
