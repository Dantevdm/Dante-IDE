import DanteKit
import SwiftUI

/// The sidebar's Debug tab: start and step controls, where the program is stopped, its
/// variables, the breakpoints, and a console for output and expressions.
struct DebugPanel: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var expression = ""
    @State private var expanded: Set<Int> = []

    private var debug: DebugSession? { session.debug }
    private var running: Bool { debug.map { $0.state != .ended } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Rectangle().fill(theme.line.color).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let debug, debug.state == .stopped {
                        section("Call Stack") { callStack(debug) }
                        section("Variables") { variables(debug) }
                    }
                    section("Breakpoints", trailing: session.breakpoints.isEmpty ? nil : AnyView(
                        IconButton(symbol: "trash", label: "Remove all breakpoints", size: 10) { session.removeAllBreakpoints() }
                    )) { breakpointList }
                }
                .padding(.bottom, 8)
            }
            if let debug, !debug.output.isEmpty || running {
                Rectangle().fill(theme.line.color).frame(height: 1)
                console(debug)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let debug, debug.state != .ended {
                HStack(spacing: 2) {
                    if debug.state == .stopped {
                        control("play.fill", "Continue", "debugContinue") { debug.resume() }
                    } else {
                        control("pause.fill", "Pause", nil) { debug.pause() }.disabled(debug.state != .running)
                    }
                    control("arrow.turn.down.right", "Step Over", "debugStepOver") { debug.stepOver() }.disabled(debug.state != .stopped)
                    control("arrow.down.to.line", "Step Into", "debugStepIn") { debug.stepIn() }.disabled(debug.state != .stopped)
                    control("arrow.up.to.line", "Step Out", "debugStepOut") { debug.stepOut() }.disabled(debug.state != .stopped)
                    Spacer()
                    control("stop.fill", "Stop", "debugStop") { session.stopDebugging() }
                }
                status(debug)
            } else {
                let file = workspace.activeDocument
                let adapter = session.remoteSync == nil ? file.flatMap { DebugAdapter.for(file: $0.url.path) } : nil
                Button {
                    session.startDebugging()
                } label: {
                    Label(adapter.map { _ in "Debug \(file?.url.lastPathComponent ?? "")" } ?? "Debug", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(adapter == nil)
                .help(Shortcuts.label("Start Debugging", "debugStart"))
                Text(hint(adapter: adapter, file: file))
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.text3.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = debug?.failure {
                    Text(failure)
                        .font(.dante(size: 11.5))
                        .foregroundStyle(theme.red.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let adapter = debug?.adapter, failure.contains(adapter.install) {
                        Button("Install…") { session.typeInTerminal(adapter.install) }
                            .buttonStyle(DanteButtonStyle())
                            .help(adapter.install)
                    }
                }
            }
        }
        .padding(10)
    }

    private func hint(adapter: DebugAdapter?, file: EditorDocument?) -> String {
        if session.remoteSync != nil { return "The debugger runs programs on this Mac, so it isn’t available for remote projects yet." }
        guard let file else { return "Open a Go or Python file to debug it." }
        guard let adapter else { return "Dante debugs Go (with Delve) and Python (with debugpy). \(file.url.lastPathComponent) isn’t either." }
        let what = adapter.id == "go" ? (file.url.lastPathComponent.hasSuffix("_test.go") ? "this package’s tests" : "this file’s package") : "this file"
        return "Runs \(what) with \(adapter.name). Click a line number to stop there."
    }

    private func control(_ symbol: String, _ title: String, _ shortcut: String?, action: @escaping () -> Void) -> some View {
        IconButton(symbol: symbol, label: shortcut.map { Shortcuts.label(title, $0) } ?? title, size: 12, action: action)
    }

    private func status(_ debug: DebugSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(debug.state == .stopped ? theme.amber.color : (debug.state == .running ? theme.green.color : theme.text3.color))
                .frame(width: 7, height: 7)
            Text(statusText(debug))
                .font(.dante(size: 11.5))
                .foregroundStyle(theme.text2.color)
                .lineLimit(2)
        }
    }

    private func statusText(_ debug: DebugSession) -> String {
        switch debug.state {
        case .starting: return "Starting \(debug.adapter.name)…"
        case .running: return "Running \((debug.file as NSString).lastPathComponent)"
        case .ended: return "Ended"
        case .stopped:
            let place = debug.selectedFrame.map { "\(($0.path.map { ($0 as NSString).lastPathComponent }) ?? $0.name):\($0.line)" } ?? ""
            let reason = debug.stopDescription ?? debug.stopReason.map { $0 == "breakpoint" ? "breakpoint" : $0 } ?? "paused"
            return "Paused at \(place) · \(reason)"
        }
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title.uppercased())
                    .font(.dante(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(theme.text3.color)
                Spacer()
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 2)
            content()
        }
    }

    private func callStack(_ debug: DebugSession) -> some View {
        ForEach(debug.frames) { frame in
            let selected = frame.id == debug.selectedFrameID
            Button {
                debug.select(frame: frame.id)
                session.reveal(frame)
            } label: {
                HStack(spacing: 6) {
                    Text(frame.name)
                        .font(.dante(size: 12, design: .monospaced))
                        .foregroundStyle(frame.path.flatMap(session.projectURL(forDebuggerPath:)) == nil ? theme.text3.color : theme.text.color)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    if let path = frame.path {
                        Text("\((path as NSString).lastPathComponent):\(frame.line)")
                            .font(.dante(size: 10.5))
                            .foregroundStyle(theme.text3.color)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background(selected ? theme.accentTint.color : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func variables(_ debug: DebugSession) -> some View {
        ForEach(debug.scopes) { scope in
            if debug.scopes.count > 1 {
                Text(scope.name)
                    .font(.dante(size: 11, weight: .medium))
                    .foregroundStyle(theme.text2.color)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            if let children = debug.children[scope.reference] {
                if children.isEmpty {
                    Text("None").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).padding(.horizontal, 12)
                }
                ForEach(children) { variable in VariableRow(debug: debug, variable: variable, depth: 0, expanded: $expanded) }
            } else if scope.expensive {
                Button("Load \(scope.name)") { Task { await debug.loadChildren(scope.reference) } }
                    .buttonStyle(.plain)
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.accent.color)
                    .padding(.horizontal, 12)
            } else {
                ProgressView().controlSize(.mini).padding(.horizontal, 12)
            }
        }
    }

    private struct Entry: Identifiable {
        var path: String
        var line: Int
        var id: String { "\(path):\(line)" }
    }

    private static func entries(_ breakpoints: [String: Set<Int>]) -> [Entry] {
        var entries: [Entry] = []
        for (path, lines) in breakpoints {
            for line in lines { entries.append(Entry(path: path, line: line)) }
        }
        return entries.sorted { a, b in a.path == b.path ? a.line < b.line : a.path < b.path }
    }

    private var breakpointList: some View {
        let entries = Self.entries(session.breakpoints)
        return VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text("Click a line number in the editor to add one.")
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.text3.color)
                    .padding(.horizontal, 12)
            }
            ForEach(entries) { entry in breakpointRow(entry) }
        }
    }

    private func breakpointRow(_ entry: Entry) -> some View {
        let verified: Bool? = debug?.verified[DebugSession.canonical(entry.path)]?[entry.line]
        let url = URL(filePath: entry.path)
        return HStack(spacing: 6) {
            Image(systemName: verified == false ? "circle.dashed" : "circle.fill")
                .font(.dante(size: 8))
                .foregroundStyle(theme.accent.color)
                .help(verified == false ? "The debugger couldn’t place this breakpoint" : "")
            Button {
                session.open(file: url, line: entry.line)
            } label: {
                HStack(spacing: 4) {
                    Text(url.lastPathComponent).font(.dante(size: 12)).foregroundStyle(theme.text.color)
                    Text("line \(entry.line)").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            IconButton(symbol: "xmark", label: "Remove breakpoint", size: 9) {
                session.toggleBreakpoint(in: url, line: entry.line)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
    }

    // MARK: Console

    private func console(_ debug: DebugSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONSOLE")
                    .font(.dante(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(theme.text3.color)
                Spacer()
                IconButton(symbol: "trash", label: "Clear console", size: 10) { debug.clearOutput() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(debug.output) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.dante(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line.category))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onChange(of: debug.output.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .frame(minHeight: 80, maxHeight: 200)
            if debug.state == .stopped {
                TextField("Evaluate…", text: $expression)
                    .textFieldStyle(.plain)
                    .font(.dante(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.raised.color))
                    .padding(8)
                    .onSubmit {
                        let text = expression
                        expression = ""
                        Task { await debug.evaluate(text) }
                    }
            }
        }
    }

    private func color(for category: String) -> Color {
        switch category {
        case "stderr": theme.red.color
        case "console": theme.text3.color
        case "input": theme.accent.color
        case "result": theme.green.color
        default: theme.text.color
        }
    }
}

/// A variable, with its children when expanded.
private struct VariableRow: View {
    @Environment(\.theme) private var theme
    let debug: DebugSession
    let variable: DebugSession.Variable
    let depth: Int
    @Binding var expanded: Set<Int>

    var body: some View {
        let isOpen = variable.reference > 0 && expanded.contains(variable.reference)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.dante(size: 8, weight: .bold))
                    .foregroundStyle(theme.text3.color)
                    .frame(width: 10)
                    .opacity(variable.reference > 0 ? 1 : 0)
                Text(variable.name)
                    .font(.dante(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.syntax.function.color)
                    .lineLimit(1)
                Text(variable.value)
                    .font(.dante(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(variable.type.map { "\($0): \(variable.value)" } ?? variable.value)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12 + CGFloat(depth) * 12)
            .padding(.trailing, 8)
            .frame(height: 20)
            .contentShape(Rectangle())
            .onTapGesture {
                guard variable.reference > 0 else { return }
                if isOpen {
                    expanded.remove(variable.reference)
                } else {
                    expanded.insert(variable.reference)
                    Task { await debug.loadChildren(variable.reference) }
                }
            }
            if isOpen, depth < 8 {
                ForEach(debug.children[variable.reference] ?? []) { child in
                    VariableRow(debug: debug, variable: child, depth: depth + 1, expanded: $expanded)
                }
            }
        }
    }
}
