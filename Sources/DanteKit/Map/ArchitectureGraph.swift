import Foundation

/// The project as boxes and arrows for the Map area, built from what the repo already
/// declares: SwiftPM targets, Docker Compose services, or top-level source folders.
public struct ArchitectureGraph: Equatable, Sendable {
    public struct Node: Equatable, Sendable, Identifiable, Hashable {
        public enum Kind: String, Sendable {
            case app, library, test, service, external, folder
        }

        public var id: String
        public var name: String
        public var kind: Kind
        /// Project-relative folder, when the node lives in the repo.
        public var path: String?
        /// A short second line: file count, image, or package URL.
        public var detail: String

        public init(id: String, name: String, kind: Kind, path: String? = nil, detail: String = "") {
            self.id = id
            self.name = name
            self.kind = kind
            self.path = path
            self.detail = detail
        }
    }

    public struct Edge: Equatable, Sendable, Hashable {
        public var from: String
        public var to: String
    }

    public var title: String
    /// Where the graph came from, shown under the title.
    public var source: String
    public var nodes: [Node]
    public var edges: [Edge]
    /// For a part's inside (`inner`): the folder its loose files sit in.
    public var base: String?

    public init(title: String, source: String, nodes: [Node], edges: [Edge]) {
        self.title = title
        self.source = source
        self.nodes = nodes
        self.edges = edges
    }

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    public func dependencies(of id: String) -> [Node] { edges.filter { $0.from == id }.compactMap { node($0.to) } }
    public func dependents(of id: String) -> [Node] { edges.filter { $0.to == id }.compactMap { node($0.from) } }

    /// Without the test nodes and their edges.
    public var withoutTests: ArchitectureGraph {
        let tests = Set(nodes.filter { $0.kind == .test }.map(\.id))
        return ArchitectureGraph(title: title, source: source, nodes: nodes.filter { !tests.contains($0.id) },
                                 edges: edges.filter { !tests.contains($0.from) && !tests.contains($0.to) })
    }

    /// Columns for a left-to-right layout: things that depend on others sit left of what
    /// they use, so arrows point right. Each node goes one column past its furthest dependent.
    public var columns: [[Node]] {
        var depth: [String: Int] = [:]
        func visit(_ id: String, _ seen: Set<String>) -> Int {
            if let known = depth[id] { return known }
            let parents = edges.filter { $0.to == id && !seen.contains($0.from) }.map(\.from)
            let value = parents.map { visit($0, seen.union([id])) + 1 }.max() ?? 0
            depth[id] = value
            return value
        }
        for node in nodes { _ = visit(node.id, []) }
        // External packages line up in the last column, past everything in the repo.
        let internalDepth = nodes.filter { $0.kind != .external }.compactMap { depth[$0.id] }.max() ?? 0
        for node in nodes where node.kind == .external { depth[node.id] = internalDepth + 1 }
        let count = (depth.values.max() ?? 0) + 1
        var columns = Array(repeating: [Node](), count: count)
        for node in nodes { columns[depth[node.id] ?? 0].append(node) }
        return columns.map { column in
            column.sorted { ($0.kind == .external ? 1 : 0, $0.name) < ($1.kind == .external ? 1 : 0, $1.name) }
        }.filter { !$0.isEmpty }
    }

    // MARK: Sources

    /// From `swift package describe --type json`.
    public static func swiftPackage(describeJSON json: String) -> ArchitectureGraph? {
        guard let root = JSONValue(line: json), let targets = root["targets"]?.array else { return nil }
        var nodes: [Node] = []
        var edges: [Edge] = []
        var externals: [String: String] = [:]
        for dependency in root["dependencies"]?.array ?? [] {
            if let identity = dependency["identity"]?.string {
                externals[identity] = dependency["url"]?.string.map { URL(string: $0)?.host() ?? $0 } ?? ""
            }
        }
        for target in targets {
            guard let name = target["name"]?.string else { continue }
            let type = target["type"]?.string ?? "library"
            let sources = target["sources"]?.int ?? target["sources"]?.array?.count ?? 0
            let kind: Node.Kind = type == "test" ? .test : (type == "executable" ? .app : .library)
            nodes.append(Node(id: name, name: name, kind: kind, path: target["path"]?.string, detail: "\(sources) file\(sources == 1 ? "" : "s")"))
            for dependency in target["target_dependencies"]?.array ?? [] {
                if let to = dependency.string { edges.append(Edge(from: name, to: to)) }
            }
            for dependency in target["product_dependencies"]?.array ?? [] {
                guard let product = dependency.string else { continue }
                if !nodes.contains(where: { $0.id == "pkg:" + product }) {
                    let host = externals[product.lowercased()] ?? "package"
                    nodes.append(Node(id: "pkg:" + product, name: product, kind: .external, detail: host))
                }
                edges.append(Edge(from: name, to: "pkg:" + product))
            }
        }
        // Externals were appended as found; keep them after the targets.
        nodes.sort { ($0.kind == .external ? 1 : 0) < ($1.kind == .external ? 1 : 0) }
        return ArchitectureGraph(title: root["name"]?.string ?? "Package", source: "Package.swift", nodes: nodes, edges: edges)
    }

    public static func compose(_ file: ComposeFile) -> ArchitectureGraph {
        let nodes = file.services.map { service in
            Node(id: service.name, name: service.name, kind: service.build != nil ? .app : .service, path: service.build, detail: service.image ?? "build \(service.build ?? ".")")
        }
        let edges = file.services.flatMap { service in service.dependsOn.map { Edge(from: service.name, to: $0) } }
        return ArchitectureGraph(title: "Services", source: file.url.lastPathComponent, nodes: nodes, edges: edges)
    }

    /// Files that make their folder a project of its own.
    static let projectManifests: Set<String> = ["package.json", "build.gradle", "build.gradle.kts", "pom.xml", "go.mod", "Cargo.toml", "pyproject.toml", "setup.py", "Gemfile", "composer.json", "mix.exs"]

    /// For stacks Dante can't read yet: the folders that hold code, under a source root
    /// (Sources, src, lib…) when there is one, else at the top of the repo.
    public static func folders(_ paths: [String]) -> ArchitectureGraph? {
        let roots = ["Sources", "src", "lib", "app", "packages", "apps", "services", "cmd", "internal", "pkg"]
        let code: Set<String> = ["swift", "go", "rs", "py", "js", "ts", "tsx", "jsx", "rb", "java", "kt", "cs", "php", "c", "cc", "cpp", "m"]
        let skipped: Set<String> = ["docs", "doc", "data", "bin", "build", "dist", "public", "static", "assets", "vendor", "node_modules", "tests", "test", "scripts", "design"]
        var counts: [String: Int] = [:]
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 2, code.contains((path as NSString).pathExtension.lowercased()) else { continue }
            if parts.count >= 3, roots.contains(parts[0]) {
                counts[parts[0] + "/" + parts[1], default: 0] += 1
            } else if !parts[0].hasPrefix("."), !skipped.contains(parts[0].lowercased()), !roots.contains(parts[0]) {
                counts[parts[0], default: 0] += 1
            }
        }
        // A folder that only groups projects (services/java holding two Gradle builds) gives
        // way to the projects in it, each counted on its own.
        let projects = Set(paths.filter { projectManifests.contains(($0 as NSString).lastPathComponent) || $0.hasSuffix(".csproj") }
            .map { ($0 as NSString).deletingLastPathComponent })
        for folder in Array(counts.keys) where !projects.contains(folder) {
            let inner = projects.filter { $0.hasPrefix(folder + "/") }
            let outermost = inner.filter { project in !inner.contains { $0 != project && project.hasPrefix($0 + "/") } }
            guard !outermost.isEmpty else { continue }
            counts[folder] = nil
            for project in outermost {
                let files = paths.filter { $0.hasPrefix(project + "/") && code.contains(($0 as NSString).pathExtension.lowercased()) }.count
                if files > 0 { counts[project] = files }
            }
        }
        // A source root wins over loose top-level folders.
        let rooted = counts.keys.filter { $0.contains("/") }
        let chosen = rooted.isEmpty ? Array(counts.keys) : rooted
        guard !chosen.isEmpty else { return nil }
        let nodes = chosen.sorted().map { folder in
            Node(id: folder, name: (folder as NSString).lastPathComponent, kind: .folder, path: folder, detail: "\(counts[folder]!) files")
        }
        return ArchitectureGraph(title: "Folders", source: "source folders", nodes: nodes, edges: [])
    }

    /// Go packages from every `go.mod` and the imports in each package's files: which package
    /// uses which, and the outside modules they pull in. A repo with several modules (one per
    /// tool) gets them all. `read` returns a file's text.
    public static func goModules(files: [String], read: (String) -> String?) -> ArchitectureGraph? {
        let mods = files.filter { ($0 as NSString).lastPathComponent == "go.mod" && !$0.split(separator: "/").contains { ["vendor", "node_modules", "testdata"].contains(String($0)) } }
            .sorted { ($0.count, $0) < ($1.count, $1) }
        guard mods.count > 1 else { return mods.first.flatMap { goModule(modFile: $0, files: files, read: read) } }
        let folders = mods.map { ($0 as NSString).deletingLastPathComponent }
        let graphs = mods.compactMap { mod -> ArchitectureGraph? in
            let folder = (mod as NSString).deletingLastPathComponent
            // A module's files stop where a module inside it starts.
            let inner = folders.filter { $0 != folder && (folder.isEmpty || $0.hasPrefix(folder + "/")) }
            let own = files.filter { file in !inner.contains { file.hasPrefix($0 + "/") } }
            return goModule(modFile: mod, files: own, read: read)
        }
        return merged(graphs, title: "Go modules", source: "\(graphs.count) go.mod files and imports")
    }

    /// Several graphs as one: nodes by id (outside modules once), edges from all.
    static func merged(_ graphs: [ArchitectureGraph], title: String, source: String) -> ArchitectureGraph? {
        guard !graphs.isEmpty else { return nil }
        if graphs.count == 1 { return graphs[0] }
        var nodes: [Node] = []
        var seen: Set<String> = []
        for node in graphs.flatMap(\.nodes) where seen.insert(node.id).inserted { nodes.append(node) }
        let edges = Set(graphs.flatMap(\.edges)).sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        nodes.sort { ($0.kind == .external ? 1 : 0, $0.id) < ($1.kind == .external ? 1 : 0, $1.id) }
        return ArchitectureGraph(title: title, source: source, nodes: nodes, edges: edges)
    }

    /// .NET projects (`.csproj`, `.fsproj`) and the projects each references: an app for a
    /// web, worker or console project, a library otherwise, tests for test projects.
    public static func dotnetProjects(files: [String], read: (String) -> String?) -> ArchitectureGraph? {
        let projects = files.filter { ($0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj")) && !$0.split(separator: "/").contains { ["bin", "obj"].contains(String($0)) } }.sorted()
        guard !projects.isEmpty else { return nil }
        let folders = projects.map { ($0 as NSString).deletingLastPathComponent }
        var nodes: [Node] = []
        var edges: [Edge] = []
        for (project, folder) in zip(projects, folders) {
            let text = read(project) ?? ""
            let name = ((project as NSString).lastPathComponent as NSString).deletingPathExtension
            let inner = folders.filter { $0 != folder && (folder.isEmpty || $0.hasPrefix(folder + "/")) }
            let prefix = folder.isEmpty ? "" : folder + "/"
            let sources = files.filter { file in
                file.hasPrefix(prefix) && [".cs", ".fs"].contains { file.hasSuffix($0) } && !inner.contains { file.hasPrefix($0 + "/") }
                    && !file.split(separator: "/").contains { ["bin", "obj"].contains(String($0)) }
            }.count
            let isTest = text.contains("Microsoft.NET.Test.Sdk") || text.contains("<IsTestProject>true")
            let kind: String
            if text.contains("Microsoft.NET.Sdk.Web") { kind = "ASP.NET Core" }
            else if text.contains("Microsoft.NET.Sdk.Worker") { kind = "worker" }
            else if text.contains("<OutputType>Exe") || text.contains("<OutputType>WinExe") { kind = "console app" }
            else { kind = isTest ? "tests" : "library" }
            let isApp = ["ASP.NET Core", "worker", "console app"].contains(kind) && !isTest
            nodes.append(Node(id: "dotnet:" + project, name: name, kind: isTest ? .test : isApp ? .app : .library, path: folder.isEmpty ? "." : folder,
                              detail: "\(sources) file\(sources == 1 ? "" : "s") · \(kind)"))
            for match in text.matches(of: /<ProjectReference\s+Include\s*=\s*"([^"]+)"/) {
                let target = normalisedProjectPath(folder: folder, include: String(match.1))
                if projects.contains(target) { edges.append(Edge(from: "dotnet:" + project, to: "dotnet:" + target)) }
            }
        }
        return ArchitectureGraph(title: ".NET projects", source: "\(projects.count) project file\(projects.count == 1 ? "" : "s") and their references", nodes: nodes, edges: edges)
    }

    /// `..\\Shop.Core\\Shop.Core.csproj` from `src/Shop.Api` → `src/Shop.Core/Shop.Core.csproj`.
    static func normalisedProjectPath(folder: String, include: String) -> String {
        var parts = folder.split(separator: "/").map(String.init)
        for part in include.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else if part != "." { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }

    /// A repo holding projects in more than one stack, or several projects of one (two Go
    /// tools beside a .NET service): every Go module and .NET project, plus a folder for each
    /// other project, so none is left off the map. Nil when one stack's graph covers it.
    public static func projects(files: [String], read: (String) -> String?) -> ArchitectureGraph? {
        let dotnet = dotnetProjects(files: files, read: read)
        let go = goModules(files: files, read: read)
        guard dotnet != nil || go != nil else { return nil }
        // Folders those cover; anything else with a manifest gets a folder node.
        let covered = Set((dotnet?.nodes ?? []).compactMap(\.path) + (go?.nodes.filter { $0.kind == .app || $0.kind == .library }.compactMap(\.path) ?? []))
        let goRoots = files.filter { ($0 as NSString).lastPathComponent == "go.mod" }.map { ($0 as NSString).deletingLastPathComponent }
        let dotnetRoots = (dotnet?.nodes ?? []).compactMap(\.path)
        let rest = files.filter { file in
            ![goRoots, dotnetRoots].joined().contains { root in root.isEmpty || root == "." || file.hasPrefix(root + "/") } && !covered.contains((file as NSString).deletingLastPathComponent)
        }
        let others = rest.isEmpty ? nil : folders(rest).map { graph in
            ArchitectureGraph(title: graph.title, source: graph.source, nodes: graph.nodes.filter { node in
                // A folder that only holds the projects above isn't one of its own.
                guard let path = node.path else { return true }
                return !goRoots.contains { $0.hasPrefix(path + "/") } && !dotnetRoots.contains { $0.hasPrefix(path + "/") }
            }, edges: graph.edges)
        }
        let parts = [go, dotnet, others].compactMap { $0 }.filter { !$0.nodes.isEmpty }
        guard parts.count > 1 || dotnet != nil else { return nil }
        let sources = [go.map { _ in "go.mod" }, dotnet.map { _ in "project files" }, others.map { _ in "folders" }].compactMap { $0 }
        return merged(parts, title: "Projects", source: sources.joined(separator: ", ") + " and imports")
    }

    /// One Go module's packages.
    static func goModule(modFile: String, files: [String], read: (String) -> String?) -> ArchitectureGraph? {
        guard let mod = read(modFile),
              let module = mod.firstMatch(of: /(?m)^module\s+(\S+)/).map({ String($0.1) }) else { return nil }
        let base = (modFile as NSString).deletingLastPathComponent
        let prefix = base.isEmpty ? "" : base + "/"
        var packages: [String: (files: Int, isMain: Bool, imports: Set<String>)] = [:]
        for file in files where file.hasSuffix(".go") && !file.hasSuffix("_test.go") && file.hasPrefix(prefix) {
            let relative = String(file.dropFirst(prefix.count))
            if relative.hasPrefix("vendor/") { continue }
            let folder = (relative as NSString).deletingLastPathComponent
            var entry = packages[folder] ?? (0, false, [])
            entry.files += 1
            if let text = read(file) {
                if goPackage(text) == "main" { entry.isMain = true }
                entry.imports.formUnion(goImports(text))
            }
            packages[folder] = entry
        }
        guard !packages.isEmpty else { return nil }
        func id(_ folder: String) -> String { folder.isEmpty ? module : module + "/" + folder }
        var nodes: [Node] = []
        var edges: Set<Edge> = []
        var externals: [String: Int] = [:]
        for (folder, info) in packages {
            // The root package is named by its folder (backend) or `main`, not the long module path.
            let name = folder.isEmpty ? (base.isEmpty ? (info.isMain ? "main" : (module as NSString).lastPathComponent) : (base as NSString).lastPathComponent)
                : (folder as NSString).lastPathComponent
            let path = folder.isEmpty ? (base.isEmpty ? "." : base) : prefix + folder
            nodes.append(Node(id: id(folder), name: name, kind: info.isMain ? .app : .library, path: path,
                              detail: "\(info.files) file\(info.files == 1 ? "" : "s")\(info.isMain ? " · main" : "")"))
            for path in info.imports {
                if path == module || path.hasPrefix(module + "/") {
                    let target = path == module ? "" : String(path.dropFirst(module.count + 1))
                    if packages[target] != nil, target != folder { edges.insert(Edge(from: id(folder), to: id(target))) }
                } else if let first = path.split(separator: "/").first, first.contains(".") {
                    // Outside modules, by their first three path parts (host/owner/repo).
                    let root = path.split(separator: "/").prefix(first.hasPrefix("github.com") || first.hasPrefix("gitlab.com") ? 3 : 2).joined(separator: "/")
                    externals[root, default: 0] += 1
                    edges.insert(Edge(from: id(folder), to: "ext:" + root))
                }
            }
        }
        for (root, _) in externals {
            nodes.append(Node(id: "ext:" + root, name: (root as NSString).lastPathComponent, kind: .external, detail: root))
        }
        nodes.sort { ($0.kind == .external ? 1 : 0, $0.id) < ($1.kind == .external ? 1 : 0, $1.id) }
        return ArchitectureGraph(title: (module as NSString).lastPathComponent, source: "\(modFile) and imports",
                                 nodes: nodes, edges: edges.sorted { ($0.from, $0.to) < ($1.from, $1.to) })
    }

    /// The import paths in a Go file: single imports and import blocks.
    /// The name in a Go file's package clause, which comes before any code. Read line by
    /// line: a regex over the whole file was slow on big repos.
    static func goPackage(_ text: String) -> String? {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("package ") || line.hasPrefix("package\t") else { continue }
            return line.dropFirst("package".count).trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "/" || $0 == ";" }).first.map(String.init)
        }
        return nil
    }

    static func goImports(_ text: String) -> Set<String> {
        var found: Set<String> = []
        var inBlock = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inBlock {
                if line.hasPrefix(")") { inBlock = false; continue }
                if let match = line.firstMatch(of: /"([^"]+)"/) { found.insert(String(match.1)) }
            } else if line.hasPrefix("import (") {
                inBlock = true
            } else if line.hasPrefix("import "), let match = line.firstMatch(of: /"([^"]+)"/) {
                found.insert(String(match.1))
            } else if line.hasPrefix("func ") || line.hasPrefix("type ") {
                break
            }
        }
        return found
    }

    /// Names that `notes` (usually `.dante/architecture.md`) never mentions.
    public func undocumented(in notes: String) -> [Node] {
        let lower = notes.lowercased()
        return nodes.filter { node in
            guard node.kind != .test && node.kind != .external, !lower.contains(node.name.lowercased()) else { return false }
            // A mention of its folder counts too (`backend/`, `internal/api`).
            let path = node.path?.lowercased() ?? ""
            return path.isEmpty || path == "." || !lower.contains(path)
        }
    }
}
