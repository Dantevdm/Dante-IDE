import AppKit
import DanteKit
import Foundation
import Observation

/// One mind map open in Docs: the map, the sheet and topic chosen, undo through the window's
/// undo manager, and saving. Like a diagram, every change is written back half a second later
/// (atomically, as an XMind file), and a change made to the file elsewhere (XMind, an agent,
/// a pull) is read back in.
@MainActor @Observable
final class MindMapDocument {
    let url: URL
    let path: String
    private(set) var map: MindMap
    var sheet = 0
    var selected: String?
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var isSaved = true
    @ObservationIgnored private var onDisk: Data?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var lastCoalescing: (key: String, at: Date)?

    init(url: URL, path: String) {
        self.url = url
        self.path = path
        map = MindMap(title: MindMap.title(ofPath: path))
        read()
        selected = root.id
    }

    var root: MindMap.Topic {
        map.sheets.indices.contains(sheet) ? map.sheets[sheet].root : MindMap.Topic(title: "")
    }

    var selectedTopic: MindMap.Topic? { selected.flatMap { root.find($0) } }

    private func read() {
        do {
            let data = try Data(contentsOf: url)
            onDisk = data
            map = try MindMap.read(data)
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Couldn’t read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func reloadIfChanged() {
        guard saveTask == nil, let data = try? Data(contentsOf: url), data != onDisk else { return }
        onDisk = data
        do {
            let fresh = try MindMap.read(data)
            loadError = nil
            apply(fresh, name: "Change from Disk", saves: false)
            if sheet >= fresh.sheets.count { sheet = 0 }
            if let selected, root.find(selected) == nil { self.selected = root.id }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Changing

    /// Changes the shown sheet's tree as one undoable step; with `coalescing`, quick changes
    /// with the same key (each letter of a title) undo together.
    func change(_ name: String, coalescing key: String? = nil, _ body: (inout MindMap.Topic) -> Void) {
        guard map.sheets.indices.contains(sheet) else { return }
        var copy = map
        body(&copy.sheets[sheet].root)
        guard copy != map else { return }
        if let key, let last = lastCoalescing, last.key == key, Date().timeIntervalSince(last.at) < 1.5 {
            map = copy
            lastCoalescing = (key, Date())
            scheduleSave()
            return
        }
        lastCoalescing = key.map { ($0, Date()) }
        apply(copy, name: name)
    }

    func changeMap(_ name: String, _ body: (inout MindMap) -> Void) {
        var copy = map
        body(&copy)
        lastCoalescing = nil
        apply(copy, name: name)
    }

    private func apply(_ new: MindMap, name: String, saves: Bool = true) {
        let old = map
        guard new != old else { return }
        map = new
        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.lastCoalescing = nil
                document.apply(old, name: name)
                if document.sheet >= old.sheets.count { document.sheet = 0 }
                if let selected = document.selected, document.root.find(selected) == nil { document.selected = document.root.id }
            }
        }
        undoManager?.setActionName(name)
        if saves { scheduleSave() }
    }

    // MARK: The usual edits

    /// A new topic under the selected one; returns its id so the view can start editing it.
    @discardableResult
    func addChild() -> String? {
        guard let parent = selected ?? Optional(root.id) else { return nil }
        let topic = MindMap.Topic(title: parent == root.id ? "Main topic" : "Subtopic")
        change("Add Topic") { $0.add(topic, under: parent) }
        selected = topic.id
        return topic.id
    }

    /// A new topic after the selected one (a child when the central topic is selected).
    @discardableResult
    func addSibling() -> String? {
        guard let selected, selected != root.id else { return addChild() }
        let topic = MindMap.Topic(title: root.parent(of: selected)?.id == root.id ? "Main topic" : "Subtopic")
        change("Add Topic") { $0.add(topic, after: selected) }
        self.selected = topic.id
        return topic.id
    }

    func deleteSelected() {
        guard let selected, selected != root.id else { return }
        let parent = root.parent(of: selected)
        let siblings = parent?.children ?? []
        let index = siblings.firstIndex { $0.id == selected } ?? 0
        change("Delete Topic") { $0.remove(selected) }
        // The next sibling, else the previous, else the parent.
        let left = root.find(parent?.id ?? root.id)?.children ?? []
        self.selected = left.indices.contains(index) ? left[index].id : left.last?.id ?? parent?.id ?? root.id
    }

    func toggleFold(_ id: String? = nil) {
        guard let id = id ?? selected, let topic = root.find(id), !topic.children.isEmpty else { return }
        change(topic.folded ? "Unfold" : "Fold") { $0.update(id) { $0.folded.toggle() } }
    }

    func rename(_ id: String, to title: String) {
        change("Rename Topic", coalescing: "title:\(id)") { $0.update(id) { $0.title = title } }
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

    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard !isSaved || onDisk == nil else { return }
        do {
            let data = map.data()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            onDisk = data
            isSaved = true
            saveError = nil
        } catch {
            saveError = "Couldn’t save: \(error.localizedDescription)"
        }
    }
}
