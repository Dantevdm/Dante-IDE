import DanteKit
import SwiftUI

/// The workspace's own title bar. The window's system title bar is hidden, so this draws
/// everything above the content: project, lifecycle ribbon and window-level actions.
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
            // Ribbon centred on the window, not on the space left between the side groups.
            PhaseRibbon(lifecycle: workspace.lifecycle)

            HStack(spacing: 6) {
                ProjectMenu(session: session, workspace: workspace)
                Spacer(minLength: 12)
                ThemeMenu()
                ClaudeToggle(session: session)
                IconButton(
                    symbol: session.showsTerminal ? "terminal.fill" : "terminal",
                    label: session.showsTerminal ? "Hide terminal (⌃`)" : "Show terminal (⌃`)"
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
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.accent.color)
                    )
                    .frame(width: 20, height: 20)
                Text(workspace.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text.color)
                if let branch = session.branch {
                    Text("/").foregroundStyle(theme.text3.color.opacity(0.6))
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.text3.color)
                    Text(branch)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.text2.color)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(theme.text3.color)
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.branch.map { "\(workspace.name), branch \($0)" } ?? workspace.name)
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
                .font(.system(size: 13, weight: .medium))
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
            label: session.showsClaude ? "Hide Claude (⌥⌘L)" : "Show Claude (⌥⌘L)"
        ) {
            withAnimation(.snappy(duration: 0.22)) { session.showsClaude.toggle() }
        }
        .overlay(alignment: .topTrailing) {
            if session.claude?.pendingApprovals.isEmpty == false, !session.showsClaude {
                StatusDot(color: theme.amber.color, size: 6).offset(x: -3, y: 3)
            }
        }
    }
}
