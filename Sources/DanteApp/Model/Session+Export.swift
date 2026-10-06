import AppKit
import DanteEditor
import DanteKit
import PDFKit

/// Exporting and printing docs.
extension Session {
    /// The markdown doc Docs is showing, exported as a Paper-theme PDF to save or print.
    func exportDoc(printing: Bool = false) {
        guard let workspace, let doc = DocLibrary(paths: workspace.files).doc(preferring: docPath), doc.kind == .markdown else { return }
        let url = workspace.url.appending(path: doc.path)
        // Unsaved edits are what's on screen, so they're what gets exported.
        let open = workspace.documents.first { $0.url.standardizedFileURL == url.standardizedFileURL }?.text
        guard let text = open ?? (try? String(contentsOf: url, encoding: .utf8)),
              let data = DocExport.pdf(MarkdownDocument(text), path: doc.path, root: workspace.url) else {
            errorMessage = "Couldn’t export \(doc.path)."
            return
        }
        if printing {
            guard let pdf = PDFDocument(data: data),
                  let operation = pdf.printOperation(for: .shared, scalingMode: .pageScaleNone, autoRotate: true) else { return }
            operation.jobTitle = (doc.path as NSString).lastPathComponent
            operation.runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ((doc.path as NSString).lastPathComponent as NSString).deletingPathExtension + ".pdf"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try data.write(to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            errorMessage = "Couldn’t save the PDF: \(error.localizedDescription)"
        }
    }
}
