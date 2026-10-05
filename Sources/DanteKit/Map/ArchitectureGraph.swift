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

    /// For stacks Dante can't read yet: the top-level folders under the source root.
    public static func folders(_ paths: [String]) -> ArchitectureGraph? {
        let roots = ["Sources", "src", "lib", "app", "packages", "apps", "services", "cmd", "internal", "pkg"]
        var counts: [String: Int] = [:]
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 3, roots.contains(parts[0]) else { continue }
            counts[parts[0] + "/" + parts[1], default: 0] += 1
        }
        guard !counts.isEmpty else { return nil }
        let nodes = counts.keys.sorted().map { folder in
            Node(id: folder, name: (folder as NSString).lastPathComponent, kind: .folder, path: folder, detail: "\(counts[folder]!) files")
        }
        return ArchitectureGraph(title: "Folders", source: "source folders", nodes: nodes, edges: [])
    }

    /// Names that `notes` (usually `.dante/architecture.md`) never mentions.
    public func undocumented(in notes: String) -> [Node] {
        let lower = notes.lowercased()
        return nodes.filter { $0.kind != .test && $0.kind != .external && !lower.contains($0.name.lowercased()) }
    }
}
