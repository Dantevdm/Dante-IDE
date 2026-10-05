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
        if url.path.contains("/.dante/") { reloadLifecycle() }
        guard let document = documents.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return true }
        guard !document.isDirty else { return false }
        try? document.reloadFromDisk()
        return true
    }

    public func reloadLifecycle() {
        lifecycle = Lifecycle.load(projectRoot: url)
    }
}
