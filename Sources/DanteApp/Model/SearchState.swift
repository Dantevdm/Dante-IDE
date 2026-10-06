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
    private var task: Task<Void, Never>?

    var isInvalid: Bool { !query.text.isEmpty && query.expression == nil }

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
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let found = await ProjectSearch.run(query, root: root, paths: paths)
            guard !Task.isCancelled else { return }
            result = found
            collapsed = []
            isSearching = false
        }
    }
}
