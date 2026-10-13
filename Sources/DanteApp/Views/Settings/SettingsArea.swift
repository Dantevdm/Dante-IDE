import AppKit
import DanteKit
import SwiftUI

/// Settings inside the window (⌘,): the app-wide preferences, plus the tools on this Mac
/// and this project's Dante setup, which only make sense next to a project.
struct SettingsArea: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore
    let session: Session
    let workspace: Workspace

    enum Section: String, CaseIterable, Identifiable {
        case appearance = "Appearance", editor = "Editor", keyboard = "Keyboard", languages = "Languages", files = "Files", claude = "Claude", tools = "Tools & drivers", project = "This project"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .appearance: "paintpalette"
            case .editor: "chevron.left.forwardslash.chevron.right"
            case .keyboard: "keyboard"
            case .languages: "curlybraces"
            case .files: "doc"
            case .claude: "sparkle"
            case .tools: "wrench.and.screwdriver"
            case .project: "folder.badge.gearshape"
            }
        }
    }

    @AppStorage("settingsSection") private var section: Section = .appearance

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.dante(size: 20, weight: .semibold)).foregroundStyle(theme.text.color)
                    .padding(.horizontal, 10).padding(.bottom, 12)
                ForEach(Section.allCases) { item in
                    Button { section = item } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.dante(size: 13, weight: section == item ? .medium : .regular))
                            .foregroundStyle(section == item ? theme.text.color : theme.text2.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(section == item ? theme.raised.color : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 28)
            .frame(width: 210)
            .background(theme.panel.color)
            Rectangle().fill(theme.line.color).frame(width: 1)
            Group {
                switch section {
                case .appearance: AppearancePane(themeStore: themeStore)
                case .editor: EditorSettings(preferences: Preferences.shared)
                case .keyboard: KeyboardPane()
                case .languages: LanguagesPane(session: session)
                case .files: FileSettings(preferences: Preferences.shared)
                case .claude: ClaudePreferencesPane(session: session)
                case .tools: ToolsPane(session: session, workspace: workspace)
                case .project: ProjectPane(session: session, workspace: workspace)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.ground.color)
        .tint(theme.accent.color)
    }
}

// MARK: Appearance

private struct AppearancePane: View {
    @Environment(\.theme) private var theme
    @Bindable var themeStore: ThemeStore

    var body: some View {
        Form {
            SwiftUI.Section("Theme") {
                HStack(spacing: 14) {
                    ForEach(ThemeID.allCases, id: \.self) { id in
                        Button { themeStore.id = id } label: {
                            VStack(spacing: 8) {
                                ThemePreview(theme: id.theme)
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(themeStore.id == id ? theme.accent.color : theme.line.color, lineWidth: themeStore.id == id ? 2 : 1))
                                Text(id.displayName).font(.dante(size: 12, weight: themeStore.id == id ? .semibold : .regular)).foregroundStyle(theme.text.color)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
            SwiftUI.Section {
                LabeledContent("Editor font size") {
                    Stepper(value: $themeStore.editorFontSize, in: 9...28, step: 1) {
                        Text("\(Int(themeStore.editorFontSize)) pt").monospacedDigit()
                    }
                }
                Toggle("Geist and Geist Mono", isOn: Bindable(Preferences.shared).usesGeist)
            } footer: {
                Text("Geist is the design’s typeface, bundled with Dante. Off uses SF Pro and SF Mono.")
            }
        }
    }
}

/// A tiny window in a theme's colours: title bar, sidebar, code lines and an accent button.
private struct ThemePreview: View {
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in Circle().fill(theme.line2.color).frame(width: 5, height: 5) }
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 14)
            .background(theme.panel.color)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: 1.5).fill(index == 1 ? theme.accent.color : theme.text3.color.opacity(0.6)).frame(width: 18, height: 3)
                    }
                    Spacer()
                }
                .padding(6)
                .frame(width: 34)
                .background(theme.panel.color)
                VStack(alignment: .leading, spacing: 4) {
                    line(theme.syntax.keyword.color, 14, theme.syntax.function.color, 24)
                    line(theme.syntax.type.color, 20, theme.syntax.string.color, 30)
                    line(theme.syntax.comment.color, 40, nil, 0)
                    line(theme.syntax.keyword.color, 10, theme.syntax.number.color, 12)
                    Spacer()
                    HStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 3).fill(theme.accent.color).frame(width: 26, height: 9)
                    }
                }
                .padding(7)
                .background(theme.codeBackground.color)
            }
        }
        .frame(width: 150, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func line(_ first: Color, _ a: CGFloat, _ second: Color?, _ b: CGFloat) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5).fill(first).frame(width: a, height: 3)
            if let second { RoundedRectangle(cornerRadius: 1.5).fill(second).frame(width: b, height: 3) }
        }
    }
}

// MARK: Claude

private struct ClaudePreferencesPane: View {
    let session: Session
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Model", selection: $preferences.claudeModel) {
                    ForEach(Preferences.ClaudeModel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Ask clarifying questions before ambiguous work", isOn: $preferences.claudeAsksFirst)
                Toggle("Notify me when Claude finishes or needs approval while Dante is in the background", isOn: $preferences.notifiesOnClaude)
                    .onChange(of: preferences.notifiesOnClaude) { _, on in
                        if on { Task { if await !Session.requestNotificationPermission() { preferences.notifiesOnClaude = false } } }
                    }
            } footer: {
                Text("Changes apply from your next message. Sign-in and plan stay in Claude Code.")
            }
            SwiftUI.Section {
                LabeledContent("Skills, memory, connectors and usage") {
                    Button("Open the Claude area") { session.area = .claude }
                }
            }
        }
    }
}

// MARK: Tools

private struct ToolsPane: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var statuses: [String: ToolStatus] = [:]
    @State private var showsAll = false
    @State private var command: CommandLineTool.State?
    private let bundledCommand = CommandLineTool.bundled()

    private var languages: [String] {
        let names: [String: String] = ["go": "Go", "js": "JavaScript", "mjs": "JavaScript", "jsx": "JavaScript", "ts": "TypeScript", "tsx": "TypeScript",
                                       "py": "Python", "rs": "Rust", "swift": "Swift"]
        return Array(Set(workspace.files.compactMap { names[($0 as NSString).pathExtension.lowercased()] }))
    }

    private var tools: [Tool] { showsAll ? Tool.all : Tool.relevant(stack: languages) }

    var body: some View {
        Form {
            SwiftUI.Section("Dante") { commandRow }
            ForEach(Tool.Group.allCases, id: \.self) { group in
                let inGroup = tools.filter { $0.group == group }
                if !inGroup.isEmpty {
                    SwiftUI.Section {
                        ForEach(inGroup) { tool in row(tool) }
                    } header: {
                        Text(group.rawValue)
                    } footer: {
                        if group == .databases {
                            Text("The Data area runs queries through these clients, or inside the database’s container when the client isn’t installed here.")
                        }
                    }
                }
            }
            SwiftUI.Section {
                Toggle("Show tools for languages this project doesn’t use", isOn: $showsAll)
            } footer: {
                Text("Install types the command into the terminal below; press Return to run it. Dante doesn’t install anything itself.")
            }
        }
        .task(id: showsAll) { await check() }
    }

    private func row(_ tool: Tool) -> some View {
        let status = statuses[tool.id]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.dante(size: 13, weight: .medium))
                Text(tool.purpose).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            }
            Spacer()
            if let status {
                if status.installed {
                    Label(status.version ?? "Installed", systemImage: "checkmark.circle.fill")
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.green.color)
                        .help(status.path ?? "")
                } else {
                    Text("Not installed").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                    Button("Install…") { session.typeInTerminal(tool.install) }
                    .help(tool.install)
                }
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }

    /// The `dante` command: open folders and files from any terminal.
    private var commandRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("dante command").font(.dante(size: 13, weight: .medium))
                Text("Open folders and files from the terminal: dante . or dante src/main.go:42")
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            }
            Spacer()
            if let bundledCommand {
                let install = CommandLineTool.installCommand(
                    source: bundledCommand.path,
                    path: Shell.environment()["PATH"] ?? "",
                    home: NSHomeDirectory(),
                    isWritable: { FileManager.default.isWritableFile(atPath: $0) }
                )
                switch command {
                case .installed(let path):
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.green.color)
                        .help(path)
                case .elsewhere(let path):
                    Text("Points to another copy").font(.dante(size: 12)).foregroundStyle(theme.amber.color).help(path)
                    Button("Link This Copy…") { session.typeInTerminal(install) }.help(install)
                case .notInstalled:
                    Text("Not installed").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                    Button("Install…") { session.typeInTerminal(install) }.help(install)
                case nil:
                    ProgressView().controlSize(.mini)
                }
            } else {
                Text("Comes with the app bundle").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
        }
    }

    private func check() async {
        if let bundledCommand {
            let found = Shell.which(CommandLineTool.name)
            let resolved = found.map { URL(filePath: $0).resolvingSymlinksInPath().path }
            command = CommandLineTool.state(found: found, resolved: resolved, bundled: bundledCommand.resolvingSymlinksInPath().path)
        }
        await withTaskGroup(of: (String, ToolStatus).self) { group in
            for tool in tools where statuses[tool.id] == nil {
                group.addTask { (tool.id, await ToolStatus.check(tool)) }
            }
            for await (id, status) in group { statuses[id] = status }
        }
    }
}

// MARK: This project

private struct ProjectPane: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var confirmsRemoval = false
    @State private var confirmsForget = false
    @State private var message: String?

    private var danteFiles: [String] { workspace.files.filter { $0.hasPrefix(".dante/") } }
    private var hasDante: Bool { FileManager.default.fileExists(atPath: workspace.danteFolder.path) }
    private var savedConnections: Int { ConnectionStore().connections(for: workspace.url).count }

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("Folder") {
                    Text(workspace.url.path(percentEncoded: false).replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.dante(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Dante setup") {
                    Text(hasDante ? "\(danteFiles.count) files in .dante/ · \(workspace.tasks.tasks.count) tasks" : "Not set up")
                        .foregroundStyle(theme.text2.color)
                }
            }
            SwiftUI.Section {
                if hasDante {
                    LabeledContent {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.danteFolder]) }
                    } label: {
                        Text("The .dante folder")
                        Text("Phases, tasks, the spec and what Claude may change. Plain files, checked in with the code.")
                    }
                    LabeledContent {
                        Button("Set up again…") { session.offerSetup(force: true) }
                    } label: {
                        Text("Run setup again")
                        Text("Pick a different lifecycle or start the checklists over. Existing tasks are kept.")
                    }
                    LabeledContent {
                        Button("Remove…", role: .destructive) { confirmsRemoval = true }
                    } label: {
                        Text("Remove Dante from this project")
                        Text("Moves .dante/ to the Trash, so you can put it back. The code isn’t touched.")
                    }
                } else {
                    LabeledContent {
                        Button("Set up…") { session.offerSetup(force: true) }
                    } label: {
                        Text("Set up this project for Dante")
                        Text("Adds a .dante folder with phases, a task list and Claude’s rules.")
                    }
                }
            } header: {
                Text("Dante setup")
            }
            SwiftUI.Section {
                LabeledContent {
                    Button("Forget…") { confirmsForget = true }
                        .disabled(savedConnections == 0)
                } label: {
                    Text("Saved database connections")
                    Text(savedConnections == 0 ? "None saved for this project." : "\(savedConnections) saved on this Mac, not in the repo.")
                }
            } header: {
                Text("Kept on this Mac")
            }
            if let message {
                Text(message).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
            }
        }
        .confirmationDialog("Move .dante to the Trash?", isPresented: $confirmsRemoval) {
            Button("Move to Trash", role: .destructive) { removeDante() }
        } message: {
            Text("Dante stops showing phases and tasks for this project. You can restore the folder from the Trash, or set the project up again later.")
        }
        .confirmationDialog("Forget the saved connections?", isPresented: $confirmsForget) {
            Button("Forget", role: .destructive) {
                try? ConnectionStore().removeAll(for: workspace.url)
                message = "Saved connections forgotten."
            }
        }
    }

    private func removeDante() {
        do {
            try FileManager.default.trashItem(at: workspace.danteFolder, resultingItemURL: nil)
            workspace.reloadSpec()
            message = "Moved .dante to the Trash."
        } catch {
            message = "Couldn’t move .dante to the Trash: \(error.localizedDescription)"
        }
    }
}

// MARK: Keyboard

private struct KeyboardPane: View {
    @Environment(\.theme) private var theme
    private let shortcuts = Shortcuts.shared
    @State private var recording: String?

    private var menus: [String] {
        var seen: [String] = []
        for command in Shortcuts.commands where !seen.contains(command.menu) { seen.append(command.menu) }
        return seen
    }

    var body: some View {
        Form {
            ForEach(menus, id: \.self) { menu in
                SwiftUI.Section(menu) {
                    ForEach(Shortcuts.commands.filter { $0.menu == menu }) { command in
                        row(command)
                    }
                }
            }
            SwiftUI.Section {
                HStack {
                    Text("Click a shortcut, then press the new keys. ⌫ removes it, esc cancels.")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    Spacer()
                    Button("Restore All Defaults") { shortcuts.reset() }
                        .disabled(shortcuts.overrides.isEmpty)
                }
            }
        }
        .background(KeyRecorder(isActive: recording != nil) { event in
            guard let id = recording else { return }
            if event.keyCode == 53 { recording = nil; return }
            if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty {
                shortcuts.set(nil, for: id)
                recording = nil
                return
            }
            if let binding = KeyBinding(event: event) {
                shortcuts.set(binding, for: id)
                recording = nil
            }
        })
    }

    private func row(_ command: ShortcutCommand) -> some View {
        let binding = shortcuts.binding(command.id)
        let conflicts = binding.map { shortcuts.conflicts($0, except: command.id) } ?? []
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(command.title)
                Spacer()
                if shortcuts.isChanged(command.id) {
                    Button { shortcuts.reset(command.id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.text3.color)
                        .help("Back to \(command.defaultBinding?.display ?? "no shortcut")")
                }
                Button { recording = recording == command.id ? nil : command.id } label: {
                    Text(recording == command.id ? "Type a shortcut…" : binding?.display ?? "None")
                        .font(.dante(size: 12, design: .monospaced))
                        .foregroundStyle(recording == command.id ? theme.accent.color : binding == nil ? theme.text3.color : theme.text.color)
                        .frame(minWidth: 110)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(recording == command.id ? theme.accentTint.color : theme.raised.color))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording == command.id ? theme.accentLine.color : theme.line2.color))
                }
                .buttonStyle(.plain)
            }
            if !conflicts.isEmpty {
                Text("Also on \(conflicts.map(\.title).joined(separator: ", ")); whichever is available at the time runs.")
                    .font(.dante(size: 11)).foregroundStyle(theme.amber.color)
            }
            if MenuShortcuts.shared.needsRestart.contains(command.id) {
                Text("The menu shows this after Dante restarts.")
                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            }
        }
    }
}

/// Hands key presses to `record` while a shortcut is being recorded, and swallows them.
private struct KeyRecorder: NSViewRepresentable {
    let isActive: Bool
    let record: @MainActor (NSEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard coordinator.isActive else { return event }
            MainActor.assumeIsolated { coordinator.record?(event) }
            return nil
        }
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.record = record
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    @MainActor
    final class Coordinator {
        var isActive = false
        var record: (@MainActor (NSEvent) -> Void)?
        var monitor: Any?
    }
}

// MARK: Languages

private struct LanguagesPane: View {
    @Environment(\.theme) private var theme
    let session: Session
    @State private var options: [String: LanguageServerOptions] = LanguageServerOptions.load()
    @State private var saved: [String: LanguageServerOptions] = LanguageServerOptions.load()

    var body: some View {
        Form {
            ForEach(LanguageServer.all, id: \.name) { server in
                SwiftUI.Section {
                    Toggle("Run \(server.name)", isOn: binding(server.name, \.enabled))
                    TextField("Command", text: binding(server.name, \.command),
                              prompt: Text(server.commands.map { $0.joined(separator: " ") }.joined(separator: "  or  ")))
                        .font(.dante(size: 12, design: .monospaced))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings (JSON)").font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                        TextEditor(text: binding(server.name, \.settings))
                            .font(.dante(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(5)
                            .frame(height: 70)
                            .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color))
                        if let error = options[server.name]?.settingsError {
                            Text(error).font(.dante(size: 11)).foregroundStyle(theme.red.color)
                        }
                    }
                    if (options[server.name] ?? LanguageServerOptions()) != (saved[server.name] ?? LanguageServerOptions()) {
                        HStack {
                            Spacer()
                            Button("Revert") { options[server.name] = saved[server.name] }
                            Button("Apply and Restart") { apply(server.name) }
                                .buttonStyle(.borderedProminent)
                                .disabled(options[server.name]?.settingsError != nil)
                        }
                    }
                } header: {
                    Text("\(server.name) · \(server.languageIDs.keys.map(\.displayName).sorted().joined(separator: ", "))")
                }
            }
            SwiftUI.Section {
                Text("Settings go to the server when it starts and whenever it asks for them. A server restarts the next time a file in its language opens.")
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
            }
        }
    }

    private func binding<Value>(_ name: String, _ path: WritableKeyPath<LanguageServerOptions, Value>) -> Binding<Value> {
        Binding(get: { (options[name] ?? LanguageServerOptions())[keyPath: path] },
                set: { value in var current = options[name] ?? LanguageServerOptions(); current[keyPath: path] = value; options[name] = current })
    }

    private func apply(_ name: String) {
        LanguageServerOptions.save(options)
        saved = options
        session.languages?.restart(name)
        // Files already open in that language get the server back right away.
        if let workspace = session.workspace {
            for document in workspace.documents where LanguageServer.for(document.language)?.name == name {
                session.languages?.opened(document)
            }
        }
    }
}
