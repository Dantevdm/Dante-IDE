import AppKit
import DanteKit
@preconcurrency import SwiftTerm
import SwiftUI

/// The integrated terminal: the user's login shell, started in the project folder.
struct TerminalPane: View {
    @Environment(\.theme) private var theme
    let directory: URL
    var input: TerminalInput?
    var onBranchMayHaveChanged: () -> Void = {}

    @State private var title = "zsh"
    @State private var generation = 0
    @State private var exited: Int32?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label(title, systemImage: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.raised.color))
                if let exited {
                    Text("exited (\(exited))").font(.system(size: 12)).foregroundStyle(theme.text3.color)
                }
                Spacer()
                IconButton(symbol: "arrow.counterclockwise", label: "Restart shell", size: 11) {
                    exited = nil
                    generation += 1
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }

            TerminalHost(directory: directory, theme: theme, input: input) { newTitle in
                title = newTitle
            } onDirectoryChange: {
                onBranchMayHaveChanged()
            } onExit: { code in
                exited = code
            }
            .id(generation)
            .padding(.leading, 10)
            .padding(.top, 6)
        }
        .background(theme.panel.color)
    }
}

private struct TerminalHost: NSViewRepresentable {
    let directory: URL
    let theme: Theme
    let input: TerminalInput?
    let onTitle: (String) -> Void
    let onDirectoryChange: () -> Void
    let onExit: (Int32?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.processDelegate = context.coordinator
        view.optionAsMetaKey = true
        apply(theme, to: view)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        environment.append("TERM_PROGRAM=Dante")
        if let path = ProcessInfo.processInfo.environment["PATH"] { environment.append("PATH=\(path)") }
        environment.append("HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)")
        if let lang = ProcessInfo.processInfo.environment["LANG"] { environment.append("LANG=\(lang)") } else { environment.append("LANG=en_US.UTF-8") }
        if let user = ProcessInfo.processInfo.environment["USER"] { environment.append("USER=\(user)") }
        view.startProcess(
            executable: shell,
            args: ["-l"],
            environment: environment,
            execName: "-" + shellName,
            currentDirectory: directory.path
        )
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.appliedTheme != theme {
            apply(theme, to: view)
            context.coordinator.appliedTheme = theme
        }
        if let input, input.id != context.coordinator.sentInputID {
            context.coordinator.sentInputID = input.id
            view.send(txt: input.text)
            view.window?.makeFirstResponder(view)
        }
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        view.process?.terminate()
    }

    private func apply(_ theme: Theme, to view: LocalProcessTerminalView) {
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = theme.panel.nsColor
        view.nativeForegroundColor = theme.text.nsColor
        view.caretColor = theme.accent.nsColor
        view.selectedTextBackgroundColor = theme.accent.opacity(0.3).nsColor
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TerminalHost
        var appliedTheme: Theme?
        var sentInputID: UUID?

        init(_ parent: TerminalHost) {
            self.parent = parent
            appliedTheme = parent.theme
            // Input queued before this terminal existed was meant for a previous shell.
            sentInputID = parent.input?.id
        }
    }
}

extension TerminalHost.Coordinator: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { parent.onTitle(trimmed) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        parent.onDirectoryChange()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        parent.onExit(exitCode)
    }
}
