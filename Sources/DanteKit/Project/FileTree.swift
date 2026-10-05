import Foundation
import Observation

/// Reads directory listings for the explorer.
public enum FileTree {
    /// Names hidden from the explorer: version control, dependencies and build output.
    public static let ignoredNames: Set<String> = [
        ".git", ".hg", ".svn", ".DS_Store", "node_modules", ".build", "DerivedData",
        ".swiftpm", "__pycache__", ".venv", ".pytest_cache", ".mypy_cache", ".next", ".turbo",
    ]

    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let isDirectory: Bool
    }

    /// Lists a directory: folders first, then files, each sorted the way Finder sorts names.
    public static func listing(of directory: URL, fileManager: FileManager = .default) throws -> [Entry] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        return urls
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return Entry(url: url, isDirectory: isDirectory)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
    }
}

/// One file or folder in the explorer. Children load the first time a folder is expanded.
@MainActor
@Observable
public final class FileNode: Identifiable {
    public let url: URL
    public let isDirectory: Bool
    public private(set) var children: [FileNode]?
    public var isExpanded = false

    public nonisolated var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// Loads (or reloads) this folder's children.
    public func loadChildren() {
        guard isDirectory else { return }
        let entries = (try? FileTree.listing(of: url)) ?? []
        let existing = Dictionary(uniqueKeysWithValues: (children ?? []).map { ($0.url, $0) })
        children = entries.map { existing[$0.url] ?? FileNode(url: $0.url, isDirectory: $0.isDirectory) }
    }

    public func toggle() {
        guard isDirectory else { return }
        if children == nil { loadChildren() }
        isExpanded.toggle()
    }
}
