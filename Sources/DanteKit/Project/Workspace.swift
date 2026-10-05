import Foundation
import Observation

/// An open project folder: its file tree, open tabs and lifecycle.
@MainActor
@Observable
public final class Workspace {
    public let root: FileNode
    public private(set) var documents: [EditorDocument] = []
    public var activeDocumentID: EditorDocument.ID?
    public private(set) var lifecycle: Lifecycle
    /// Tasks from `.dante/tasks.yaml`.
    public let tasks: TaskBoard
    /// What Claude may touch, from `claude:` in project.yaml.
    public private(set) var claudeRules = ClaudeRules()
    /// Phase docs from `.dante/phases/`, keyed by lower-case phase name.
    public private(set) var phaseDocs: [String: PhaseDoc] = [:]

    /// Every file in the project, relative to the root, for quick open. Filled in the background.
    public private(set) var files: [String] = []
    private var fileSet: Set<String> = []
    private var indexTask: Task<Void, Never>?
    /// The root with symlinks resolved, which is how FSEvents reports paths.
    private let resolvedRootPath: String

    public var url: URL { root.url }
    public var name: String { root.url.lastPathComponent }

    public var activeDocument: EditorDocument? {
        documents.first { $0.id == activeDocumentID }
    }

    public init(url: URL) {
        root = FileNode(url: url, isDirectory: true)
        root.loadChildren()
        root.isExpanded = true
        lifecycle = Lifecycle.load(projectRoot: url)
        tasks = TaskBoard(projectRoot: url)
        resolvedRootPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        reloadSpec()
    }

    // MARK: Plan

    public var danteFolder: URL { url.appending(path: ".dante") }

    public func phaseDocURL(_ phase: String) -> URL {
        danteFolder.appending(path: "phases/\(phase.lowercased()).md")
    }

    /// Re-reads everything under `.dante/`: lifecycle, tasks and phase docs.
    public func reloadSpec() {
        let next = Lifecycle.load(projectRoot: url)
        if next != lifecycle { lifecycle = next }
        let rules = ClaudeRules.load(projectRoot: url)
        if rules != claudeRules { claudeRules = rules }
        tasks.reload()
        var docs: [String: PhaseDoc] = [:]
        for phase in lifecycle.phases {
            if let markdown = try? String(contentsOf: phaseDocURL(phase), encoding: .utf8) {
                docs[phase.lowercased()] = PhaseDoc.parse(markdown)
            }
        }
        if docs != phaseDocs { phaseDocs = docs }
    }

    /// Moves the project to another phase by editing `lifecycle.current` in project.yaml.
    public func setCurrentPhase(_ phase: String) throws {
        let file = danteFolder.appending(path: "project.yaml")
        let yaml = (try? String(contentsOf: file, encoding: .utf8))
            .map { Lifecycle.settingCurrent(phase, inProjectYAML: $0) }
            ?? Lifecycle.projectYAMLTemplate(name: name, current: phase)
        try write(yaml, to: file)
    }

    public func createPhaseDoc(_ phase: String) throws {
        let file = phaseDocURL(phase)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try write(PhaseDoc.template(for: phase), to: file)
    }

    public func toggle(_ item: PhaseDoc.Item, inPhase phase: String) throws {
        guard let doc = phaseDocs[phase.lowercased()] else { return }
        try write(doc.toggling(item), to: phaseDocURL(phase))
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
        fileChanged(at: file)
    }

    /// Rescans the project's files off the main thread.
    public func refreshFileIndex() {
        indexTask?.cancel()
        let root = url
        indexTask = Task { [weak self] in
            let paths = await Task.detached(priority: .utility) { FileIndex.scan(root) }.value
            guard !Task.isCancelled, let self else { return }
            self.files = paths
            self.fileSet = Set(paths)
        }
    }

    public struct ExternalChanges: Equatable, Sendable {
        /// `.git/HEAD` or a branch ref moved, so the current branch may differ.
        public var gitHeadChanged = false
        /// Open documents that changed on disk but kept their unsaved edits.
        public var conflicts: [URL] = []
    }

    /// Applies a batch of changed paths from the file watcher: refreshes explorer folders,
    /// reloads clean tabs, notes git branch moves and updates the file index.
    @discardableResult
    public func applyExternalChanges(_ changed: [URL]) -> ExternalChanges {
        var result = ExternalChanges()
        let rootPath = url.standardizedFileURL.path
        var folders = Set<URL>()
        var needsIndex = false
        var specChanged = false

        for raw in changed {
            var path = raw.standardizedFileURL.path
            if path.hasPrefix(resolvedRootPath + "/") { path = rootPath + path.dropFirst(resolvedRootPath.count) }
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            let components = relative.split(separator: "/").map(String.init)
            if components.first == ".git" {
                if relative == ".git/HEAD" || relative.hasPrefix(".git/refs/heads/") { result.gitHeadChanged = true }
                continue
            }
            if components.contains(where: FileTree.ignoredNames.contains) { continue }

            let file = URL(filePath: path)
            folders.insert(file.deletingLastPathComponent().standardizedFileURL)
            let exists = FileManager.default.fileExists(atPath: path)
            if exists != fileSet.contains(relative) { needsIndex = true }
            if relative.hasPrefix(".dante/") { specChanged = true }
            if let document = documents.first(where: { $0.url.standardizedFileURL.path == path }), exists {
                if document.isDirty {
                    result.conflicts.append(document.url)
                } else {
                    try? document.reloadFromDisk()
                }
            }
        }
        for folder in folders { root.node(for: folder)?.loadChildren() }
        if needsIndex { refreshFileIndex() }
        if specChanged { reloadSpec() }
        return result
    }

    /// Opens a file in a tab, or switches to its tab if it's already open.
    @discardableResult
    public func open(_ url: URL) throws -> EditorDocument {
        if let existing = documents.first(where: { $0.url == url }) {
            activeDocumentID = existing.id
            return existing
        }
        let document = try EditorDocument(url: url)
        documents.append(document)
        activeDocumentID = document.id
        return document
    }

    /// Closes a tab and activates its neighbour. Callers confirm unsaved changes first.
    public func close(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        if activeDocumentID == document.id {
            activeDocumentID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
        }
    }

    /// Brings the editor and file tree up to date after something outside the editor
    /// (Claude, the terminal) changed a file. Unsaved edits are never overwritten; returns
    /// false when an open document kept its edits instead of reloading.
    @discardableResult
    public func fileChanged(at url: URL) -> Bool {
        root.node(for: url.deletingLastPathComponent())?.loadChildren()
        if url.path.contains("/.dante/") { reloadSpec() }
        guard let document = documents.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return true }
        guard !document.isDirty else { return false }
        try? document.reloadFromDisk()
        return true
    }
}
