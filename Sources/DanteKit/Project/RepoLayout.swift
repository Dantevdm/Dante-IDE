import Foundation

/// The projects inside one repo: every folder with its own build file (a Go module, a .NET
/// project, a package.json…), and the groups they fall into at the first folder where they part
/// ways (`v1/` holding two Go tools, `v2/` a .NET service). A repo can carry an old and a new
/// generation side by side, in different languages, and the Map shows one group at a time.
public struct RepoLayout: Equatable, Sendable {
    public struct Project: Equatable, Sendable, Identifiable {
        /// The folder, relative to the repo root ("" for the root).
        public var path: String
        public var name: String
        /// "Go", ".NET", "Node", "Java", "Python", "Rust"…
        public var stack: String
        public var id: String { path }
    }

    public struct Group: Equatable, Sendable, Identifiable {
        /// The folder that holds the group's projects.
        public var path: String
        public var name: String
        public var projects: [Project]
        public var id: String { path }

        /// "2 Go projects", "Go and Node", ".NET".
        public var summary: String {
            let stacks = projects.reduce(into: [String]()) { if !$0.contains($1.stack) { $0.append($1.stack) } }
            if stacks.count == 1 { return projects.count == 1 ? stacks[0] : "\(projects.count) \(stacks[0]) projects" }
            return stacks.dropLast().joined(separator: ", ") + " and " + stacks.last!
        }
    }

    public var projects: [Project]
    public var groups: [Group]

    public init(projects: [Project] = [], groups: [Group] = []) {
        self.projects = projects
        self.groups = groups
    }

    /// Worth a choice of what to show: two groups or more.
    public var hasGroups: Bool { groups.count >= 2 }

    static let manifests: [(name: String, stack: String)] = [
        ("go.mod", "Go"), ("package.json", "Node"), ("pom.xml", "Java"), ("build.gradle", "Java"), ("build.gradle.kts", "Kotlin"),
        ("Cargo.toml", "Rust"), ("pyproject.toml", "Python"), ("requirements.txt", "Python"), ("setup.py", "Python"), ("Gemfile", "Ruby"),
        ("composer.json", "PHP"), ("mix.exs", "Elixir"), ("Package.swift", "Swift"), ("module.yaml", "Kotlin"),
    ]
    static let skipped: Set<String> = ["node_modules", "vendor", "bin", "obj", "build", "dist", "target", "out", "testdata", "fixtures", "examples", "Pods"]

    public static func detect(files: [String]) -> RepoLayout {
        var found: [String: Project] = [:]
        for file in files {
            let parts = file.split(separator: "/").map(String.init)
            guard parts.count <= 6, !parts.dropLast().contains(where: { skipped.contains($0) || $0.hasPrefix(".") }), let last = parts.last else { continue }
            let stack: String? = last.hasSuffix(".csproj") || last.hasSuffix(".sln") || last.hasSuffix(".fsproj") ? ".NET"
                : manifests.first { $0.name == last }?.stack
            guard let stack else { continue }
            let folder = parts.dropLast().joined(separator: "/")
            // A .NET solution and its projects are one project, at the outermost folder.
            if found[folder] == nil { found[folder] = Project(path: folder, name: folder.isEmpty ? "root" : (folder as NSString).lastPathComponent, stack: stack) }
        }
        // A project inside another (a React app in a Go tool's folder, a .NET project under its
        // solution) belongs to the outer one.
        let paths = found.keys.sorted()
        let outer = paths.filter { path in !paths.contains { other in other != path && (other.isEmpty || path.hasPrefix(other + "/")) } }
        let projects = outer.compactMap { found[$0] }
        return RepoLayout(projects: projects, groups: groups(of: projects))
    }

    /// The projects split at the first folder where they differ. A group of one project is
    /// named after its top folder when that differs from the project's own.
    static func groups(of projects: [Project]) -> [Group] {
        guard projects.count >= 2, !projects.contains(where: { $0.path.isEmpty }) else { return [] }
        let split = projects.map { $0.path.split(separator: "/").map(String.init) }
        var depth = 0
        while split.allSatisfy({ $0.count > depth + 1 }), Set(split.map { $0[depth] }).count == 1 { depth += 1 }
        var order: [String] = []
        var members: [String: [Project]] = [:]
        for (project, parts) in zip(projects, split) {
            let key = parts.prefix(depth + 1).joined(separator: "/")
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(project)
        }
        guard order.count >= 2 else { return [] }
        return order.map { key in Group(path: key, name: (key as NSString).lastPathComponent, projects: members[key] ?? []) }
    }

    /// The group a file belongs to.
    public func group(of path: String) -> Group? {
        groups.first { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    /// The files under a group's folder.
    public static func files(_ files: [String], in folder: String) -> [String] {
        folder.isEmpty ? files : files.filter { $0.hasPrefix(folder + "/") }
    }
}

extension SystemMap {
    /// The whole repo's map with each part saying which group it's from ("V1 · 3 files"),
    /// so two groups' parts of the same name (each with its own `db`) can be told apart.
    public func labelled(by layout: RepoLayout) -> SystemMap {
        guard layout.hasGroups else { return self }
        var map = self
        for index in map.parts.indices {
            guard let path = map.parts[index].path, let group = layout.group(of: path) else { continue }
            map.parts[index].detail = map.parts[index].detail.isEmpty ? group.name : "\(group.name) · \(map.parts[index].detail)"
        }
        return map
    }
}
