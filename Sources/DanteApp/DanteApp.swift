import AppKit
import DanteKit
import SwiftUI

@main
struct DanteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var themeStore = ThemeStore()
    @State private var recents = RecentProjects()

    var body: some Scene {
        WindowGroup(id: "workspace") {
            RootView(recents: recents)
                .environment(themeStore)
                .environment(recents)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            DanteCommands(themeStore: themeStore)
        }

        Settings {
            SettingsView()
                .environment(themeStore)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Paths passed on the command line (`Dante path/to/project [file …]`): the first window
    /// opens the folder, then any files after it.
    @MainActor static var launchPaths: [URL] = CommandLine.arguments.dropFirst()
        .filter { !$0.hasPrefix("-") }
        .map { URL(filePath: $0, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath)).standardizedFileURL }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `launchPaths` handles the folder argument. Left to AppKit, it becomes an open-file
        // event, and SwiftUI then skips the window it would make at launch.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare executable (`swift run`) rather than the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Quitting with unsaved files asks once for all windows: save, cancel or discard.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sessions = Sessions.all
        let documents = sessions.flatMap { $0.workspace?.documents ?? [] }
        let proceed = Session.confirmDiscardingChanges(in: documents) { document in
            sessions.first { $0.workspace?.documents.contains { $0 === document } == true }?.save(document)
        }
        return proceed ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        for session in Sessions.all { session.claude?.stop() }
    }
}

/// One window: the launch screen until a folder is open, then the workspace.
struct RootView: View {
    @Environment(ThemeStore.self) private var themeStore
    @State private var session: Session

    init(recents: RecentProjects) {
        _session = State(initialValue: Session(recents: recents))
    }

    var body: some View {
        let theme = themeStore.theme
        Group {
            if let workspace = session.workspace {
                WorkspaceView(session: session, workspace: workspace)
            } else {
                LaunchView(session: session)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        // The title bar is hidden; views draw into its space and leave room for the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .background(theme.ground.color)
        .environment(\.theme, theme)
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.accent.color)
        .focusedSceneValue(\.session, session)
        .navigationTitle(session.workspace?.name ?? "Dante")
        .onDisappear { session.shutdown() }
        .onAppear {
            let paths = AppDelegate.launchPaths
            AppDelegate.launchPaths = []
            if let folder = paths.first {
                session.open(folder: folder)
                for file in paths.dropFirst() { session.open(file: file) }
            }
        }
        .sheet(isPresented: $session.isCloning) {
            CloneSheet(session: session)
                .environment(\.theme, theme)
        }
        .sheet(isPresented: Binding(get: { session.setupProfile != nil && session.workspace != nil }, set: { if !$0 { session.setupProfile = nil } })) {
            if let profile = session.setupProfile, let workspace = session.workspace {
                SetupSheet(session: session, workspace: workspace, profile: profile)
                    .environment(\.theme, theme)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } }),
            presenting: session.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}

extension EnvironmentValues {
    @Entry var theme: Theme = .dark
}

extension FocusedValues {
    @Entry var session: Session?
}
