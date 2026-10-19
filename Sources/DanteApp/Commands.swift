import DanteKit
import SwiftUI

struct DanteCommands: Commands {
    let themeStore: ThemeStore
    @FocusedValue(\.session) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { session?.newProject() }
                .shortcut("newProject")
            Button("New Window") { openWindow(id: "workspace") }
                .shortcut("newWindow")
            Divider()
            Button("Open Folder…") { session?.openFolderPanel() }
                .shortcut("openFolder")
            Button("Clone Repository…") { session?.isCloning = true }
                .shortcut("clone")
            Button("Open Remote…") { session?.showsOpenRemote = true }
                .shortcut("openRemote")
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
                .shortcut("save")
                .disabled(session?.workspace?.activeDocument == nil)
            Button("Save All") { session?.saveAll() }
                .shortcut("saveAll")
                .disabled(session?.workspace == nil)
            Divider()
            Button("Close Tab") { session?.closeActiveTab() }
                .shortcut("closeTab")
        }

        // ⌘P is Open Quickly here, as in Xcode and VS Code.
        CommandGroup(replacing: .printItem) {
            Button("Export Doc as PDF…") { session?.exportDoc() }
                .shortcut("exportDoc")
                .disabled(session?.area != .docs)
            Button("Print Doc…") { session?.exportDoc(printing: true) }
                .shortcut("printDoc")
                .disabled(session?.area != .docs)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Search or Ask…") { session?.palette = .all }
                .shortcut("searchOrAsk")
                .disabled(session?.workspace == nil)
            Button("Open Quickly…") { session?.palette = .files }
                .shortcut("openQuickly")
                .disabled(session?.workspace == nil)
            Button("Find in Project…") { session?.showSearch() }
                .shortcut("findInProject")
                .disabled(session?.workspace == nil)
            Button("Go to Symbol…") { session?.palette = .symbols }
                .shortcut("goToSymbol")
                .disabled(session?.workspace == nil)
            Button("Jump to Definition") { session?.jumpToDefinitionAtCursor() }
                .shortcut("jumpToDefinition")
                .disabled(session?.workspace?.activeDocument == nil)
            Button("Edit with Claude…") { session?.editWithClaude() }
                .shortcut("editWithClaude")
                .disabled(session?.workspace?.activeDocument == nil)
            Button("Find References") { session?.findReferencesAtCursor() }
                .shortcut("findReferences")
                .disabled(session?.workspace?.activeDocument == nil)
            Button("Rename Symbol…") { session?.renameSymbolAtCursor() }
                .shortcut("renameSymbol")
                .disabled(session?.workspace?.activeDocument == nil)
            Button("Format Document") { session?.formatActiveDocument() }
                .shortcut("formatDocument")
                .disabled(session?.workspace?.activeDocument == nil)
            Divider()
            Button("Problems") { session?.showProblems() }
                .shortcut("problems")
                .disabled(session?.workspace == nil)
        }

        CommandMenu("Git") {
            Button("Source Control") { session?.showChanges() }
                .shortcut("sourceControl")
                .disabled(session?.workspace == nil)
            Divider()
            Button("Push") { if let git = session?.git { Task { await git.push() } } }
                .shortcut("push")
                .disabled(session?.git.isRepository != true)
            Button("Pull") { if let git = session?.git { Task { await git.pull() } } }
                .shortcut("pull")
                .disabled(session?.git.isRepository != true)
            Button("Fetch") { if let git = session?.git { Task { await git.fetch() } } }
                .shortcut("fetch")
                .disabled(session?.git.isRepository != true)
            Divider()
            Button("Switch Branch…") { session?.showsBranches = true }
                .shortcut("switchBranch")
                .disabled(session?.git.isRepository != true)
        }

        CommandMenu("Debug") {
            let debug = session?.debug
            let live = debug.map { $0.state != .ended } ?? false
            let stopped = debug?.state == .stopped
            Button("Start Debugging") { session?.startDebugging() }
                .shortcut("debugStart")
                .disabled(session?.canDebugActiveFile != true && !stopped)
            Button("Continue") { debug?.resume() }
                .shortcut("debugContinue")
                .disabled(!stopped)
            Divider()
            Button("Step Over") { debug?.stepOver() }
                .shortcut("debugStepOver")
                .disabled(!stopped)
            Button("Step Into") { debug?.stepIn() }
                .shortcut("debugStepIn")
                .disabled(!stopped)
            Button("Step Out") { debug?.stepOut() }
                .shortcut("debugStepOut")
                .disabled(!stopped)
            Divider()
            Button("Stop Debugging") { session?.stopDebugging() }
                .shortcut("debugStop")
                .disabled(!live)
            Button("Toggle Breakpoint") { session?.toggleBreakpointAtCursor() }
                .shortcut("debugToggleBreakpoint")
                .disabled(session?.canDebugActiveFile != true)
        }

        CommandGroup(before: .toolbar) {
            Button(session?.showsTerminal == true ? "Hide Terminal" : "Show Terminal") {
                session?.showsTerminal.toggle()
            }
            .shortcut("toggleTerminal")
            .disabled(session?.workspace == nil)
            Button("Back") { session?.goBack() }
                .shortcut("back")
                .disabled(session?.history.canGoBack != true)
            Button("Forward") { session?.goForward() }
                .shortcut("forward")
                .disabled(session?.history.canGoForward != true)
            Divider()
            Button("New Terminal") { session?.newTerminal() }
                .shortcut("newTerminal")
                .disabled(session?.workspace == nil)

            Button("Ask \(session?.agentName ?? "Claude")") { session?.focusClaude() }
                .shortcut("askClaude")
                .disabled(session?.claude == nil)
            Button(session?.showsClaude == true ? "Hide \(session?.agentName ?? "Claude")" : "Show \(session?.agentName ?? "Claude")") {
                session?.showsClaude.toggle()
            }
            .shortcut("toggleClaude")
            .disabled(session?.claude == nil)

            Button("Next Tab") { session?.selectTab(offset: 1) }
                .shortcut("nextTab")
            Button("Previous Tab") { session?.selectTab(offset: -1) }
                .shortcut("previousTab")
            Button(session?.workspace?.split == nil ? "Split Editor" : "Close Split") { session?.toggleSplit() }
                .shortcut("split")
                .disabled(session?.workspace?.activeDocument == nil)
            Button("Focus Other Pane") { session?.focusOtherPane() }
                .shortcut("focusOtherPane")
                .disabled(session?.workspace?.split == nil)
            Divider()

            Picker("Theme", selection: Binding(get: { themeStore.id }, set: { themeStore.id = $0 })) {
                ForEach(ThemeID.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Button("Next Theme") { themeStore.cycle() }
                .shortcut("nextTheme")
            Divider()
            Button("Bigger Text") { themeStore.adjustFontSize(by: 1) }
                .shortcut("biggerText")
            Button("Smaller Text") { themeStore.adjustFontSize(by: -1) }
                .shortcut("smallerText")
            Button("Actual Size") { themeStore.editorFontSize = 13 }
                .shortcut("actualSize")
            Divider()
            Button("Stage in a Window") { StageController.shared.open(fullScreen: false) }
            Button("Stage Full Screen") { StageController.shared.open(fullScreen: true) }
            Divider()
        }
    }
}
