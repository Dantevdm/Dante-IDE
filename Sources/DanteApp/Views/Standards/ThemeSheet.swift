import AppKit
import DanteKit
import SwiftUI

/// One theme in full: its sign-in panel and app shell, every field with where it came from,
/// what's wrong with it, and opening the running app in it when the app swaps themes live.
struct ThemeSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let session: Session
    let workspace: Workspace
    let theme_: UITheme
    let themeSet: ThemeSet
    let standards: Standards
    let makeFrom: (ThemeSet) -> Void
    @State private var notice: String?

    init(session: Session, workspace: Workspace, theme: UITheme, set: ThemeSet, standards: Standards, makeFrom: @escaping (ThemeSet) -> Void) {
        self.session = session
        self.workspace = workspace
        theme_ = theme
        self.themeSet = set
        self.standards = standards
        self.makeFrom = makeFrom
    }

    private var resolved: UITheme { themeSet.resolved(theme_) }
    private var problems: [String] { themeSet.problems(theme_) }

    /// The frontend beside a project's themes folder, from the project's root.
    private var appFolder: String? {
        guard case .project(let path) = themeSet.place else { return nil }
        return (path as NSString).deletingLastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.line.color).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        ThemeSignIn(theme: resolved, scale: 1.25)
                            .frame(height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
                        ThemeShell(theme: resolved, scale: 1.6)
                            .frame(height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.line.color))
                    }
                    if let launch = session.webLaunch, launch.theme?.name == theme_.name {
                        WebLaunchCard(session: session, launch: launch)
                    }
                    if !problems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Eyebrow("Problems")
                            ForEach(problems, id: \.self) { problem in
                                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.dante(size: 12)).foregroundStyle(theme.amber.color)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 28) {
                        colours.frame(maxWidth: .infinity, alignment: .leading)
                        details.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let notice { Text(notice).font(.dante(size: 12)).foregroundStyle(theme.text2.color) }
                }
                .padding(22)
            }
        }
        .frame(width: 880, height: 700)
        .background(theme.ground.color)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(theme_.name).font(.dante(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(theme.text.color)
                    if theme_.name == themeSet.defaultName { Chip(text: "Default") }
                }
                Text([theme_.customerName, themeSet.title].compactMap { $0 }.joined(separator: " · ")).font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
            Spacer()
            if let appFolder, let query = themeSet.swap?.query {
                Button {
                    session.openInBrowser(folder: appFolder, name: appFolder.isEmpty ? workspace.name : (appFolder as NSString).lastPathComponent,
                                          screen: nil, theme: (query, theme_.name))
                } label: { Label("Open the app in it", systemImage: "bolt.fill") }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .help("Opens the running app with ?\(query)=\(theme_.name): it swaps the theme live, no restart. If the dev server isn’t running, Dante says so and starts it when you agree.")
            } else if appFolder != nil, let variable = themeSet.swap?.buildVariable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(variable)=\(theme_.name)", forType: .string)
                    notice = "Copied \(variable)=\(theme_.name). This app picks its theme when it’s built, so set it before building or starting it."
                } label: { Label("Copy \(variable)=\(theme_.name)", systemImage: "doc.on.doc") }
                    .buttonStyle(DanteButtonStyle())
            }
            Menu {
                Button("New theme from this…") { makeFrom(themeSet) }
                if themeSet.place != .library, let library = Preferences.shared.standardsLibraryURL {
                    Button("Copy to the company library") { copy(into: library.appending(path: "themes", directoryHint: .isDirectory), what: "the company library") }
                }
                if themeSet.place == .library {
                    ForEach(standards.themeSets.filter { $0.place != .library }) { target in
                        Button("Copy into \(target.title)") { copy(into: target.folder, what: target.title) }
                    }
                }
                Divider()
                Button("Open theme.json") { openFile() }
                Button("Show in Finder") { if let folder = theme_.folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            Button("Done") { dismiss() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var colours: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Colours")
            ForEach(UITheme.colorKeys, id: \.self) { key in
                if let color = resolved.color(key) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 5).fill(color.color).frame(width: 26, height: 18).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.line.color))
                        Text(key).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text.color)
                        Spacer()
                        Text(color.hex).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2.color)
                        source(key: "colors.\(key)", own: theme_.ownsColor(key))
                    }
                }
            }
            if let primary = resolved.color("primary"), let text = resolved.color("primaryForeground") {
                let ratio = primary.contrast(with: text)
                Text(String(format: "Text on primary: %.1f:1 %@", ratio, ratio >= 4.5 ? "(passes AA)" : "(below AA’s 4.5:1)"))
                    .font(.dante(size: 11.5)).foregroundStyle(ratio >= 4.5 ? theme.text3.color : theme.amber.color)
            }
            if !resolved.status.isEmpty {
                Text("Status colours: " + resolved.status.keys.sorted().joined(separator: ", ")).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Type, corners and pictures")
            row("Font", resolved.fontName ?? "The app’s own", own: theme_.fontFamily != nil, key: "font")
            row("Corners", resolved.radius.map { "\(Int($0)) pt" } ?? "The app’s own", own: theme_.radius != nil, key: "radius")
            row("Product", resolved.productName ?? "—", own: theme_.productName != nil, key: "productName")
            row("Copyright", theme_.copyrightHolder ?? "None shown", own: true, key: "copyrightHolder")
            HStack(spacing: 10) {
                ForEach(UITheme.assetKeys, id: \.self) { key in
                    if let url = theme_.url(of: key), FileManager.default.fileExists(atPath: url.path) {
                        VStack(spacing: 3) {
                            ThemeAsset(theme: theme_, asset: key, fill: key == "loginArtwork")
                                .frame(width: 54, height: 34)
                                .padding(4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(key.hasSuffix("Reversed") ? (resolved.color("primary") ?? ThemeColor("#333333")!).color : Color.white))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(key).font(.dante(size: 9.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                        }
                    }
                }
            }
            .padding(.top, 4)
            if theme_.assets.isEmpty {
                Text("No pictures: the app shows the customer’s initials, never another customer’s logo.").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            }
        }
    }

    private func row(_ title: String, _ value: String, own: Bool, key: String) -> some View {
        HStack {
            Text(title).font(.dante(size: 12)).foregroundStyle(theme.text3.color).frame(width: 80, alignment: .leading)
            Text(value).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
            Spacer()
            source(key: key, own: own)
        }
    }

    /// Where a field came from: the theme itself, or its set's default.
    @ViewBuilder private func source(key: String, own: Bool) -> some View {
        if !own, let base = themeSet.defaultName, base != theme_.name {
            Text("from \(base)").font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
                .help("This theme leaves \(key) out, so the app uses \(base)’s")
        }
    }

    private func copy(into folder: URL, what: String) {
        do {
            try ThemeMaker.copy(theme_, into: folder)
            notice = "Copied \(theme_.name) into \(what)."
            Task { await workspace.reloadStandards(library: Preferences.shared.standardsLibraryURL) }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func openFile() {
        guard let file = theme_.folder?.appending(path: "theme.json") else { return }
        if file.path.hasPrefix(workspace.url.path + "/") {
            dismiss()
            session.open(file: file)
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}
