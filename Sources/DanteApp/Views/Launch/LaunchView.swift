import DanteKit
import SwiftUI

/// The first thing you see: the animated mark, ways to start, and recent projects.
struct LaunchView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(RecentProjects.self) private var recents
    let session: Session

    @State private var drawn = false
    @State private var status = SystemStatus()

    private static let ease = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.8)

    var body: some View {
        ZStack {
            theme.ground.color
            DotGrid(color: theme.line.color)

            HStack(spacing: 0) {
                brand
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                start
                    .frame(width: 420)
                    .frame(maxHeight: .infinity)
                    .background(theme.panel.color)
                    .overlay(alignment: .leading) { Rectangle().fill(theme.line.color).frame(width: 1) }
                    .opacity(drawn ? 1 : 0)
                    .offset(x: drawn || reduceMotion ? 0 : 28)
                    .animation(reduceMotion ? nil : Self.ease.delay(1.6), value: drawn)
            }
            .frame(maxWidth: 1060, maxHeight: 600)
            .background(theme.card.color.opacity(theme.isDark ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.line.color))
            .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.12), radius: 50, y: 30)
            .padding(40)
        }
        .ignoresSafeArea()
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task {
            recents.prune()
            drawn = true
            status = await Task.detached { SystemStatus.detect() }.value
        }
    }

    // MARK: Left: the mark

    private var brand: some View {
        VStack(spacing: 26) {
            PhaseRing(drawn: drawn)
                .onTapGesture { replay() }
                .help("Replay")

            VStack(spacing: 10) {
                Text("Dante")
                    .font(.dante(size: 44, weight: .semibold))
                    .tracking(drawn || reduceMotion ? -1.3 : 15)
                    .blur(radius: drawn || reduceMotion ? 0 : 6)
                    .opacity(drawn ? 1 : 0)
                    .animation(reduceMotion ? nil : .timingCurve(0.2, 0.7, 0.2, 1, duration: 1).delay(1.05), value: drawn)
                Text("The whole lifecycle, in one window.")
                    .font(.dante(size: 15))
                    .foregroundStyle(theme.text2.color)
                    .opacity(drawn ? 1 : 0)
                    .offset(y: drawn || reduceMotion ? 0 : 10)
                    .animation(reduceMotion ? nil : Self.ease.delay(1.35), value: drawn)
            }

            HStack(spacing: 14) {
                ForEach(Array(Lifecycle.defaultPhases.enumerated()), id: \.offset) { index, phase in
                    Text(phase.uppercased())
                        .font(.dante(size: 10.5, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(theme.text3.color)
                        .opacity(drawn ? 1 : 0)
                        .offset(y: drawn || reduceMotion ? 0 : 8)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.25 + Double(index) * 0.11), value: drawn)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Lifecycle phases: " + Lifecycle.defaultPhases.joined(separator: ", "))
        }
        .padding(40)
    }

    private func replay() {
        guard !reduceMotion else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drawn = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drawn = true }
    }

    // MARK: Right: start

    private var start: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Start")
                StartAction(symbol: "plus", title: "New project", subtitle: "Create a folder and start in Discover", shortcut: "⌘N") {
                    session.newProject()
                }
                StartAction(symbol: "folder", title: "Open folder", subtitle: "Any project, with or without .dante/", shortcut: "⌘O") {
                    session.openFolderPanel()
                }
                StartAction(symbol: "arrow.triangle.branch", title: "Clone repository", subtitle: "From GitHub or any Git URL", shortcut: "⇧⌘C") {
                    session.isCloning = true
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Recent")
                if recents.items.isEmpty {
                    Text("Projects you open appear here.")
                        .font(.dante(size: 12.5))
                        .foregroundStyle(theme.text3.color)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(recents.items) { project in
                                RecentRow(project: project) { session.open(folder: project.url) }
                                    .contextMenu {
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                                        Button("Remove from Recents") { recents.remove(project) }
                                    }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                statusItem(status.claudePath != nil, on: "Claude Code found", off: "Claude Code not found")
                statusItem(status.dockerRunning, on: "Docker running", off: "Docker not running")
                Spacer()
                Text("v0.1")
                    .font(.dante(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.text3.color)
            }
            .padding(.top, 14)
            .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 36)
    }

    private func statusItem(_ ok: Bool, on: String, off: String) -> some View {
        HStack(spacing: 6) {
            StatusDot(color: ok ? theme.green.color : theme.text3.color, size: 6)
            Text(ok ? on : off)
        }
        .font(.dante(size: 12))
        .foregroundStyle(theme.text3.color)
    }
}

private struct StartAction: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let title: String
    let subtitle: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.dante(size: 15, weight: .medium))
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.raised.color))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line2.color))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                    Text(subtitle).font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                Spacer()
                Text(shortcut).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? theme.raised.color : theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovering ? theme.line2.color : theme.line.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RecentRow: View {
    @Environment(\.theme) private var theme
    let project: RecentProject
    let action: () -> Void
    @State private var hovering = false
    @State private var lifecycle = Lifecycle()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                    Text(project.displayPath)
                        .font(.dante(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.text3.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(lifecycle.currentIndex.map { lifecycle.phases[$0] } ?? (lifecycle.hasSpec ? "" : "No spec yet"))
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.text2.color)
                    PhaseDots(lifecycle: lifecycle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? theme.raised.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: project.path) { lifecycle = Lifecycle.load(projectRoot: project.url) }
    }
}
