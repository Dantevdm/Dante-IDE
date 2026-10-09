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
        // A source root wins over loose top-level folders.
        let rooted = counts.keys.filter { $0.contains("/") }
        let chosen = rooted.isEmpty ? Array(counts.keys) : rooted
        guard !chosen.isEmpty else { return nil }
        let nodes = chosen.sorted().map { folder in
            Node(id: folder, name: (folder as NSString).lastPathComponent, kind: .folder, path: folder, detail: "\(counts[folder]!) files")
        }
        return ArchitectureGraph(title: "Folders", source: "source folders", nodes: nodes, edges: [])
    }

    /// Go packages from `go.mod` and the imports in each package's files: which package
    /// uses which, and the outside modules they pull in. `read` returns a file's text.
    public static func goModules(files: [String], read: (String) -> String?) -> ArchitectureGraph? {
        guard let modFile = files.filter({ ($0 as NSString).lastPathComponent == "go.mod" }).min(by: { $0.count < $1.count }),
              let mod = read(modFile),
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
                if text.contains(/(?m)^package\s+main\b/) { entry.isMain = true }
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
