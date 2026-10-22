import AppKit
import DanteKit
import SwiftUI

/// Docs › Standards: the house rules a team builds to. Principles and UI standards as docs, and
/// the frontend themes (theme.json folders) from this project and the company library, each
/// drawn as the app looks in it. New themes are made here, from a start theme or by the agent.
struct StandardsView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @Bindable private var preferences = Preferences.shared
    @State private var shown: ShownTheme?
    @State private var reading: Standards.Doc?
    @State private var making: ThemeSet?
    @State private var makingNew = false
    @State private var notice: String?

    struct ShownTheme: Identifiable {
        var theme: UITheme
        var set: ThemeSet
        var id: String { theme.id }
    }

    private var standards: Standards { workspace.standards ?? Standards() }

    var body: some View {
        AreaPage(eyebrow: nil, title: "Standards", subtitle: subtitle, maxWidth: 1240) {
            Button { session.showDoc(DocLibrary.libraryPath) } label: { Label("Docs", systemImage: "chevron.left") }
                .buttonStyle(DanteButtonStyle())
            Button { chooseLibrary() } label: { Label("Library", systemImage: "building.columns") }
                .buttonStyle(DanteButtonStyle())
                .help("The library every project shares: \(preferences.standardsLibraryURL?.path ?? ""). It stays outside every repo, so a customer’s logos never travel in another customer’s project. Click to use another folder.")
            Button { writeStandardsDoc() } label: { Label("New standard", systemImage: "doc.badge.plus") }
                .buttonStyle(DanteButtonStyle())
                .help("Start docs/standards/ui-standards.md: principles, layout, colour and themes, type, accessibility and components, to fill in")
            Button { makingNew = true } label: { Label("New theme", systemImage: "plus") }
                .buttonStyle(DanteButtonStyle(primary: true))
        } content: {
            if let notice {
                Text(notice).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
            }
            docsSection
            ForEach(standards.themeSets) { set in setSection(set) }
            if standards.themeSets.isEmpty {
                EmptyState(symbol: "swatchpalette", title: "No themes yet",
                           message: "A theme is a folder with a theme.json: the customer’s colours, font, corners, logos and sign-in picture. Dante finds any folder of them in the project, and the company library’s.") {
                    Button("Company library…") { chooseLibrary() }.buttonStyle(DanteButtonStyle())
                    Button("New theme…") { makingNew = true }.buttonStyle(DanteButtonStyle(primary: true))
                }
            }
        }
        .sheet(item: $shown) { shown in
            ThemeSheet(session: session, workspace: workspace, theme: shown.theme, set: shown.set, standards: standards) { set in
                self.shown = nil
                making = set
            }
        }
        .sheet(item: $reading) { doc in LibraryDocSheet(doc: doc) }
        .sheet(isPresented: $makingNew) { NewThemeSheet(session: session, workspace: workspace, standards: standards, start: nil) }
        .sheet(item: $making) { set in NewThemeSheet(session: session, workspace: workspace, standards: standards, start: set) }
    }

    private var subtitle: String {
        let docs = standards.docs.count, themes = standards.themeCount
        return "\(docs) standard\(docs == 1 ? "" : "s") · \(themes) theme\(themes == 1 ? "" : "s")"
    }

    // MARK: Docs

    @ViewBuilder private var docsSection: some View {
        if !standards.docs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Principles and standards")
                VStack(spacing: 0) {
                    ForEach(Array(standards.docs.enumerated()), id: \.element.id) { index, doc in
                        if index > 0 { Rectangle().fill(theme.line.color).frame(height: 1) }
                        Button { open(doc) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: doc.path == nil ? "building.columns" : "checklist").font(.dante(size: 12)).foregroundStyle(theme.accent.color).frame(width: 18)
                                Text(doc.title).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                                Spacer()
                                Text(doc.path ?? "Company library").font(.dante(size: 11, design: doc.path == nil ? .default : .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
            }
        }
    }

    private func open(_ doc: Standards.Doc) {
        if let path = doc.path { session.showDoc(path) } else { reading = doc }
    }

    // MARK: Themes

    private func setSection(_ set: ThemeSet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: set.place == .library ? "building.columns" : "swatchpalette").font(.dante(size: 11, weight: .medium)).foregroundStyle(theme.text3.color)
                Eyebrow(set.place == .library ? "Company library themes" : "Themes")
                Text("\(set.themes.count)").font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                if case .project(let path) = set.place {
                    Text(path + "/").font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color.opacity(0.7))
                }
                if let swap = set.swap {
                    if let query = swap.query { Chip(text: "Swaps live with ?\(query)=", symbol: "bolt.fill", color: theme.green.color) }
                    if let variable = swap.buildVariable { Chip(text: variable, symbol: "hammer", mono: true) }
                }
                Spacer()
                if set.place != .library, let library = preferences.standardsLibraryURL {
                    Button("Copy all to the library") { copyAll(set, to: library) }
                        .buttonStyle(DanteButtonStyle())
                        .help("Copies every theme here into the company library, so other projects can start from them. Themes already there are left alone.")
                }
                Button { making = set } label: { Label("New theme here", systemImage: "plus") }.buttonStyle(DanteButtonStyle())
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(set.themes) { theme in
                    ThemeCard(theme: set.resolved(theme), isDefault: theme.name == set.defaultName, problems: set.problems(theme).count) {
                        shown = ShownTheme(theme: theme, set: set)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: Actions

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Library"
        panel.message = "A folder for the standards and themes every project shares: markdown docs, and a themes folder of theme.json folders. Keep it outside any repo."
        if let current = preferences.standardsLibraryURL { panel.directoryURL = current }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.path.hasPrefix(workspace.url.path + "/") || url.path == workspace.url.path {
            notice = "The library can’t be inside this project: it’s for every project, and a customer’s logos shouldn’t travel in another customer’s repo."
            return
        }
        preferences.standardsLibrary = url.path
        notice = nil
        Sessions.all.forEach { $0.applyClaudePreferences() }
    }

    private func copyAll(_ set: ThemeSet, to library: URL) {
        let themes = library.appending(path: "themes", directoryHint: .isDirectory)
        var copied = 0, skipped = 0
        for item in set.themes {
            if (try? ThemeMaker.copy(item, into: themes)) != nil { copied += 1 } else { skipped += 1 }
        }
        notice = "Copied \(copied) theme\(copied == 1 ? "" : "s") to the library" + (skipped > 0 ? "; \(skipped) were there already." : ".")
        Task { await workspace.reloadStandards(library: preferences.standardsLibraryURL) }
    }

    private func writeStandardsDoc() {
        let path = "docs/standards/ui-standards.md"
        let url = workspace.url.appending(path: path)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? StandardsTemplate.ui(themes: standards.themeSets).write(to: url, atomically: true, encoding: .utf8)
        }
        session.docOpensEditing = true
        session.showDoc(path)
    }
}

/// A theme as a card: the app in it, its name and customer, and whether it's the default.
struct ThemeCard: View {
    @Environment(\.theme) private var theme
    let theme_: UITheme
    let isDefault: Bool
    let problems: Int
    let action: () -> Void
    @State private var hovering = false

    init(theme: UITheme, isDefault: Bool, problems: Int, action: @escaping () -> Void) {
        theme_ = theme
        self.isDefault = isDefault
        self.problems = problems
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ThemeShell(theme: theme_)
                    .frame(height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.line.color))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(theme_.name).font(.dante(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(theme.text.color)
                    if isDefault { Chip(text: "Default") }
                    Spacer(minLength: 0)
                    if problems > 0 {
                        Label("\(problems)", systemImage: "exclamationmark.triangle.fill").font(.dante(size: 11, weight: .medium)).foregroundStyle(theme.amber.color)
                            .help("\(problems) problem\(problems == 1 ? "" : "s"): open it to see")
                    }
                }
                .frame(height: 22)
                HStack(spacing: 6) {
                    ForEach(["primary", "secondary", "accent"], id: \.self) { key in
                        if let color = theme_.color(key) {
                            Circle().fill(color.color).frame(width: 11, height: 11).overlay(Circle().strokeBorder(theme.line.color))
                        }
                    }
                    Text([theme_.customerName, theme_.fontName].compactMap { $0 }.joined(separator: " · "))
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? theme.accent.color : theme.line.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A standards doc from the company library, which lives outside the project.
private struct LibraryDocSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let doc: Standards.Doc

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(doc.title).font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }.buttonStyle(DanteButtonStyle())
                Button("Done") { dismiss() }.buttonStyle(DanteButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Rectangle().fill(theme.line.color).frame(height: 1)
            ScrollView {
                DocumentBody(document: MarkdownDocument((try? String(contentsOf: doc.url, encoding: .utf8)) ?? ""),
                             path: doc.url.lastPathComponent, root: doc.url.deletingLastPathComponent(), showsPath: false)
                    .padding(32)
                    .frame(maxWidth: 780, alignment: .leading)
            }
        }
        .frame(width: 820, height: 640)
        .background(theme.ground.color)
    }
}

/// Standards on the Docs front page: the themes in small and the standards docs, or an
/// invitation to start them.
struct StandardsStrip: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        let standards = workspace.standards ?? Standards()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow("Standards")
                Text(standards.isEmpty ? "" : "\(standards.docs.count) doc\(standards.docs.count == 1 ? "" : "s") · \(standards.themeCount) theme\(standards.themeCount == 1 ? "" : "s")")
                    .font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                Spacer()
                LinkButton(standards.isEmpty ? "Set up" : "Open") { session.showDoc(DocLibrary.standardsPath) }
            }
            Button { session.showDoc(DocLibrary.standardsPath) } label: {
                HStack(spacing: 12) {
                    if standards.themeSets.isEmpty {
                        Image(systemName: "swatchpalette").font(.dante(size: 18)).foregroundStyle(theme.accent.color).frame(width: 40)
                        Text("Principles, UI standards and the themes every frontend follows: from this project and your company library. The agents build to them.")
                            .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    } else {
                        ForEach(standards.themeSets.flatMap { set in set.themes.map { set.resolved($0) } }.prefix(6)) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                ThemeShell(theme: item, scale: 0.72)
                                    .frame(width: 150, height: 86)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.line.color))
                                Text(item.name).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text2.color).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
