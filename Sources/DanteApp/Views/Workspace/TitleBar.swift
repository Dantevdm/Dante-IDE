import DanteKit
import SwiftUI

/// The workspace's own title bar. The window's system title bar is hidden, so this draws
/// everything above the content: project, branch and window-level actions.
struct TitleBar: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore
    let session: Session
    let workspace: Workspace

    static let height: CGFloat = 46
    /// Room for the traffic-light buttons, which macOS still draws over this bar.
    private static let trafficLightInset: CGFloat = 78

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    IconButton(symbol: "chevron.left", label: Shortcuts.shared.binding("back").map { "Back (\($0.display) or the mouse’s back button)" } ?? "Back (the mouse’s back button)", size: 11) { session.goBack() }
                        .disabled(!session.history.canGoBack)
                        .opacity(session.history.canGoBack ? 1 : 0.35)
                    IconButton(symbol: "chevron.right", label: Shortcuts.label("Forward", "forward"), size: 11) { session.goForward() }
                        .disabled(!session.history.canGoForward)
                        .opacity(session.history.canGoForward ? 1 : 0.35)
                }
                ProjectMenu(session: session, workspace: workspace)
                if let sync = session.remoteSync {
                    RemoteChip(session: session, sync: sync)
                }
                if let branch = session.git.status?.branch ?? session.branch {
                    BranchButton(session: session, branch: branch)
                }
                Spacer(minLength: 12)
                ThemeMenu()
                ClaudeToggle(session: session)
                IconButton(
                    symbol: session.showsTerminal ? "terminal.fill" : "terminal",
                    label: Shortcuts.label(session.showsTerminal ? "Hide terminal" : "Show terminal", "toggleTerminal")
                ) {
                    withAnimation(.snappy(duration: 0.22)) { session.showsTerminal.toggle() }
                }
            }
            .padding(.leading, Self.trafficLightInset)
            .padding(.trailing, 10)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(theme.panel.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
    }
}

private struct ProjectMenu: View {
    @Environment(\.theme) private var theme
    @Environment(RecentProjects.self) private var recents
    let session: Session
    let workspace: Workspace
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Open Folder…") { session.openFolderPanel() }
            Button("Clone Repository…") { session.isCloning = true }
            Button("Open Remote…") { session.showsOpenRemote = true }
            let others = recents.items.filter { $0.path != workspace.url.path }
            if !others.isEmpty {
                Section("Recent") {
                    ForEach(others) { project in
                        Button(project.name) { session.open(folder: project.url) }
                    }
                }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.url]) }
            Button("Close Project") { session.closeProject() }
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.accentTint.color)
                    .overlay(
                        Text(String(workspace.name.prefix(1)).uppercased())
                            .font(.dante(size: 11, weight: .bold))
                            .foregroundStyle(theme.accent.color)
                    )
                    .frame(width: 20, height: 20)
                Text(workspace.name)
                    .font(.dante(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text.color)
                Image(systemName: "chevron.down")
                    .font(.dante(size: 8.5, weight: .bold))
                    .foregroundStyle(theme.text3.color)
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(workspace.name)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? theme.raised.color : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Project")
    }
}

private struct ThemeMenu: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore
    @State private var hovering = false

    var body: some View {
        Menu {
            Picker("Theme", selection: Bindable(themeStore).id) {
                ForEach(ThemeID.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: symbol)
                .font(.dante(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(hovering ? theme.text.color : theme.text3.color)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.raised.color : .clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Theme (⌥⌘T to cycle)")
        .accessibilityLabel("Theme")
    }

    private var symbol: String {
        switch themeStore.id {
        case .dark: "moon"
        case .light: "sun.max"
        case .paper: "book"
        }
    }
}

/// Shows or hides the Claude panel; a dot marks changes waiting for review.
private struct ClaudeToggle: View {
    @Environment(\.theme) private var theme
    let session: Session

    var body: some View {
        IconButton(
            symbol: "sparkle",
            label: Shortcuts.label(session.showsClaude ? "Hide \(session.agentName)" : "Show \(session.agentName)", "toggleClaude")
        ) {
            withAnimation(.snappy(duration: 0.22)) { session.showsClaude.toggle() }
        }
        .overlay(alignment: .topTrailing) {
            if !session.inbox.isEmpty, !session.showsClaude {
                StatusDot(color: theme.amber.color, size: 6).offset(x: -3, y: 3)
            }
        }
    }
}

/// The host a remote project lives on, and how its copy here is keeping up. Click to sync now.
private struct RemoteChip: View {
    @Environment(\.theme) private var theme
    let session: Session
    let sync: RemoteSync
    @State private var hovering = false

    var body: some View {
        Button { session.syncRemoteNow() } label: {
            HStack(spacing: 5) {
                Group {
                    switch sync.state {
                    case .syncing: Image(systemName: "arrow.triangle.2.circlepath")
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.amber.color)
                    case .idle: Image(systemName: "network")
                    }
                }
                .font(.dante(size: 10.5, weight: .medium))
                Text(sync.project.host)
                    .font(.dante(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(theme.text2.color)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.raised.color : theme.raised.opacity(0.5).color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var help: String {
        var lines = ["\(sync.project.label), copied to this Mac. Click to sync now."]
        switch sync.state {
        case .failed(let message): lines.append("Last sync failed: \(message)")
        case .syncing: lines.append("Syncing…")
        case .idle: if let date = sync.lastSynced { lines.append("Synced \(date.formatted(date: .omitted, time: .standard)).") }
        }
        if sync.heldDeletions > 0 {
            lines.append("\(sync.heldDeletions) files deleted here at once weren’t deleted on the host, in case that was a mistake; they were copied back.")
        }
        return lines.joined(separator: "\n")
    }
}
