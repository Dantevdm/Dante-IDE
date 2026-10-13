import DanteKit
import Foundation

/// The debugger: breakpoints per file, and the run in progress.
extension Session {
    private static let breakpointsKey = "breakpoints"

    /// 1-based breakpoint lines in a file.
    func breakpointLines(in url: URL) -> Set<Int> {
        breakpoints[url.standardizedFileURL.path] ?? []
    }

    func toggleBreakpoint(in url: URL, line: Int) {
        let path = url.standardizedFileURL.path
        var lines = breakpoints[path] ?? []
        if lines.contains(line) { lines.remove(line) } else { lines.insert(line) }
        breakpoints[path] = lines.isEmpty ? nil : lines
        saveBreakpoints()
        if let debug, debug.state != .ended {
            Task { await debug.setBreakpoints(path, lines: Array(lines)) }
        }
    }

    /// F9: a breakpoint on the caret's line.
    func toggleBreakpointAtCursor() {
        guard let document = workspace?.activeDocument, document.kind.opensAsText else { return }
        toggleBreakpoint(in: document.url, line: cursor.line)
    }

    func removeAllBreakpoints() {
        let paths = Array(breakpoints.keys)
        breakpoints = [:]
        saveBreakpoints()
        if let debug, debug.state != .ended {
            Task { for path in paths { await debug.setBreakpoints(path, lines: []) } }
        }
    }

    /// The zero-based line the debugger is stopped on in this file, if it is.
    func executionLine(in document: EditorDocument) -> Int? {
        guard let debug, debug.state == .stopped, let frame = debug.selectedFrame, let path = frame.path,
              path == DebugSession.canonical(document.url.path) else { return nil }
        return frame.line - 1
    }

    var canDebugActiveFile: Bool {
        guard let document = workspace?.activeDocument else { return false }
        return DebugAdapter.for(file: document.url.path) != nil
    }

    /// Starts debugging the open file (its package, for Go), or continues when stopped.
    func startDebugging() {
        if let debug, debug.state == .stopped { debug.resume(); return }
        guard let workspace, let document = workspace.activeDocument else { return }
        guard let adapter = DebugAdapter.for(file: document.url.path) else {
            errorMessage = "Dante can debug Go and Python files. Open one and start again."
            return
        }
        // The program runs from disk, so unsaved edits go first.
        for open in workspace.documents where open.isDirty { save(open, tidy: false) }
        if let old = debug, old.state != .ended { Task { await old.stop() } }

        let session = DebugSession(adapter: adapter, file: document.url.path)
        session.onStopped = { [weak self] frame in self?.reveal(frame) }
        debug = session
        sidebar = .debug
        let points = breakpoints.mapValues { Array($0) }
        let root = workspace.url
        Task { await session.start(root: root, environment: Shell.environment(), breakpoints: points) }
    }

    func stopDebugging() {
        guard let debug, debug.state != .ended else { return }
        Task { await debug.stop() }
    }

    /// Opens the frame's file at its line, when it's in the project.
    func reveal(_ frame: DebugSession.Frame?) {
        guard let frame, let path = frame.path, let url = projectURL(forDebuggerPath: path) else { return }
        open(file: url, line: frame.line)
    }

    /// A path the adapter reported (symlinks resolved) as the project's own URL for it.
    func projectURL(forDebuggerPath path: String) -> URL? {
        guard let root = workspace?.url else { return nil }
        let canonicalRoot = DebugSession.canonical(root.path)
        if path.hasPrefix(canonicalRoot + "/") {
            return root.appending(path: String(path.dropFirst(canonicalRoot.count + 1)))
        }
        if path.hasPrefix(root.path + "/") { return URL(filePath: path) }
        return nil
    }

    // MARK: Saved per project, on this Mac

    func loadBreakpoints() {
        guard let root = workspace?.url.standardizedFileURL else { breakpoints = [:]; return }
        let saved = UserDefaults.standard.dictionary(forKey: Self.breakpointsKey)?[root.path] as? [String: [Int]] ?? [:]
        breakpoints = Dictionary(uniqueKeysWithValues: saved.map { (root.appending(path: $0.key).standardizedFileURL.path, Set($0.value)) })
    }

    private func saveBreakpoints() {
        guard let root = workspace?.url.standardizedFileURL else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.breakpointsKey) ?? [:]
        let prefix = root.path + "/"
        let relative = Dictionary(uniqueKeysWithValues: breakpoints.compactMap { path, lines -> (String, [Int])? in
            path.hasPrefix(prefix) ? (String(path.dropFirst(prefix.count)), lines.sorted()) : nil
        })
        all[root.path] = relative.isEmpty ? nil : relative
        UserDefaults.standard.set(all, forKey: Self.breakpointsKey)
    }
}
