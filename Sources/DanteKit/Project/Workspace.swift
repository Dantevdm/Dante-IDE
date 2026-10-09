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
    /// Name, summary and health checks from project.yaml.
    public private(set) var info = ProjectInfo()
    /// Bumped whenever files change on disk or through the editor, so views that read
    /// git or other tools know to refresh.
    public private(set) var revision = 0

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

    /// The editor split in two. The active document is always the focused pane's; tabs
    /// open files there.
    public struct Split: Equatable, Sendable {
        /// What the pane without focus shows.
        public var otherDocumentID: EditorDocument.ID
        public var focusIsRight: Bool
    }

    public private(set) var split: Split?

    /// The documents in the left and right panes, when split.
    public var panes: (left: EditorDocument, right: EditorDocument)? {
        guard let split, let active = activeDocument,
              let other = documents.first(where: { $0.id == split.otherDocumentID }) else { return nil }
        return split.focusIsRight ? (other, active) : (active, other)
    }

    /// Splits the editor, showing the active document on both sides with the right one focused.
    public func splitEditor() {
        guard split == nil, let active = activeDocumentID else { return }
        split = Split(otherDocumentID: active, focusIsRight: true)
    }

    /// Back to one pane, keeping the focused one.
    public func closeSplit() {
        split = nil
    }

    /// Clicking into a pane makes its document the active one.
    public func focusPane(right: Bool) {
        guard var split, split.focusIsRight != right, let active = activeDocumentID else { return }
        activeDocumentID = split.otherDocumentID
        split.otherDocumentID = active
        split.focusIsRight = right
        self.split = split
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
        let nextInfo = ProjectInfo.load(projectRoot: url)
        if nextInfo != info { info = nextInfo }
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
        try write(lifecycle.phaseDocTemplate(phase), to: file)
    }

    /// The template that best fits this project's files.
    public var suggestedTemplate: LifecycleTemplate {
        LifecycleTemplate.suggest(for: files) { [url] path in
            try? String(contentsOf: url.appending(path: path), encoding: .utf8)
        }
    }

    /// Creates `.dante/` from a template: project.yaml, a checklist per phase and an empty
    /// task list. Leaves any file that already exists alone.
    public func setUp(with template: LifecycleTemplate, current: String) throws {
        let project = danteFolder.appending(path: "project.yaml")
        if !FileManager.default.fileExists(atPath: project.path) {
            try write(template.projectYAML(name: name, summary: Self.readmeSummary(in: url), current: current), to: project)
        }
        for phase in template.phaseNames {
            let file = phaseDocURL(phase)
            if !FileManager.default.fileExists(atPath: file.path) { try write(template.phaseDoc(phase), to: file) }
        }
        let tasks = danteFolder.appending(path: "tasks.yaml")
        if !FileManager.default.fileExists(atPath: tasks.path) {
            try write("# Tasks for this project. Edit here or on Dante's Plan board.\nprefix: \(Self.taskPrefix(for: name))\ntasks: []\n", to: tasks)
        }
        reloadSpec()
    }

    /// The first paragraph of the README that isn't a heading, badge or image.
    public static func readmeSummary(in root: URL) -> String? {
        let names = ["README.md", "Readme.md", "readme.md", "README"]
        guard let text = names.lazy.compactMap({ try? String(contentsOf: root.appending(path: $0), encoding: .utf8) }).first else { return nil }
        var paragraph: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !paragraph.isEmpty { break }
                continue
            }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("![") || trimmed.hasPrefix("[![") || trimmed.hasPrefix("<") || trimmed.hasPrefix("```") {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(trimmed)
        }
        guard !paragraph.isEmpty else { return nil }
        let joined = paragraph.joined(separator: " ")
            .replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        guard joined.count > 200 else { return joined }
        let cut = joined.prefix(200)
        return (cut.range(of: ". ", options: .backwards).map { String(cut[..<$0.lowerBound]) + "." }) ?? String(cut) + "…"
    }

    /// Initials of the project name, for task ids: "Dante IDE" → "DI", "billing" → "BIL".
    public static func taskPrefix(for name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.filter { !$0.isEmpty }
        let prefix = words.count > 1 ? String(words.prefix(3).compactMap(\.first)) : String((words.first ?? "TASK").prefix(3))
        return prefix.uppercased()
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
            guard paths != self.files else { return }
            self.files = paths
            self.fileSet = Set(paths)
            // Views that read the index reload on a new revision.
            self.revision += 1
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
        var relevant = false

        for raw in changed {
            var path = raw.standardizedFileURL.path
            if path.hasPrefix(resolvedRootPath + "/") { path = rootPath + path.dropFirst(resolvedRootPath.count) }
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            let components = relative.split(separator: "/").map(String.init)
            if components.first == ".git" {
                if relative == ".git/HEAD" || relative.hasPrefix(".git/refs/") || relative == ".git/index" {
                    if relative != ".git/index" { result.gitHeadChanged = true }
                    relevant = true
                }
                continue
            }
            if components.contains(where: FileTree.ignoredNames.contains) { continue }

            relevant = true
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
        if relevant { revision += 1 }
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

    /// Open documents at or under `url`, such as the files inside a folder about to be trashed.
    public func documents(under url: URL) -> [EditorDocument] {
        documents.filter { FileOperations.relocated($0.url, from: url, to: url) != nil }
    }

    /// Something in the project was renamed or moved: re-point open tabs, refresh both
    /// folders in the explorer and the file index. Returns the documents that moved.
    @discardableResult
    public func itemMoved(from old: URL, to new: URL) -> [EditorDocument] {
        let moved = documents.filter { document in
            guard let target = FileOperations.relocated(document.url, from: old, to: new) else { return false }
            document.relocate(to: target)
            return true
        }
        itemsChanged(in: [old.deletingLastPathComponent(), new.deletingLastPathComponent()])
        return moved
    }

    /// Re-lists folders after files appear or disappear in them, and updates the index.
    public func itemsChanged(in folders: [URL]) {
        for folder in Set(folders.map(\.standardizedFileURL)) {
            root.node(for: folder)?.loadChildren()
        }
        refreshFileIndex()
        revision += 1
    }

    /// Closes a tab and activates its neighbour. Callers confirm unsaved changes first.
    public func close(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        if var split {
            if activeDocumentID == document.id, split.otherDocumentID != document.id {
                // The focused pane closed: the other pane takes over.
                activeDocumentID = split.otherDocumentID
                self.split = nil
                return
            }
            if split.otherDocumentID == document.id {
                if activeDocumentID == document.id {
                    // Shown in both: both panes move to the neighbouring tab.
                    guard !documents.isEmpty else { self.split = nil; activeDocumentID = nil; return }
                    let neighbour = documents[min(index, documents.count - 1)].id
                    activeDocumentID = neighbour
                    split.otherDocumentID = neighbour
                    self.split = split
                } else {
                    self.split = nil
                }
                return
            }
        }
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
        revision += 1
        guard let document = documents.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return true }
        guard !document.isDirty else { return false }
        try? document.reloadFromDisk()
        return true
    }
}
