import AppKit
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
                    ResizeHandle(axis: .horizontal, value: $explorerWidth, range: 180...900)
                }
                VStack(spacing: 0) {
                    Group {
                        switch session.area {
                        case .code: EditorArea(session: session, workspace: workspace)
                        case .plan: PlanView(session: session, workspace: workspace)
                        case .home: HomeView(session: session, workspace: workspace)
                        case .docs: DocsView(session: session, workspace: workspace)
                        case .spec: SpecView(session: session, workspace: workspace)
                        case .tests: TestsView(session: session, workspace: workspace)
                        case .ship: ShipView(session: session, workspace: workspace)
                        case .environments: EnvironmentView(session: session, workspace: workspace)
                        case .data: DataView(session: session, workspace: workspace)
                        case .map: MapView(session: session, workspace: workspace)
                        case .run: RunView(session: session, workspace: workspace)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // The terminal stays alive when hidden so its shell keeps running.
                    VStack(spacing: 0) {
                        ResizeHandle(axis: .vertical, value: Bindable(session).terminalHeight, range: 120...1400, inverted: true)
                        TerminalPane(session: session, directory: workspace.url)
                    }
                    .frame(height: session.showsTerminal ? session.terminalHeight : 0)
                    .clipped()
                    .opacity(session.showsTerminal ? 1 : 0)
                    .allowsHitTesting(session.showsTerminal)

                    StatusBar(session: session, workspace: workspace)
                }
                if session.showsClaude, let claude = session.claude {
                    ResizeHandle(axis: .horizontal, value: Bindable(session).claudeWidth, range: 300...1400, inverted: true)
                    ClaudePanel(session: session, workspace: workspace, claude: claude)
                        .frame(width: session.claudeWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(theme.ground.color)
        .background(MouseNavigation(back: session.goBack, forward: session.goForward))
        .onChange(of: session.place) { previous, _ in session.placeChanged(from: previous) }
        // Git status feeds the Changes tab, the branch button and its sync arrows.
        .task(id: "\(workspace.revision)#\(session.gitRevision)") { await session.git.load(workspace.url) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            session.autoSaveOnFocusChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            session.autoSaveOnFocusChange()
        }
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
        .background(WindowEditedMarker(isEdited: session.hasUnsavedChanges))
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

/// Puts the standard "unsaved changes" dot in the window's close button.
private struct WindowEditedMarker: NSViewRepresentable {
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let isEdited = isEdited
        DispatchQueue.main.async { view.window?.isDocumentEdited = isEdited }
    }
}

/// The back and forward buttons on a mouse (buttons 3 and 4), for this window only.
private struct MouseNavigation: NSViewRepresentable {
    let back: @MainActor () -> Void
    let forward: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak coordinator] event in
            let button = event.buttonNumber
            guard button == 3 || button == 4 else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let coordinator, let window = coordinator.view?.window, window.isKeyWindow else { return false }
                if button == 3 { coordinator.back?() } else { coordinator.forward?() }
                return true
            }
            return handled ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.back = back
        context.coordinator.forward = forward
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var back: (@MainActor () -> Void)?
        var forward: (@MainActor () -> Void)?
        var monitor: Any?
    }
}
