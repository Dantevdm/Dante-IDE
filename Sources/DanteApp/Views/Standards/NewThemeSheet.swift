import AppKit
import DanteKit
import SwiftUI

/// Making a theme: where it goes, the theme it starts from (colours, font and corners, never
/// another customer's pictures), the customer's words, colours, font, corners and pictures,
/// with the result drawn as it's made. Or a description for the agent in charge to make it from.
struct NewThemeSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session
    let workspace: Workspace
    let standards: Standards

    @State private var destination: String
    @State private var startName: String
    @State private var customer = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var product = ""
    @State private var copyright = ""
    @State private var tagline = ""
    @State private var primary = Color(red: 0.0, green: 0.38, blue: 0.61)
    @State private var secondary = Color(red: 0.0, green: 0.48, blue: 0.2)
    @State private var accent = Color(red: 0.47, green: 0.75, blue: 0.13)
    @State private var ownSidebar = false
    @State private var sidebar = Color(red: 0.0, green: 0.23, blue: 0.36)
    @State private var radius = 6.0
    @State private var pictures: [String: URL] = [:]
    @State private var describe = ""
    @State private var problem: String?

    /// Where new themes can go: the project's theme folders, the library, or a new folder.
    private struct Destination: Identifiable, Hashable {
        var id: String
        var title: String
        var folder: URL
        var set: ThemeSet?
        static func == (a: Destination, b: Destination) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    init(session: Session, workspace: Workspace, standards: Standards, start: ThemeSet?) {
        self.session = session
        self.workspace = workspace
        self.standards = standards
        let first = start ?? standards.themeSets.first
        _destination = State(initialValue: first?.id ?? "new")
        _startName = State(initialValue: first?.defaultName ?? first?.themes.first?.name ?? "")
    }

    private var destinations: [Destination] {
        var all = standards.themeSets.map { Destination(id: $0.id, title: $0.place == .library ? "Company library" : $0.title, folder: $0.folder, set: $0) }
        if let library = Preferences.shared.standardsLibraryURL, !standards.themeSets.contains(where: { $0.place == .library }) {
            all.append(Destination(id: "library", title: "Company library", folder: library.appending(path: "themes", directoryHint: .isDirectory), set: nil))
        }
        if standards.themeSets.allSatisfy({ $0.place == .library }) {
            all.append(Destination(id: "new", title: "themes/ in this project", folder: workspace.url.appending(path: "themes", directoryHint: .isDirectory), set: nil))
        }
        return all
    }

    private var chosen: Destination? { destinations.first { $0.id == destination } ?? destinations.first }
    /// Themes to start from: those in the chosen folder, else any.
    private var starts: [UITheme] {
        let own = chosen?.set?.themes ?? []
        return own.isEmpty ? standards.themeSets.flatMap(\.themes) : own
    }
    private var start: UITheme? {
        let found = starts.first { $0.name == startName }
        let set = standards.themeSets.first { $0.themes.contains { $0.id == found?.id } }
        return found.map { set?.resolved($0) ?? $0 }
    }

    private var draft: UITheme {
        var made = UITheme(name: name.isEmpty ? "new-theme" : name, folder: start?.folder)
        made.customerName = customer.isEmpty ? nil : customer
        made.productName = product.isEmpty ? start?.productName : product
        made.copyrightHolder = copyright.isEmpty ? nil : copyright
        made.tagline = tagline.isEmpty ? nil : tagline
        let primaryColor = Self.themeColor(primary)
        made.colors["primary"] = primaryColor
        made.colors["secondary"] = Self.themeColor(secondary)
        made.colors["accent"] = Self.themeColor(accent)
        made.colors["primaryForeground"] = ThemeMaker.foreground(on: primaryColor)
        if ownSidebar { made.colors["sidebar"] = Self.themeColor(sidebar) }
        made.fontFamily = start?.fontFamily
        made.fontFiles = start?.fontFiles ?? []
        made.radius = radius.rounded()
        return made
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New theme").font(.dante(size: 15, weight: .semibold)).foregroundStyle(theme.text.color)
                Spacer()
            }
            .padding(16)
            Rectangle().fill(theme.line.color).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                form.frame(width: 400)
                Rectangle().fill(theme.line.color).frame(width: 1)
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow("How it looks")
                    ThemeSignIn(theme: draft, scale: 1.1)
                        .frame(height: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
                    ThemeShell(theme: draft, scale: 1.3)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
                    let ratio = draft.color("primary")!.contrast(with: draft.color("primaryForeground")!)
                    Text(String(format: "Text on the brand colour: %.1f:1%@", ratio, ratio >= 4.5 ? "" : ", below the 4.5:1 reading needs"))
                        .font(.dante(size: 11.5)).foregroundStyle(ratio >= 4.5 ? theme.text3.color : theme.amber.color)
                    Text("Pictures you choose are copied in; the preview shows the start theme’s until then. A theme without a logo shows the customer’s initials.")
                        .font(.dante(size: 11)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Rectangle().fill(theme.line.color).frame(height: 1)
            HStack(spacing: 8) {
                if let problem { Text(problem).font(.dante(size: 12)).foregroundStyle(theme.red.color).lineLimit(2) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Make theme") { make() }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(customer.isEmpty || !UITheme.isValidName(name))
            }
            .padding(14)
        }
        .frame(width: 960, height: 720)
        .background(theme.ground.color)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                field("Goes in") {
                    Picker("", selection: $destination) {
                        ForEach(destinations) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                }
                if !starts.isEmpty {
                    field("Starts from") {
                        Picker("", selection: $startName) {
                            ForEach(starts) { Text($0.name).tag($0.name) }
                        }
                        .labelsHidden()
                        .onChange(of: startName) { takeColours() }
                        .help("Takes its colours, font and corners to change. Never its pictures: those are its customer’s.")
                    }
                }
                field("Customer") {
                    TextField("Acme Insurance", text: $customer)
                        .onChange(of: customer) { if !nameEdited { name = ThemeMaker.slug(customer) } }
                }
                field("Folder name") {
                    TextField("acme-insurance", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                        .font(.dante(size: 12.5, design: .monospaced))
                }
                field("Product") { TextField(start?.productName ?? "The app’s name", text: $product) }
                field("Copyright") { TextField("Acme Insurance Ltd (none shown if empty)", text: $copyright) }
                field("Tagline") { TextField("Optional, under the product on sign-in", text: $tagline) }
                Eyebrow("Colours").padding(.top, 4)
                ColorPicker("Brand (buttons, links, focus)", selection: $primary, supportsOpacity: false)
                ColorPicker("Second (the gradient’s far end)", selection: $secondary, supportsOpacity: false)
                ColorPicker("Accent", selection: $accent, supportsOpacity: false)
                Toggle("Its own sidebar colour", isOn: $ownSidebar)
                if ownSidebar { ColorPicker("Sidebar", selection: $sidebar, supportsOpacity: false) }
                field("Corners: \(Int(radius)) pt") { Slider(value: $radius, in: 0...16, step: 1) }
                Eyebrow("Pictures").padding(.top, 4)
                ForEach([("logoReversed", "White logo (sign-in, documents)"), ("markReversed", "White square mark (sidebar)"),
                         ("favicon", "Tab icon"), ("loginArtwork", "Sign-in picture")], id: \.0) { key, title in
                    HStack {
                        Text(title).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                        Spacer()
                        Text(pictures[key]?.lastPathComponent ?? "None").font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
                        Button("Choose…") { choose(key) }.buttonStyle(DanteButtonStyle())
                    }
                }
                Eyebrow("Or let \(session.agentName) make it").padding(.top, 6)
                TextField("Our customer Acme Insurance: navy and gold, rounded, logo at acme-logo.svg", text: $describe, axis: .vertical)
                    .lineLimit(2...4)
                Button("Ask \(session.agentName) to make it") { askAgent() }
                    .buttonStyle(DanteButtonStyle())
                    .disabled(describe.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Sends your words, the theme format and where it goes to the agent in charge, which writes the folder and checks it")
            }
            .textFieldStyle(.roundedBorder)
            .font(.dante(size: 12.5))
            .padding(18)
        }
        .onAppear { takeColours() }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.dante(size: 11.5, weight: .medium)).foregroundStyle(theme.text3.color)
            content()
        }
    }

    private func takeColours() {
        guard let start else { return }
        if let color = start.color("primary") { primary = color.color }
        if let color = start.color("secondary") { secondary = color.color }
        if let color = start.color("accent") { accent = color.color }
        if let color = start.colors["sidebar"] { ownSidebar = true; sidebar = color.color } else { ownSidebar = false }
        radius = start.radius ?? 6
    }

    private func choose(_ key: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg, .webP, .gif, .ico].compactMap { $0 }
        panel.message = "Choose the customer’s own picture; it’s copied into the theme’s folder."
        if panel.runModal() == .OK, let url = panel.url { pictures[key] = url }
    }

    private func make() {
        guard let chosen else { return }
        var made = draft
        made.folder = nil
        let fontSource = standards.themeSets.flatMap(\.themes).first { $0.name == startName }
        do {
            try ThemeMaker.write(made, into: chosen.folder, assets: pictures, fontsFrom: fontSource.map { theme -> UITheme in
                var source = theme
                if source.fontFamily == nil, let set = standards.themeSets.first(where: { $0.themes.contains { $0.id == theme.id } }) {
                    source.fontFamily = set.resolved(theme).fontFamily
                    if source.fontFiles.isEmpty, let base = set.base { source.fontFiles = base.fontFiles; source.folder = base.folder }
                }
                return source
            })
            Task { await workspace.reloadStandards(library: Preferences.shared.standardsLibraryURL) }
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func askAgent() {
        let place = chosen.map { $0.folder.path.hasPrefix(workspace.url.path + "/") ? String($0.folder.path.dropFirst(workspace.url.path.count + 1)) : $0.folder.path } ?? "themes"
        let start = startName.isEmpty ? "" : " Start from \(startName)'s colours, font and corners where they fit, but never copy its pictures."
        session.askClaude("""
        Make a new frontend theme in \(place)/ from this: \(describe.trimmingCharacters(in: .whitespacesAndNewlines))

        Read ui_standards first for the theme.json format and the themes already there.\(start) Give it its own folder named in lower case, with theme.json and only the customer's own pictures. Keep text on the brand colour at 4.5:1 or better, and say what's still missing (a logo, a licensed font) at the end.
        """)
        dismiss()
    }

    static func themeColor(_ color: Color) -> ThemeColor {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return ThemeColor(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }
}
