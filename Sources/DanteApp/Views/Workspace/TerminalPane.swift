import AppKit
import DanteEditor
import DanteKit
@preconcurrency import SwiftTerm
import SwiftUI

/// The integrated terminal: tabs of the user's login shell, started in the project folder.
/// Hidden tabs keep running.
struct TerminalPane: View {
    @Environment(\.theme) private var theme
    let session: Session
    let directory: URL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(session.terminalTabs) { tab in
                            TerminalTabButton(
                                tab: tab,
                                isSelected: tab.id == session.selectedTerminal,
                                canClose: session.terminalTabs.count > 1,
                                select: { session.selectedTerminal = tab.id },
                                close: { session.closeTerminal(tab.id) }
                            )
                        }
                    }
                }
                IconButton(symbol: "plus", label: "New terminal (⌃⇧`)", size: 11) { session.newTerminal() }
                Spacer(minLength: 8)
                IconButton(symbol: "arrow.counterclockwise", label: "Restart this shell", size: 11) {
                    update(session.selectedTerminal) {
                        $0.exitCode = nil
                        $0.generation += 1
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }

            ZStack {
                ForEach(session.terminalTabs) { tab in
                    let selected = tab.id == session.selectedTerminal
                    TerminalHost(directory: directory, theme: theme, tab: tab.id, isSelected: selected, input: session.terminalInput) { title in
                        update(tab.id) { $0.title = title }
                    } onDirectoryChange: {
                        session.refreshBranch()
                    } onExit: { code in
                        update(tab.id) { $0.exitCode = .some(code) }
                    }
                    .id("\(tab.id)-\(tab.generation)")
                    .opacity(selected ? 1 : 0)
                    .allowsHitTesting(selected)
                }
            }
            .padding(.leading, 10)
            .padding(.top, 6)
        }
        .background(theme.panel.color)
    }

    private func update(_ id: UUID, _ change: (inout TerminalTab) -> Void) {
        guard let index = session.terminalTabs.firstIndex(where: { $0.id == id }) else { return }
        change(&session.terminalTabs[index])
    }
}

private struct TerminalTabButton: View {
    @Environment(\.theme) private var theme
    let tab: TerminalTab
    let isSelected: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "terminal").font(.dante(size: 10.5))
            Text(tab.title).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            if let code = tab.exitCode {
                Text(code.map { "exited \($0)" } ?? "exited").foregroundStyle(theme.text3.color)
            }
            if canClose {
                Button(action: close) {
                    Image(systemName: "xmark").font(.dante(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .foregroundStyle(theme.text3.color)
                        .opacity(hovering || isSelected ? 1 : 0)
                }
                .buttonStyle(.plain)
                .help("Close this shell")
            }
        }
        .font(.dante(size: 12))
        .foregroundStyle(isSelected ? theme.text.color : theme.text2.color)
        .padding(.leading, 9)
        .padding(.trailing, canClose ? 5 : 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? theme.raised.color : (hovering ? theme.raised.opacity(0.5).color : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let directory: URL
    let theme: Theme
    let tab: UUID
    let isSelected: Bool
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
        if context.coordinator.appliedTheme != theme || context.coordinator.appliedGeist != DanteFonts.usesGeist {
            apply(theme, to: view)
            context.coordinator.appliedTheme = theme
            context.coordinator.appliedGeist = DanteFonts.usesGeist
        }
        if let input, input.id != context.coordinator.sentInputID {
            context.coordinator.sentInputID = input.id
            if input.tab == tab {
                view.send(txt: input.text)
                view.window?.makeFirstResponder(view)
            }
        }
        if isSelected, !context.coordinator.wasSelected {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        context.coordinator.wasSelected = isSelected
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        view.process?.terminate()
    }

    private func apply(_ theme: Theme, to view: LocalProcessTerminalView) {
        view.font = DanteFonts.mono(size: 12.5)
        view.nativeBackgroundColor = theme.panel.nsColor
        view.nativeForegroundColor = theme.text.nsColor
        view.caretColor = theme.accent.nsColor
        view.selectedTextBackgroundColor = theme.accent.opacity(0.3).nsColor
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TerminalHost
        var appliedTheme: Theme?
        var appliedGeist: Bool?
        var sentInputID: UUID?
        var wasSelected = true

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
