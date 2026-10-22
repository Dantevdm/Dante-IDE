import Foundation
import Testing
@testable import DanteKit

@Suite struct StandardsTests {
    /// A project with a frontend and its themes folder: `base` (the default) and `harbour`,
    /// made up, plus a build copy in dist that must be ignored.
    private func project() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "standards-\(UUID().uuidString)")
        let write = { (path: String, text: String) in
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("web/themes/README.md", "# Themes\n\nOne folder per look. `base` is the built-in theme: every other one falls back to it.\n")
        try write("web/themes/base/theme.json", """
        { "name": "base", "customerName": "Studio", "productName": "Ledger", "copyrightHolder": "Studio Ltd",
          "colors": { "primary": "#00629b", "secondary": "#007a33", "primaryForeground": "#ffffff" },
          "font": { "family": "'Work Sans', sans-serif", "files": [{ "src": "fonts/work-sans.woff2", "weight": "300 800" }] },
          "radius": "6px", "assets": { "logoReversed": "logo-reversed.svg" } }
        """)
        try write("web/themes/base/logo-reversed.svg", "<svg/>")
        try write("web/themes/base/fonts/work-sans.woff2", "font")
        try write("web/themes/base/fonts/OFL.txt", "licence")
        try write("web/themes/harbour/theme.json", """
        { "name": "harbour", "customerName": "Harbour Mutual", "colors": { "primary": "214 80% 32%", "accent": "nonsense" },
          "radius": 10, "assets": { "markReversed": "mark.svg", "favicon": "../base/logo-reversed.svg" }, "gizmo": true }
        """)
        try write("web/dist/theme/theme.json", #"{ "name": "base", "colors": {} }"#)
        try write("web/src/theme/boot.ts", "const name = new URLSearchParams(location.search).get('theme') ?? import.meta.env.VITE_THEME\n")
        try write("web/.env.production", "VITE_THEME=harbour\n")
        try write("docs/standards/ui-standards.md", "# UI standards\n\nUse tokens.\n")
        try write("docs/standards/principles.md", "Plain words.\n")
        return root
    }

    private func files(_ root: URL) -> [String] { FileIndex.scan(root) }

    @Test func coloursReadAsHexOrHSL() throws {
        #expect(ThemeColor("#00629b")?.hex == "#00629b")
        #expect(ThemeColor("#fff")?.hex == "#ffffff")
        #expect(ThemeColor("214 80% 32%")?.hex == "#104993")
        #expect(ThemeColor("0 0% 100%")?.hex == "#ffffff")
        #expect(ThemeColor("167.6 100% 29.4%") != nil)
        #expect(ThemeColor("red") == nil && ThemeColor("#12345") == nil && ThemeColor("400 10% 10%") == nil)
        let white = ThemeColor("#ffffff")!, black = ThemeColor("#000000")!
        #expect(abs(white.contrast(with: black) - 21) < 0.01)
        #expect(ThemeMaker.foreground(on: ThemeColor("#00629b")!) == white)
        #expect(ThemeMaker.foreground(on: ThemeColor("#ffd400")!).hex == "#111827")
    }

    @Test func themesReadLenientlyAndFallBackFieldByField() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try #require(ThemeSet.read(folder: root.appending(path: "web/themes"), place: .project("web/themes")))
        #expect(set.defaultName == "base")
        #expect(set.themes.map(\.name) == ["base", "harbour"])
        let harbour = set.themes[1]
        #expect(harbour.invalid == ["assets.favicon", "colors.accent"])
        #expect(harbour.extra["gizmo"] == .bool(true))
        #expect(harbour.radius == 10)
        let shown = set.resolved(harbour)
        #expect(shown.color("primary")?.hex == "#104993")
        #expect(shown.color("secondary")?.hex == "#007a33")
        #expect(shown.fontName == "Work Sans")
        #expect(shown.productName == "Ledger")
        // A customer's own fields never come from the default.
        #expect(shown.copyrightHolder == nil)
        #expect(shown.assets["logoReversed"] == nil)
        #expect(shown.initials == "HM")
        #expect(shown.color("sidebar") == shown.color("primary"))
        // A default's sidebar never paints another theme's: it follows the theme's own primary.
        var dark = set.themes[0]
        dark.colors["sidebar"] = ThemeColor("#003a5c")
        #expect(harbour.over(dark).color("sidebar") == harbour.color("primary"))
        #expect(harbour.ownsColor("loginCta") && !harbour.ownsColor("secondary"))
    }

    @Test func problemsAreTheChecksABuildMakes() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try #require(ThemeSet.read(folder: root.appending(path: "web/themes"), place: .project("web/themes")))
        #expect(set.problems(set.themes[0]).isEmpty)
        let problems = set.problems(set.themes[1])
        #expect(problems.contains("assets.markReversed names mark.svg, which isn’t there."))
        #expect(problems.contains("colors.accent couldn’t be read."))
        var faint = set.themes[0]
        faint.colors["primary"] = ThemeColor("#ffd400")
        faint.name = "Faint"
        let more = faint.problems(folderName: "base") { _ in true }
        #expect(more.contains { $0.hasPrefix("Its name “Faint” must be lower case") })
        #expect(more.contains { $0.contains("differs from its folder") })
        #expect(more.contains { $0.hasPrefix("Text on the primary colour has a contrast") })
        #expect(UITheme.isInside("fonts/a.woff2") && !UITheme.isInside("../x") && !UITheme.isInside("/x") && !UITheme.isInside("https://x/y.png"))
    }

    @Test func writtenThemesReadBackTheSame() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try #require(ThemeSet.read(folder: root.appending(path: "web/themes"), place: .project("web/themes")))
        for theme in set.themes {
            var read = try #require(UITheme.parse(Data(theme.json.utf8), folder: theme.folder))
            read.invalid = theme.invalid
            #expect(read == theme)
        }
        #expect(set.themes[0].json.hasPrefix("{\n  \"name\": \"base\",\n  \"customerName\": \"Studio\""))
        #expect(UITheme.parse(Data(#"{"compilerOptions": {}}"#.utf8)) == nil)
    }

    @Test func projectsAreSearchedForThemeFoldersAndHowTheAppPicksOne() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = files(root)
        #expect(ThemeSet.folders(in: files) == ["web/themes"])
        let standards = Standards.load(projectRoot: root, files: files, library: nil)
        #expect(standards.docs.map(\.title) == ["Principles", "UI standards"])
        let set = try #require(standards.themeSets.first)
        #expect(set.swap == ThemeSwap(buildVariable: "VITE_THEME", query: "theme"))
        #expect(standards.themeSets(within: "web").count == 1)
        #expect(standards.themeSets(within: "api").isEmpty)
        #expect(Standards.current(set, envTexts: ["VITE_THEME=harbour\n"]) == "harbour")
        #expect(Standards.current(set, envTexts: ["VITE_THEME=unknown\n"]) == "base")
    }

    @Test func liveSwapKeepsHashRoutes() {
        let swap = ThemeSwap(query: "theme")
        #expect(swap.url(URL(string: "http://localhost:5173/")!, theme: "harbour")?.absoluteString == "http://localhost:5173/?theme=harbour")
        #expect(swap.url(URL(string: "http://localhost:5173/#/orders")!, theme: "harbour")?.absoluteString == "http://localhost:5173/?theme=harbour#/orders")
        #expect(swap.url(URL(string: "http://localhost:5173/a?theme=base&x=1")!, theme: "harbour")?.absoluteString == "http://localhost:5173/a?x=1&theme=harbour")
        #expect(ThemeSwap(buildVariable: "VITE_THEME").url(URL(string: "http://localhost/")!, theme: "x") == nil)
        #expect(ThemeSwap.detect(in: ["const t = process.env.REACT_APP_THEME"]) == ThemeSwap(buildVariable: "REACT_APP_THEME"))
        #expect(ThemeSwap.detect(in: ["const theme = 'dark'"]) == nil)
    }

    @Test func defaultThemeFromTheReadme() {
        #expect(ThemeSet.defaultName(readme: "| `base` | Studio | Default. Work Sans. |", names: ["base", "other"]) == "base")
        #expect(ThemeSet.defaultName(readme: "Themes: `other` and `base`.", names: ["base", "other"]) == nil)
        #expect(ThemeSet.defaultName(readme: nil, names: ["default", "other"]) == "default")
        #expect(ThemeSet.defaultName(readme: nil, names: ["only"]) == "only")
    }

    @Test func newThemesNeverCarryAnotherCustomersPictures() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try #require(ThemeSet.read(folder: root.appending(path: "web/themes"), place: .project("web/themes")))
        let base = set.themes[0]
        var made = UITheme(name: ThemeMaker.slug("Kelp & Co."), customerName: "Kelp & Co.", colors: ["primary": ThemeColor("#0f766e")!])
        made.fontFamily = base.fontFamily
        let logo = root.appending(path: "kelp-logo.png")
        try Data([0x89]).write(to: logo)
        let folder = try ThemeMaker.write(made, into: set.folder, assets: ["markReversed": logo], fontsFrom: base)
        #expect(folder.lastPathComponent == "kelp-co")
        let read = try #require(UITheme.read(folder: folder))
        #expect(read.assets == ["markReversed": "mark-reversed.png"])
        #expect(read.fontFiles.map(\.src) == ["fonts/work-sans.woff2"])
        #expect(read.json.contains("\"fonts/work-sans.woff2\""))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "fonts/OFL.txt").path))
        #expect(throws: ThemeMaker.Failure.self) { try ThemeMaker.write(made, into: set.folder) }

        let library = root.appending(path: "library/themes")
        let copied = try ThemeMaker.copy(base, into: library, as: "base-copy")
        #expect(UITheme.read(folder: copied)?.name == "base-copy")
        #expect(FileManager.default.fileExists(atPath: copied.appending(path: "logo-reversed.svg").path))
    }

    @Test func theLibraryAddsDocsAndThemesForEveryProject() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appending(path: "library")
        try FileManager.default.createDirectory(at: library.appending(path: "themes/pier"), withIntermediateDirectories: true)
        try ##"{ "name": "pier", "colors": { "primary": "#334155" } }"##.write(to: library.appending(path: "themes/pier/theme.json"), atomically: true, encoding: .utf8)
        try "# Accessibility\n".write(to: library.appending(path: "accessibility.md"), atomically: true, encoding: .utf8)
        try "# Not a doc\n".write(to: library.appending(path: "themes/pier/README.md"), atomically: true, encoding: .utf8)
        try "# Library themes\n".write(to: library.appending(path: "themes/README.md"), atomically: true, encoding: .utf8)
        let standards = Standards.load(projectRoot: root, files: files(root).filter { !$0.hasPrefix("library/") }, library: library)
        #expect(standards.docs.map(\.title) == ["Principles", "UI standards", "Accessibility", "Library themes"])
        #expect(standards.docs.last?.path == nil)
        #expect(standards.themeSets.map(\.place) == [.project("web/themes"), .library])
        #expect(standards.themeSets.last?.defaultName == "pier")
        #expect(standards.themeCount == 3)

        // An app's own themes folder chosen as the library: its themes, and its README as a doc.
        let reference = Standards.load(projectRoot: library, files: [], library: root.appending(path: "web/themes"))
        #expect(reference.themeSets.map(\.place) == [.library])
        #expect(reference.themeSets.first?.themes.map(\.name) == ["base", "harbour"])
        #expect(reference.docs.map(\.title) == ["Themes"])
        // Open the app the library came from, and its themes show once, as the project's.
        #expect(Standards.load(projectRoot: root, files: files(root).filter { !$0.hasPrefix("library/") }, library: root.appending(path: "web/themes")).themeSets.count == 1)
    }

    @Test func agentsAreBriefedAndCanAsk() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let standards = Standards.load(projectRoot: root, files: files(root), library: nil)
        let brief = try #require(StandardsBrief.brief(standards))
        #expect(brief.contains("web/themes/ (base, harbour; base is the default)"))
        #expect(brief.contains("VITE_THEME") && brief.contains("?theme=<name>"))
        #expect(StandardsBrief.brief(Standards()) == nil)
        let report = StandardsBrief.report(standards)
        #expect(report.contains("- base (default): Studio; primary #00629b"))
        #expect(report.contains("The theme.json format"))
        #expect(StandardsBrief.report(standards, theme: "harbour").contains("As the app shows it, with base's fields"))
        #expect(StandardsBrief.report(standards, doc: "ui standards").contains("Use tokens."))
        #expect(StandardsBrief.report(standards, theme: "nope").hasPrefix("No theme called nope"))
        #expect(StandardsTemplate.ui(themes: standards.themeSets).contains("`base`, `harbour`"))

        let server = DelegateServer.live(project: "shop", root: root.path, environment: [DelegateEnvironment.local: "0"])
        #expect(server.tools.contains { $0["name"]?.string == "ui_standards" })
        let answer = await server.call("ui_standards", arguments: ["theme": "base"])
        #expect(answer["content"]?.array?.first?["text"]?.string?.contains("\"customerName\": \"Studio\"") == true)
    }
}
