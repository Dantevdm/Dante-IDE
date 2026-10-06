import AppKit
import DanteKit

/// Replace across the project. Open files change in the editor, unsaved and undoable;
/// closed files are rewritten on disk.
extension Session {
    /// Replace All, after asking.
    func replaceAllInProject() {
        let targets = search.replaceable
        let count = targets.reduce(0) { $0 + $1.ids.count }
        guard count > 0 else { return }
        let alert = NSAlert()
        let with = search.replacement.isEmpty ? "nothing (deleting them)" : "“\(search.replacement)”"
        alert.messageText = "Replace \(count) match\(count == 1 ? "" : "es") in \(targets.count) file\(targets.count == 1 ? "" : "s") with \(with)?"
        alert.informativeText = "Open files change in the editor, where you can review and undo before saving. Other files are saved straight away."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        replace(targets)
    }

    func replaceMatches(in file: ProjectSearch.FileMatches) {
        let ids = Set(file.matches.filter { !search.isDismissed($0, in: file.path) }.map(\.id))
        replace([(file.path, ids)])
    }

    func replaceMatch(_ match: ProjectSearch.Match, in path: String) {
        replace([(path, [match.id])])
    }

    private func replace(_ targets: [(path: String, ids: Set<String>)]) {
        guard let workspace else { return }
        let query = search.query
        var replaced = 0, files = 0
        var written: [URL] = [], failed: [String] = []
        for (path, ids) in targets {
            let url = workspace.url.appending(path: path)
            let open = workspace.documents.first { $0.url.standardizedFileURL == url.standardizedFileURL }
            guard let text = open?.text ?? (try? String(contentsOf: url, encoding: .utf8)) else {
                failed.append(path)
                continue
            }
            let result = ProjectReplace.apply(query, replacement: search.replacement, to: text) { ids.contains($0) }
            guard result.count > 0 else { continue }
            if let open {
                open.text = result.text
                languages?.changed(open)
            } else {
                do {
                    try Data(result.text.utf8).write(to: url, options: .atomic)
                    written.append(url)
                } catch {
                    failed.append(path)
                    continue
                }
            }
            replaced += result.count
            files += 1
        }
        languages?.filesChanged(written)
        if !written.isEmpty { gitRevision += 1 }
        search.replaceNotice = replaced == 0
            ? "Nothing was replaced; the files changed since the search."
            : "Replaced \(replaced) in \(files) file\(files == 1 ? "" : "s")."
        if !failed.isEmpty { errorMessage = "Couldn’t update \(failed.joined(separator: ", "))." }
        search.run(in: workspace, delay: .zero)
    }
}
