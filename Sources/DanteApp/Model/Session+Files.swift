import AppKit
import DanteKit

/// The explorer's file operations. Open tabs follow renames and moves, language servers
/// are told, and removal always goes to the Trash.
extension Session {
    /// Where a new file goes when the explorer header's buttons are used.
    func newItemFolder(for focus: URL?) -> URL? {
        guard let workspace else { return nil }
        guard let focus else { return workspace.url }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: focus.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? focus : focus.deletingLastPathComponent()
    }

    func createFile(named name: String, in folder: URL) {
        perform { workspace in
            let url = try FileOperations.createFile(named: name, in: folder)
            workspace.itemsChanged(in: [url.deletingLastPathComponent()])
            expand(to: url, in: workspace)
            open(file: url)
        }
    }

    func createFolder(named name: String, in folder: URL) {
        perform { workspace in
            let url = try FileOperations.createFolder(named: name, in: folder)
            workspace.itemsChanged(in: [url.deletingLastPathComponent()])
            expand(to: url, in: workspace)
        }
    }

    func rename(_ url: URL, to name: String) {
        perform { workspace in
            let affected = workspace.documents(under: url)
            affected.forEach { languages?.closed($0) }
            let destination = try FileOperations.rename(url, to: name)
            workspace.itemMoved(from: url, to: destination)
            affected.forEach { languages?.opened($0) }
        }
    }

    func duplicate(_ url: URL) {
        perform { workspace in
            let copy = try FileOperations.duplicate(url)
            workspace.itemsChanged(in: [copy.deletingLastPathComponent()])
        }
    }

    /// Drops onto a folder: items from the project move there, items from elsewhere are copied in.
    func drop(_ urls: [URL], into folder: URL) {
        perform { workspace in
            let root = workspace.url.standardizedFileURL.path + "/"
            var touched = [folder]
            for url in urls where url.isFileURL {
                if url.standardizedFileURL.path.hasPrefix(root) {
                    let affected = workspace.documents(under: url)
                    affected.forEach { languages?.closed($0) }
                    let destination = try FileOperations.move(url, into: folder)
                    guard destination != url else { continue }
                    workspace.itemMoved(from: url, to: destination)
                    affected.forEach { languages?.opened($0) }
                    touched.append(url.deletingLastPathComponent())
                } else {
                    try FileOperations.copy(url, into: folder)
                }
            }
            workspace.itemsChanged(in: touched)
            workspace.root.node(for: folder)?.isExpanded = true
        }
    }

    /// Moves to the Trash after asking; open tabs for it close, unsaved edits included.
    func trash(_ url: URL) {
        guard let workspace else { return }
        let affected = workspace.documents(under: url)
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        var detail = "You can put it back from the Trash in Finder."
        if affected.contains(where: \.isDirty) { detail += " Unsaved changes in its open tabs will be lost." }
        alert.informativeText = detail
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { workspace in
            try FileOperations.trash(url)
            for document in affected {
                languages?.closed(document)
                workspace.close(document)
            }
            workspace.itemsChanged(in: [url.deletingLastPathComponent()])
        }
    }

    private func expand(to url: URL, in workspace: Workspace) {
        var folder = url.deletingLastPathComponent()
        var chain: [URL] = []
        while folder.standardizedFileURL.path.count > workspace.url.standardizedFileURL.path.count {
            chain.insert(folder, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        // Re-list each folder on the way down, since new ones may not be in the tree yet.
        var parent = workspace.root
        for step in chain {
            parent.loadChildren()
            guard let node = parent.children?.first(where: { $0.url.standardizedFileURL.path == step.standardizedFileURL.path }) else { break }
            node.loadChildren()
            node.isExpanded = true
            parent = node
        }
    }

    private func perform(_ work: (Workspace) throws -> Void) {
        guard let workspace else { return }
        do {
            try work(workspace)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
