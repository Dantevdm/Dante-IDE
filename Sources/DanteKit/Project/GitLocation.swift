import Foundation

/// Which repository a project's git features use, and how its paths map to the project's.
/// Usually the project folder is the repository (or inside one). When it isn't, but exactly
/// one folder just inside it is (docs and a compose file beside a `Code/` repo), that one is
/// used, and git's paths gain its folder in front so the rest of Dante sees project paths.
public struct GitLocation: Equatable, Sendable {
    public var root: URL
    /// The repository's folder inside the project with a slash ("Code/"), or "".
    public var prefix: String

    public init(root: URL, prefix: String = "") {
        self.root = root
        self.prefix = prefix
    }

    public static func find(projectRoot: URL, fileManager: FileManager = .default) -> GitLocation {
        var folder = projectRoot.standardizedFileURL
        while true {
            if fileManager.fileExists(atPath: folder.appending(path: ".git").path) { return GitLocation(root: projectRoot) }
            // `deletingLastPathComponent` of "/" is "/..", so stop at the top by counting.
            if folder.pathComponents.count <= 1 { break }
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
        let children = (try? fileManager.contentsOfDirectory(at: projectRoot, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles])) ?? []
        let repos = children.filter { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && fileManager.fileExists(atPath: child.appending(path: ".git").path)
        }
        guard repos.count == 1, let repo = repos.first else { return GitLocation(root: projectRoot) }
        return GitLocation(root: repo, prefix: repo.lastPathComponent + "/")
    }

    public var isNested: Bool { !prefix.isEmpty }

    /// A path git printed, as the project sees it.
    public func projectPath(_ repoPath: String) -> String { prefix + repoPath }

    /// A project path as git wants it; nil when it's outside the repository.
    public func repoPath(_ projectPath: String) -> String? {
        if prefix.isEmpty { return projectPath }
        return projectPath.hasPrefix(prefix) ? String(projectPath.dropFirst(prefix.count)) : nil
    }

    public func projectStatus(_ status: GitStatus) -> GitStatus {
        guard isNested else { return status }
        var copy = status
        copy.changes = status.changes.map(projectChange)
        return copy
    }

    public func projectChange(_ change: GitStatus.Change) -> GitStatus.Change {
        guard isNested else { return change }
        var copy = change
        copy.path = projectPath(change.path)
        copy.oldPath = change.oldPath.map(projectPath)
        return copy
    }

    public func repoChange(_ change: GitStatus.Change) -> GitStatus.Change {
        guard isNested else { return change }
        var copy = change
        copy.path = repoPath(change.path) ?? change.path
        copy.oldPath = change.oldPath.map { repoPath($0) ?? $0 }
        return copy
    }
}
