import AppKit
import DanteEditor
import DanteKit
import PDFKit

/// Opening, saving and closing files in the workspace.
extension Session {
    func open(file url: URL) {
        guard let workspace else { return }
        do {
            try workspace.open(url)
            git.diff = nil
            area = .code
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Opens a file from the Problems panel at a diagnostic.
    /// Opens a file with a 1-based line in view, for tests and search results.
    func open(file url: URL, line: Int) {
        open(file: url)
        guard let target = workspace?.activeDocument, target.url.standardizedFileURL == url.standardizedFileURL else { return }
        let position = LSPPosition(line: max(line - 1, 0), character: 0)
        target.revealRange = LineIndex(target.text as NSString).range(of: LSPRange(start: position, end: position))
    }

    func reveal(_ diagnostic: LSPDiagnostic, in url: URL) {
        open(file: url)
        guard let target = workspace?.activeDocument, target.url.standardizedFileURL == url.standardizedFileURL else { return }
        target.revealRange = LineIndex(target.text as NSString).range(of: diagnostic.range)
    }

    /// Hands a file's problems to Claude, from the Problems panel.
    func fixWithClaude(_ problems: ProblemFile) {
        let list = problems.diagnostics.prefix(30).map { "- line \($0.range.start.line + 1): \($0.message)" }.joined(separator: "\n")
        askClaude("Fix these problems the language server reports in \(problems.path):\n\(list)")
    }

    /// Hands one problem from the language server to Claude.
    func fixWithClaude(_ diagnostic: LSPDiagnostic, in document: EditorDocument) {
        guard let workspace else { return }
        let path = ProposedChange.relativePath(of: document.url, in: workspace.url)
        let kind = diagnostic.severity == .error ? "error" : "warning"
        askClaude("Fix this \(kind) in \(path) on line \(diagnostic.range.start.line + 1): \(diagnostic.message)")
    }

    /// The problems themselves travel in the message context (`ClaudeBrief.context`).
    func fixAllWithClaude(in document: EditorDocument) {
        guard let workspace else { return }
        askClaude("Fix the errors and warnings the language server reports in \(ProposedChange.relativePath(of: document.url, in: workspace.url)).")
    }

    /// Declarations across the project, scanned off the main thread and kept until the
    /// files change.
    func projectSymbols() async -> [CodeSymbol] {
        guard let workspace else { return [] }
        if let cached = symbolIndex, cached.revision == workspace.revision { return cached.symbols }
        let root = workspace.url, files = workspace.files, revision = workspace.revision
        let symbols = await Task.detached(priority: .userInitiated) { DeclarationScanner.project(root: root, files: files) }.value
        symbolIndex = (revision, symbols)
        return symbols
    }

    /// Opens a symbol from Go to Symbol and selects its name.
    func reveal(_ symbol: CodeSymbol) {
        open(file: symbol.url)
        guard let target = workspace?.activeDocument, target.url.standardizedFileURL == symbol.url.standardizedFileURL else { return }
        target.revealRange = symbol.range.nsRange(in: target.text as NSString)
    }

    /// Opens where the symbol at `offset` in `document` is defined.
    func jumpToDefinition(in document: EditorDocument, at offset: Int) {
        guard let languages else { return }
        Task {
            let locations = await languages.definition(in: document, at: offset)
            guard let location = locations.first else {
                NSSound.beep()
                return
            }
            open(file: location.url)
            guard let target = workspace?.activeDocument, target.url.standardizedFileURL == location.url else { return }
            target.revealRange = location.range.nsRange(in: target.text as NSString)
        }
    }

    /// The same, for the caret in the active editor (Navigate › Jump to Definition).
    func jumpToDefinitionAtCursor() {
        guard let document = workspace?.activeDocument else { return }
        let position = LSPPosition(line: cursor.line - 1, character: cursor.column - 1)
        jumpToDefinition(in: document, at: position.offset(in: document.text as NSString))
    }

    func saveActive() {
        guard let document = workspace?.activeDocument else { return }
        saveFormatting(document)
    }

    func saveAll() {
        workspace?.documents.filter(\.isDirty).forEach(saveFormatting)
    }

    /// Settings › Files › Auto-save "When Dante loses focus": every changed file, as typed.
    func autoSaveOnFocusChange() {
        guard Preferences.shared.autoSave == .onFocusChange else { return }
        workspace?.documents.filter(\.isDirty).forEach { save($0, tidy: false) }
    }

    /// ⌘S: formats first when Settings asks for it and a language server can.
    func saveFormatting(_ document: EditorDocument) {
        guard Preferences.shared.formatsOnSave, languages?.existingClient(for: document.language)?.formats == true else {
            return save(document)
        }
        Task {
            await format(document)
            save(document)
        }
    }

    /// Writes the file now, after the whitespace tidying chosen in Settings. Auto-save skips
    /// the tidying, so it never removes a space just typed.
    func save(_ document: EditorDocument, tidy: Bool = true) {
        if tidy {
            let tidied = Preferences.shared.tidied(document.text, language: document.language)
            if tidied != document.text { document.text = tidied }
        }
        do {
            try document.save()
            languages?.saved(document)
            conflicts.remove(document.url)
            if document.url.path.contains("/.dante/") { workspace?.reloadSpec() }
        } catch {
            errorMessage = "Couldn’t save \(document.name): \(error.localizedDescription)"
        }
    }

    func close(_ document: EditorDocument) {
        guard confirmDiscardingChanges(in: [document]) else { return }
        languages?.closed(document)
        workspace?.close(document)
    }

    func closeActiveTab() {
        if let document = workspace?.activeDocument {
            close(document)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    /// Git › Finish Task: the task being worked on with Claude, else the first in progress.
    func finishCurrentTask() {
        guard let workspace else { return }
        let open = workspace.tasks.file.tasks.filter { $0.state == .inProgress }
        guard let task = open.first(where: { $0.claude == true }) ?? open.first else {
            errorMessage = "No task is in progress. Move one to In progress on the Plan board, or use Finish… on its card."
            return
        }
        finish(task)
    }

    func finish(_ task: PlanTask) {
        guard let workspace else { return }
        finishing = FinishTaskModel(root: workspace.url, task: task)
    }

    func toggleSplit() {
        guard let workspace else { return }
        if workspace.split == nil { workspace.splitEditor() } else { workspace.closeSplit() }
    }

    func focusOtherPane() {
        guard let workspace, let split = workspace.split else { return }
        workspace.focusPane(right: !split.focusIsRight)
    }

    func selectTab(offset: Int) {
        guard let workspace, !workspace.documents.isEmpty else { return }
        let index = workspace.documents.firstIndex { $0.id == workspace.activeDocumentID } ?? 0
        let next = (index + offset + workspace.documents.count) % workspace.documents.count
        workspace.activeDocumentID = workspace.documents[next].id
    }

    /// Asks before throwing away unsaved edits. Returns false if the user cancels.
    func confirmDiscardingChanges(in documents: [EditorDocument]) -> Bool {
        Self.confirmDiscardingChanges(in: documents) { save($0) }
    }

    /// Asks before throwing away unsaved edits. Returns false if the user cancels or a save fails.
    static func confirmDiscardingChanges(in documents: [EditorDocument], save: (EditorDocument) -> Void) -> Bool {
        let dirty = documents.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Save changes to \(dirty[0].name)?"
            : "Save changes to \(dirty.count) files?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            dirty.forEach(save)
            return dirty.allSatisfy { !$0.isDirty }
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }
}
