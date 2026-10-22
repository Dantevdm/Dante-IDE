import AppKit
import DanteKit
import SwiftUI

extension View {
    /// The right-click menu for a doc anywhere in Docs: open, rename, duplicate, copy, paste,
    /// show in Finder and move to the Trash.
    func docMenu(_ doc: DocLibrary.Doc, session: Session) -> some View {
        contextMenu { DocMenu(doc: doc, session: session) }
    }

}

private struct DocMenu: View {
    let doc: DocLibrary.Doc
    let session: Session

    var body: some View {
        Button("Open") { session.showDoc(doc.path) }
        if doc.kind == .markdown || doc.kind == .html || doc.kind == .diagram {
            Button("Open in Code") { if let url = session.docURL(doc) { session.open(file: url) } }
        }
        Divider()
        Button("Rename…") { session.renameDoc(doc) }
        Button("Duplicate") { session.duplicateDoc(doc) }
        Divider()
        Button("Copy") { if let url = session.docItemURL(doc) { session.copyToPasteboard([url]) } }
        Button("Paste") { session.pasteDocs(into: (doc.path as NSString).deletingLastPathComponent) }
            .disabled(Session.pasteboardFiles.isEmpty)
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(doc.path, forType: .string)
        }
        Divider()
        Button("Show in Finder") { if let url = session.docItemURL(doc) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        Divider()
        Button("Move to Trash…") { session.trashDoc(doc) }
    }
}

extension Session {
    func docURL(_ doc: DocLibrary.Doc) -> URL? { workspace?.url.appending(path: doc.path) }

    /// What a doc is on disk: its file, or a motion piece's whole folder.
    func docItemURL(_ doc: DocLibrary.Doc) -> URL? {
        guard let url = docURL(doc) else { return nil }
        return doc.kind == .motion ? url.deletingLastPathComponent() : url
    }

    private func relative(_ url: URL) -> String? {
        guard let root = workspace?.url.standardizedFileURL.path else { return nil }
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    /// Asks for a new name; the doc keeps showing under it.
    func renameDoc(_ doc: DocLibrary.Doc) {
        guard let url = docItemURL(doc) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(url.lastPathComponent)”"
        alert.informativeText = doc.kind == .motion ? "The piece's folder is renamed." : "The file is renamed; links to it in other docs aren't changed."
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // Select the name without its extension, like Finder.
        DispatchQueue.main.async {
            let name = url.lastPathComponent
            let stem = doc.kind == .diagram ? name.replacingOccurrences(of: Diagram.fileSuffix, with: "") : (name as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        let shown = docPath == doc.path
        rename(url, to: name)
        workspace?.refreshFileIndex()
        if shown {
            let renamed = url.deletingLastPathComponent().appending(path: name)
            let file = doc.kind == .motion ? renamed.appending(path: (doc.path as NSString).lastPathComponent) : renamed
            if let path = relative(file) { showDoc(path) }
        }
    }

    func duplicateDoc(_ doc: DocLibrary.Doc) {
        guard let url = docItemURL(doc) else { return }
        duplicate([url])
        workspace?.refreshFileIndex()
    }

    /// Files on the pasteboard copied into a docs folder, renamed on a clash like Finder.
    func pasteDocs(into folder: String) {
        guard let root = workspace?.url else { return }
        paste(Session.pasteboardFiles, into: folder.isEmpty ? root : root.appending(path: folder))
        workspace?.refreshFileIndex()
    }

    /// To the Trash after asking; the library shows again if it was open.
    func trashDoc(_ doc: DocLibrary.Doc) {
        guard let url = docItemURL(doc) else { return }
        let shown = docPath == doc.path
        trash([url])
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        workspace?.refreshFileIndex()
        if shown { showDoc(DocLibrary.libraryPath) }
    }
}
