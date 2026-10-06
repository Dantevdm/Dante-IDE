import DanteKit
import Foundation
import Observation

/// Find in Project: the query and its latest results, kept per window.
@MainActor
@Observable
final class SearchState {
    var query = ProjectSearch.Query(text: "")
    private(set) var result = ProjectSearch.Result()
    private(set) var isSearching = false
    /// Files whose matches are folded away.
    var collapsed: Set<String> = []
    /// A language server's references, shown in place of search results until closed.
    var references: (symbol: String, result: ProjectSearch.Result)?
    var showsReplace = false
    var replacement = ""
    /// Matches taken out of a replace, as "path#line:column".
    var dismissed: Set<String> = []
    /// What the last replace did, shown under the fields.
    var replaceNotice: String?
    private var task: Task<Void, Never>?

    var isInvalid: Bool { !query.text.isEmpty && query.expression == nil }

    func isDismissed(_ match: ProjectSearch.Match, in path: String) -> Bool {
        dismissed.contains("\(path)#\(match.id)")
    }

    /// The matches a replace would change: everything shown, less what was dismissed.
    var replaceable: [(path: String, ids: Set<String>)] {
        result.files.compactMap { file in
            let ids = Set(file.matches.filter { !isDismissed($0, in: file.path) }.map(\.id))
            return ids.isEmpty ? nil : (file.path, ids)
        }
    }

    /// Searches after a short pause, so typing doesn't start a search per keystroke.
    func run(in workspace: Workspace, delay: Duration = .milliseconds(200)) {
        task?.cancel()
        let query = query
        guard query.expression != nil else {
            result = ProjectSearch.Result()
            isSearching = false
            return
        }
        isSearching = true
        let root = workspace.url
        let paths = workspace.files
        // Open files are searched as they are in the editor, saved or not.
        let rootPath = root.standardizedFileURL.path + "/"
        var overrides: [String: String] = [:]
        for document in workspace.documents where document.isDirty {
            let path = document.url.standardizedFileURL.path
            if path.hasPrefix(rootPath) { overrides[String(path.dropFirst(rootPath.count))] = document.text }
        }
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let found = await ProjectSearch.run(query, root: root, paths: paths, overrides: overrides)
            guard !Task.isCancelled else { return }
            result = found
            collapsed = []
            dismissed = []
            isSearching = false
        }
    }
}
