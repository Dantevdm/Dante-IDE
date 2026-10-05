import Foundation
import Observation

public struct RecentProject: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public var lastOpened: Date

    public var id: String { path }
    public var url: URL { URL(filePath: path) }
    public var name: String { url.lastPathComponent }

    /// The path with the home folder shortened to `~`.
    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// The projects shown on the launch screen, most recent first.
@MainActor
@Observable
public final class RecentProjects {
    public static let limit = 8
    private static let key = "recentProjects"

    public private(set) var items: [RecentProject]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: Self.key)
        items = data.flatMap { try? JSONDecoder().decode([RecentProject].self, from: $0) } ?? []
    }

    public func note(_ url: URL, at date: Date = .now) {
        let path = url.standardizedFileURL.path
        items.removeAll { $0.path == path }
        items.insert(RecentProject(path: path, lastOpened: date), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        persist()
    }

    public func remove(_ project: RecentProject) {
        items.removeAll { $0.path == project.path }
        persist()
    }

    /// Drops entries whose folders no longer exist.
    public func prune(fileManager: FileManager = .default) {
        let before = items.count
        items.removeAll { !fileManager.fileExists(atPath: $0.path) }
        if items.count != before { persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
