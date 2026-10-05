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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A folder passed on the command line (`Dante path/to/project`), opened by the first window.
    @MainActor static var launchFolder: URL? = CommandLine.arguments.dropFirst()
        .first { !$0.hasPrefix("-") }
        .map { URL(filePath: $0, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath)).standardizedFileURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare executable (`swift run`) rather than the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
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
        .onAppear {
            if let folder = AppDelegate.launchFolder {
                AppDelegate.launchFolder = nil
                session.open(folder: folder)
            }
        }
        .sheet(isPresented: $session.isCloning) {
            CloneSheet(session: session)
                .environment(\.theme, theme)
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
