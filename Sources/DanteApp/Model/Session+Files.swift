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

    func duplicate(_ urls: [URL]) {
        perform { workspace in
            for url in urls {
                let copy = try FileOperations.duplicate(url)
                workspace.itemsChanged(in: [copy.deletingLastPathComponent()])
            }
        }
    }

    /// Copies files and folders onto the pasteboard, as Finder's Copy does, so they paste
    /// into Finder or back into the tree.
    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
    }

    /// Files and folders on the pasteboard, from Finder's Copy or the tree's.
    static var pasteboardFiles: [URL] {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map(FileOperations.resolved)
    }

    /// Paste copies, wherever the files came from, renaming on a clash like Finder.
    func paste(_ urls: [URL], into folder: URL) {
        guard !urls.isEmpty else { return }
        perform { workspace in
            for url in urls.map(FileOperations.resolved) where url.isFileURL {
                try FileOperations.copy(url, into: folder)
            }
            workspace.itemsChanged(in: [folder])
            workspace.root.node(for: folder)?.isExpanded = true
        }
    }

    /// Drops onto a folder: items from the project move there, items from elsewhere are copied in.
    func drop(_ urls: [URL], into folder: URL) {
        perform { workspace in
            let root = workspace.url.standardizedFileURL.path + "/"
            var touched = [folder]
            for url in urls.map(FileOperations.resolved) where url.isFileURL {
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

    /// Moves to the Trash after asking; open tabs for them close, unsaved edits included.
    func trash(_ urls: [URL]) {
        guard let workspace, !urls.isEmpty else { return }
        let affected = urls.flatMap { workspace.documents(under: $0) }
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to the Trash?" : "Move \(urls.count) items to the Trash?"
        var detail = "You can put it back from the Trash in Finder."
        if affected.contains(where: \.isDirty) { detail += " Unsaved changes in its open tabs will be lost." }
        alert.informativeText = detail
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { workspace in
            for url in urls { try FileOperations.trash(url) }
            for document in affected {
                languages?.closed(document)
                workspace.close(document)
            }
            workspace.itemsChanged(in: urls.map { $0.deletingLastPathComponent() })
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
