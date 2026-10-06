import DanteKit
import SwiftUI

struct DanteCommands: Commands {
    let themeStore: ThemeStore
    @FocusedValue(\.session) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { session?.newProject() }
                .keyboardShortcut("n")
            Button("New Window") { openWindow(id: "workspace") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open Folder…") { session?.openFolderPanel() }
                .keyboardShortcut("o")
            Button("Clone Repository…") { session?.isCloning = true }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Set Up Project for Dante…") { session?.offerSetup(force: true) }
                .disabled(session?.workspace == nil)
            Divider()
            Button("New Database…") {
                session?.area = .data
                session?.data.showsNewDatabase = true
            }
            .disabled(session?.workspace == nil)
            Button("Connect to Database…") {
                session?.area = .data
                session?.data.showsConnect = true
            }
            .disabled(session?.workspace == nil)
            Divider()
            Button("Close Project") { session?.closeProject() }
                .disabled(session?.workspace == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { session?.saveActive() }
                .keyboardShortcut("s")
                .disabled(session?.workspace?.activeDocument == nil)
            Button("Save All") { session?.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(session?.workspace == nil)
            Divider()
            Button("Close Tab") { session?.closeActiveTab() }
                .keyboardShortcut("w")
        }

        // ⌘P is Open Quickly here, as in Xcode and VS Code.
        CommandGroup(replacing: .printItem) {
            Button("Export Doc as PDF…") { session?.exportDoc() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(session?.area != .docs)
            Button("Print Doc…") { session?.exportDoc(printing: true) }
                .keyboardShortcut("p")
                .disabled(session?.area != .docs)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Search or Ask…") { session?.palette = .all }
                .keyboardShortcut("k")
                .disabled(session?.workspace == nil)
            Button("Open Quickly…") { session?.palette = .files }
                .keyboardShortcut("p")
                .disabled(session?.workspace == nil)
            Button("Find in Project…") { session?.showSearch() }
                .keyboardShortcut("f", modifiers: [.shift, .command])
                .disabled(session?.workspace == nil)
            Button("Jump to Definition") { session?.jumpToDefinitionAtCursor() }
                .keyboardShortcut("j", modifiers: [.control, .command])
                .disabled(session?.workspace?.activeDocument == nil)
        }

        CommandMenu("Git") {
            Button("Source Control") { session?.showChanges() }
                .keyboardShortcut("g", modifiers: [.control, .shift])
                .disabled(session?.workspace == nil)
            Divider()
            Button("Push") { if let git = session?.git { Task { await git.push() } } }
                .disabled(session?.git.isRepository != true)
            Button("Pull") { if let git = session?.git { Task { await git.pull() } } }
                .disabled(session?.git.isRepository != true)
            Button("Fetch") { if let git = session?.git { Task { await git.fetch() } } }
                .disabled(session?.git.isRepository != true)
            Divider()
            Button("Switch Branch…") { session?.showsBranches = true }
                .keyboardShortcut("b", modifiers: [.control, .shift])
                .disabled(session?.git.isRepository != true)
        }

        CommandGroup(before: .toolbar) {
            Button(session?.showsTerminal == true ? "Hide Terminal" : "Show Terminal") {
                session?.showsTerminal.toggle()
            }
            .keyboardShortcut("`", modifiers: .control)
            .disabled(session?.workspace == nil)
            Button("Back") { session?.goBack() }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
                .disabled(session?.history.canGoBack != true)
            Button("Forward") { session?.goForward() }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
                .disabled(session?.history.canGoForward != true)
            Divider()
            Button("New Terminal") { session?.newTerminal() }
                .keyboardShortcut("`", modifiers: [.control, .shift])
                .disabled(session?.workspace == nil)

            Button("Ask Claude") { session?.focusClaude() }
                .keyboardShortcut("l")
                .disabled(session?.claude == nil)
            Button(session?.showsClaude == true ? "Hide Claude" : "Show Claude") {
                session?.showsClaude.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(session?.claude == nil)

            Button("Next Tab") { session?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { session?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()

            Picker("Theme", selection: Binding(get: { themeStore.id }, set: { themeStore.id = $0 })) {
                ForEach(ThemeID.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Button("Next Theme") { themeStore.cycle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            Button("Bigger Text") { themeStore.adjustFontSize(by: 1) }
                .keyboardShortcut("+")
            Button("Smaller Text") { themeStore.adjustFontSize(by: -1) }
                .keyboardShortcut("-")
            Button("Actual Size") { themeStore.editorFontSize = 13 }
                .keyboardShortcut("0")
            Divider()
        }
    }
}
