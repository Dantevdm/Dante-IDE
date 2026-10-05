import DanteKit
import SwiftUI

struct WorkspaceView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var explorerWidth: Double = 248

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(session: session, workspace: workspace)
            HStack(spacing: 0) {
                Rail(session: session)
                if session.area == .code {
                    ExplorerView(session: session, workspace: workspace)
                        .frame(width: explorerWidth)
                    ResizeHandle(axis: .horizontal, value: $explorerWidth, range: 180...480)
                }
                VStack(spacing: 0) {
                    Group {
                        switch session.area {
                        case .code: EditorArea(session: session, workspace: workspace)
                        case .plan: PlanView(session: session, workspace: workspace)
                        default: PlaceholderView(area: session.area)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // The terminal stays alive when hidden so its shell keeps running.
                    VStack(spacing: 0) {
                        ResizeHandle(axis: .vertical, value: Bindable(session).terminalHeight, range: 120...600, inverted: true)
                        TerminalPane(directory: workspace.url, input: session.terminalInput, onBranchMayHaveChanged: session.refreshBranch)
                    }
                    .frame(height: session.showsTerminal ? session.terminalHeight : 0)
                    .clipped()
                    .opacity(session.showsTerminal ? 1 : 0)
                    .allowsHitTesting(session.showsTerminal)

                    StatusBar(session: session, workspace: workspace)
                }
                if session.showsClaude, let claude = session.claude {
                    ResizeHandle(axis: .horizontal, value: Bindable(session).claudeWidth, range: 300...640, inverted: true)
                    ClaudePanel(session: session, workspace: workspace, claude: claude)
                        .frame(width: session.claudeWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(theme.ground.color)
        .overlay {
            if let scope = session.palette {
                ZStack(alignment: .top) {
                    theme.scrim.color
                        .ignoresSafeArea()
                        .onTapGesture { session.palette = nil }
                    CommandPalette(session: session, workspace: workspace, scope: scope)
                        .padding(.top, 90)
                        .id(scope)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: session.palette)
    }
}

/// A thin draggable divider that resizes a neighbouring panel.
struct ResizeHandle: View {
    enum Axis { case horizontal, vertical }

    @Environment(\.theme) private var theme
    let axis: Axis
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// For panels below or right of the handle, dragging towards them shrinks them.
    var inverted = false
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || start != nil ? theme.accent.color.opacity(0.5) : theme.line.color)
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            .padding(axis == .horizontal ? .horizontal : .vertical, 3)
            .contentShape(Rectangle())
            .padding(axis == .horizontal ? .horizontal : .vertical, -3)
            .onHover { inside in
                hovering = inside
                if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        if start == nil { start = value }
                        let delta = axis == .horizontal ? drag.translation.width : drag.translation.height
                        value = min(range.upperBound, max(range.lowerBound, (start ?? value) + (inverted ? -delta : delta)))
                    }
                    .onEnded { _ in start = nil }
            )
            .zIndex(1)
    }
}
