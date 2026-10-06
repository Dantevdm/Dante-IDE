import AppKit
import DanteEditor
import DanteKit

/// Language-server features for the editor: completion, references, rename and format.
extension Session {
    /// Completions for a document, converted for the editor. Ranges are worked out against
    /// the text as it was when asked, which is what the server answered for.
    func completionSource(for document: EditorDocument) -> CompletionSource? {
        guard let languages, languages.existingClient(for: document.language)?.completes == true else { return nil }
        return CompletionSource(triggers: languages.completionTriggers(for: document.language)) { [weak document] offset, trigger in
            guard let document else { return [] }
            let text = document.text as NSString
            let items = await languages.completion(in: document, at: offset, trigger: trigger)
            let lines = LineIndex(text)
            return items.map { item in
                EditorCompletion(
                    id: item.id, label: item.label, detail: item.detail, documentation: item.documentation,
                    kind: Self.kind(item.kind), insertText: item.insertText, isSnippet: item.isSnippet,
                    replaceRange: item.replaceRange.map { lines.range(of: $0) },
                    sortText: item.sortText, filterText: item.filterText
                )
            }
        }
    }

    func editorActions(for document: EditorDocument) -> EditorActions {
        let client = languages?.existingClient(for: document.language)
        return EditorActions(
            references: client?.findsReferences == true ? { [weak self, weak document] offset in
                guard let self, let document else { return }
                self.findReferences(in: document, at: offset)
            } : nil,
            rename: client?.renames == true ? { [weak self, weak document] offset in
                guard let self, let document else { return }
                self.renameSymbol(in: document, at: offset)
            } : nil,
            format: client?.formats == true ? { [weak self, weak document] in
                guard let self, let document else { return }
                self.formatDocument(document)
            } : nil
        )
    }

    // MARK: Menu commands, at the caret

    private var caretTarget: (EditorDocument, Int)? {
        guard let document = workspace?.activeDocument else { return nil }
        let position = LSPPosition(line: cursor.line - 1, character: cursor.column - 1)
        return (document, position.offset(in: document.text as NSString))
    }

    func findReferencesAtCursor() {
        if let (document, offset) = caretTarget { findReferences(in: document, at: offset) }
    }

    func renameSymbolAtCursor() {
        if let (document, offset) = caretTarget { renameSymbol(in: document, at: offset) }
    }

    func formatActiveDocument() {
        if let document = workspace?.activeDocument { formatDocument(document) }
    }

    // MARK: Actions

    func findReferences(in document: EditorDocument, at offset: Int) {
        guard let workspace, let languages else { return }
        let symbol = Self.word(at: offset, in: document.text)
        Task {
            let locations = await languages.references(in: document, at: offset)
            let root = workspace.url.standardizedFileURL.path + "/"
            let places = locations.compactMap { location -> (path: String, line: Int, column: Int, length: Int)? in
                let path = location.url.standardizedFileURL.path
                guard path.hasPrefix(root) else { return nil }
                // Index results from sourcekit-lsp are empty ranges at the start of the name.
                let span = location.range.end.character - location.range.start.character
                let length = location.range.start.line == location.range.end.line && span > 0 ? span : (symbol as NSString).length
                return (String(path.dropFirst(root.count)), location.range.start.line, location.range.start.character, max(length, 1))
            }
            guard !places.isEmpty else {
                errorMessage = "No references to \(symbol.isEmpty ? "that" : symbol) found."
                return
            }
            search.references = (symbol, ProjectSearch.result(for: places, root: workspace.url))
            area = .code
            sidebar = .search
        }
    }

    func renameSymbol(in document: EditorDocument, at offset: Int) {
        guard let languages else { return }
        let current = Self.word(at: offset, in: document.text)
        guard !current.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(current)"
        alert.informativeText = "Every reference the language server knows about is renamed, in open and closed files."
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != current else { return }
        Task {
            guard var edit = await languages.rename(in: document, at: offset, to: name), edit.editCount > 0 else {
                errorMessage = "The language server couldn’t rename \(current)."
                return
            }
            // sourcekit-lsp renames only the current file when asked from top-level code, though
            // it finds references everywhere; rename those too.
            let documents = workspace?.documents ?? []
            edit.include(await languages.references(in: document, at: offset), renaming: current, to: name) { url in
                documents.first { $0.url.standardizedFileURL == url }?.text ?? (try? String(contentsOf: url, encoding: .utf8))
            }
            apply(edit)
        }
    }

    func formatDocument(_ document: EditorDocument) {
        Task {
            if await !format(document) {
                errorMessage = "The language server for \(document.name) doesn’t format documents."
            }
        }
    }

    /// Applies the language server's formatting; false when no server formats this file.
    @discardableResult
    func format(_ document: EditorDocument) async -> Bool {
        guard let languages,
              let edits = await languages.formatting(of: document, tabSize: Preferences.shared.indentWidth(for: document.language))
        else { return false }
        if !edits.isEmpty {
            document.text = LSPTextEdit.apply(edits, to: document.text)
            languages.changed(document)
        }
        return true
    }

    /// Applies a rename across files: open documents change in the editor (unsaved, so they
    /// can be checked), closed files are rewritten on disk.
    private func apply(_ edit: LSPWorkspaceEdit) {
        guard let workspace else { return }
        var failed: [String] = [], written: [URL] = []
        for (url, edits) in edit.changes {
            if let document = workspace.documents.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                document.text = LSPTextEdit.apply(edits, to: document.text)
                languages?.changed(document)
            } else {
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    try Data(LSPTextEdit.apply(edits, to: text).utf8).write(to: url, options: .atomic)
                    written.append(url)
                } catch {
                    failed.append(url.lastPathComponent)
                }
            }
        }
        languages?.filesChanged(written)
        if !failed.isEmpty { errorMessage = "Couldn’t update \(failed.joined(separator: ", "))." }
    }

    static func word(at offset: Int, in text: String) -> String {
        let ns = text as NSString
        guard ns.length > 0 else { return "" }
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < ns.length, let scalar = Unicode.Scalar(ns.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        var start = min(offset, ns.length)
        if !isWord(start), isWord(start - 1) { start -= 1 }
        guard isWord(start) else { return "" }
        var end = start
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private static func kind(_ kind: LSPCompletionItem.Kind?) -> EditorCompletion.Kind {
        switch kind {
        case .method, .function, .constructor: .function
        case .variable, .field, .value, .reference: .variable
        case .property: .property
        case .class, .interface, .struct, .enum, .typeParameter: .type
        case .keyword, .operator: .keyword
        case .module, .file, .folder: .module
        case .constant, .enumMember: .constant
        case .snippet: .snippet
        default: .other
        }
    }
}
