import AppKit
import DanteKit
import Foundation
import Observation

/// One diagram open in Docs: the picture, what's selected, undo through the window's undo
/// manager, and saving. Every change is written back to the file half a second later, so
/// the repo always has what's on screen; a change made to the file elsewhere (an agent, a
/// pull) is read back in and can be undone like any other.
@MainActor @Observable
final class DiagramDocument {
    let url: URL
    let path: String
    private(set) var diagram: Diagram
    var selection: Set<String> = []
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var isSaved = true
    /// What this document last wrote or read, so its own saves don't count as outside changes.
    @ObservationIgnored private var onDisk: Data?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored weak var undoManager: UndoManager?
    /// The last change that may merge with the next (typing a title): its key and time.
    @ObservationIgnored private var lastCoalescing: (key: String, at: Date)?

    init(url: URL, path: String) {
        self.url = url
        self.path = path
        diagram = Diagram(title: Diagram.title(ofPath: path))
        read()
    }

    // MARK: Reading

    private func read() {
        do {
            let data = try Data(contentsOf: url)
            onDisk = data
            diagram = try Self.decode(data)
            loadError = nil
        } catch let failure as Diagram.Failure {
            loadError = failure.message
        } catch {
            loadError = "Couldn’t read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// The file, laid out if it has nodes without frames (an agent's draft).
    private static func decode(_ data: Data) throws -> Diagram {
        var diagram = try Diagram.decode(data)
        if diagram.nodes.contains(where: { $0.frame == nil }) { diagram.settle() }
        return diagram
    }

    /// Reads the file again if it changed outside the editor (and nothing here is waiting to be saved).
    func reloadIfChanged() {
        guard saveTask == nil, let data = try? Data(contentsOf: url), data != onDisk else { return }
        onDisk = data
        do {
            let fresh = try Self.decode(data)
            loadError = nil
            apply(fresh, name: "Change from Disk", saves: false)
            selection = selection.filter { fresh.node($0) != nil || fresh.link($0) != nil }
            // A layout Dante worked out goes back to the file.
            if fresh != (try? Diagram.decode(data)) { scheduleSave() }
        } catch let failure as Diagram.Failure {
            loadError = failure.message
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Changing

    /// Makes a change as one undoable step. With `coalescing`, quick changes with the same key
    /// (each letter of a title) undo together.
    func change(_ name: String, coalescing key: String? = nil, _ body: (inout Diagram) -> Void) {
        var copy = diagram
        body(&copy)
        guard copy != diagram else { return }
        if let key, let last = lastCoalescing, last.key == key, Date().timeIntervalSince(last.at) < 1.5 {
            diagram = copy
            lastCoalescing = (key, Date())
            scheduleSave()
            return
        }
        lastCoalescing = key.map { ($0, Date()) }
        apply(copy, name: name)
    }

    /// Shows a change while a drag is under way, without an undo step or a save.
    func preview(_ new: Diagram) {
        diagram = new
    }

    /// Ends a drag: one undo step back to where it started.
    func commit(from start: Diagram, name: String) {
        guard diagram != start else { return }
        let end = diagram
        diagram = start
        lastCoalescing = nil
        apply(end, name: name)
    }

    private func apply(_ new: Diagram, name: String, saves: Bool = true) {
        let old = diagram
        guard new != old else { return }
        diagram = new
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.lastCoalescing = nil
                document.apply(old, name: name)
                document.selection = document.selection.filter { old.node($0) != nil || old.link($0) != nil }
            }
        }
        undoManager?.setActionName(name)
        if saves { scheduleSave() }
    }

    // MARK: Saving

    private func scheduleSave() {
        isSaved = false
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes now (closing, exporting); does nothing when it's already saved.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard !isSaved || onDisk == nil else { return }
        do {
            let data = try diagram.encoded()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if data != onDisk { try data.write(to: url, options: .atomic) }
            onDisk = data
            isSaved = true
            saveError = nil
        } catch {
            saveError = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    // MARK: Creating

    /// Writes a new diagram file at a free path for `title` and returns its project path.
    static func create(_ diagram: Diagram, in workspace: Workspace) throws -> String {
        let path = Diagram.path(for: diagram.title, existing: Set(workspace.files))
        let url = workspace.url.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try diagram.encoded().write(to: url, options: .atomic)
        workspace.refreshFileIndex()
        return path
    }
}
