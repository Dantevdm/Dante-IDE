import Foundation

/// Opening a part of the map: the pieces inside it (packages, folders) with the imports
/// between them, and the routes, tables and services each one owns. Pure; `read` returns a
/// file's text.
extension ArchitectureGraph {
    /// The pieces inside `root`: the folders under the source root (`src/main/java/<package>`,
    /// `src`), one level down, with an edge wherever one imports another.
    public static func inner(files: [String], root: String, read: (String) -> String?) -> ArchitectureGraph? {
        guard let (base, found) = pieces(files: files, root: root) else { return nil }
        var pieces = found
        // Many small folders: the biggest keep a box each, the rest share one.
        if pieces.count > 16 {
            let kept = Set(pieces.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }.prefix(15).map(\.key))
            var other: [String] = []
            for (key, value) in pieces where !kept.contains(key) {
                other += value
                pieces[key] = nil
            }
            pieces["…"] = other
        }

        var texts: [String: String] = [:]
        func text(_ file: String) -> String {
            if let known = texts[file] { return known }
            let value = read(file) ?? ""
            texts[file] = value
            return value
        }
        let files_ = Self.byFile(pieces)
        // Imports name files without their extension.
        let stems = Dictionary(pieces.keys.filter { $0 != "…" }.map { (($0 as NSString).deletingPathExtension, $0) }) { a, _ in a }
        func piece(of file: String) -> String? {
            if files_ { return pieces[file] != nil ? file : stems[file] ?? stems[file + "/index"] }
            // A module path names the folder itself (`backend/core` for `from backend.core import db`).
            return pieces.keys.filter { $0 != "…" && (file == $0 || ($0 == base ? (file as NSString).deletingLastPathComponent == base : file.hasPrefix($0 + "/"))) }.max { $0.count < $1.count }
                ?? (pieces["…"]?.contains(file) == true ? "…" : nil)
        }

        let javaRoot = jvmSourceRoot(of: base)
        let goModule = Self.goModule(files: files, root: root, read: read)
        var edges: Set<Edge> = []
        for (key, members) in pieces {
            for file in members {
                for target in imports(of: file, text: text(file), javaRoot: javaRoot, base: base, goModule: goModule) {
                    let folder: String? = files_ ? nil : pieces.keys.first { $0 != "…" && $0 != base && (target == $0 || target.hasPrefix($0 + "/")) }
                    guard let other = piece(of: target) ?? folder, other != key else { continue }
                    edges.insert(Edge(from: key, to: other))
                }
            }
        }
        // Classes in one package name each other without importing.
        if files_ {
            let named = Dictionary(pieces.keys.filter { $0 != "…" && SystemMap.namesTypes($0) }.map { (SystemMap.stem($0), $0) }) { a, _ in a }
            for key in pieces.keys where key != "…" && SystemMap.namesTypes(key) {
                let words = SystemMap.identifiers(text(key))
                for (name, other) in named where other != key && words.contains(name) { edges.insert(Edge(from: key, to: other)) }
            }
        }
        let nodes = pieces.keys.sorted().map { key -> Node in
            let members = pieces[key]!
            if files_, key != "…" {
                return Node(id: key, name: SystemMap.stem(key), kind: isEntryPoint(key, text: text(key)) ? .app : .library, path: key,
                            detail: SystemMap.fileRole(key, text: text(key)))
            }
            let isEntry = key == base || members.contains { isEntryPoint($0, text: text($0)) }
            let name = key == "…" ? "Other" : key == base ? ((base as NSString).lastPathComponent.nonEmptyName ?? "root") : (key as NSString).lastPathComponent
            return Node(id: key, name: name, kind: isEntry ? .app : .library, path: key == "…" ? nil : key,
                        detail: role(of: members, text: text) ?? "\(members.count) file\(members.count == 1 ? "" : "s")")
        }
        var graph = ArchitectureGraph(title: (root as NSString).lastPathComponent, source: "folders and imports", nodes: nodes, edges: edges.sorted { ($0.from, $0.to) < ($1.from, $1.to) })
        graph.base = base
        return graph
    }

    /// The pieces inside `root`, by folder below its source base (files right in the base
    /// are its own piece, the entry point). Nil with fewer than two.
    static func pieces(files: [String], root: String) -> (base: String, pieces: [String: [String]])? {
        let prefix = root.isEmpty ? "" : root + "/"
        let code = files.filter { $0.hasPrefix(prefix) && SystemMap.isCode($0) }
        guard code.count >= 2 else { return nil }
        let base = sourceBase(of: code, root: root)
        var pieces: [String: [String]] = [:]
        for file in code where file.hasPrefix(base.isEmpty ? "" : base + "/") {
            let relative = base.isEmpty ? file : String(file.dropFirst(base.count + 1))
            let parts = relative.split(separator: "/")
            pieces[parts.count > 1 ? (base.isEmpty ? "" : base + "/") + parts[0] : base, default: []].append(file)
        }
        if pieces.count >= 2 { return (base, pieces) }
        // A folder of files (controllers/, a package): each file is a piece of its own.
        guard code.count <= 60 else { return nil }
        return (root, Dictionary(uniqueKeysWithValues: code.map { ($0, [$0]) }))
    }

    /// Whether the pieces are single files rather than folders.
    static func byFile(_ pieces: [String: [String]]) -> Bool {
        pieces.allSatisfy { $0.key == "…" || ($0.value == [$0.key] && SystemMap.isCode($0.key)) }
    }

    /// The Go module the folder sits in: its path and go.mod's folder.
    static func goModule(files: [String], root: String, read: (String) -> String?) -> (path: String, folder: String)? {
        let prefix = root.isEmpty ? "" : root + "/"
        let mods = files.filter { file in
            guard (file as NSString).lastPathComponent == "go.mod" else { return false }
            let folder = (file as NSString).deletingLastPathComponent
            return root.isEmpty || file.hasPrefix(prefix) || folder.isEmpty || prefix.hasPrefix(folder + "/")
        }
        guard let mod = mods.max(by: { $0.count < $1.count }), let text = read(mod),
              let match = text.firstMatch(of: /(?m)^module\s+(\S+)/) else { return nil }
        return (String(match.1), (mod as NSString).deletingLastPathComponent)
    }

    /// Where the code starts: the package folder under `src/main/java` (the longest one all
    /// files share), else the folder nearly all code sits in (`src`), else `root`.
    static func sourceBase(of code: [String], root: String) -> String {
        var base = root
        let jvm = code.filter { $0.contains("/src/main/java/") || $0.contains("/src/main/kotlin/") || $0.hasPrefix("src/main/") }
        if jvm.count * 2 > code.count {
            let folders = jvm.map { ($0 as NSString).deletingLastPathComponent }
            return commonFolder(folders)
        }
        // Down into a folder holding almost everything; the few files left are tooling.
        while true {
            let prefix = base.isEmpty ? "" : base + "/"
            let below = code.filter { $0.hasPrefix(prefix) }
            var counts: [String: Int] = [:]
            for file in below {
                let rest = file.dropFirst(prefix.count).split(separator: "/")
                if rest.count > 1 { counts[String(rest[0]), default: 0] += 1 }
            }
            // The only folder with code (loose files beside it are config), or nearly all of it.
            guard let (folder, count) = counts.max(by: { $0.value < $1.value }), below.count - count <= 6,
                  counts.count == 1 || Double(count) >= Double(below.count) * 0.9 else { return base }
            // Only when the folder itself has more than one piece inside; otherwise it is the piece.
            let inner = Set(below.filter { $0.hasPrefix(prefix + folder + "/") }.compactMap { file -> String? in
                let rest = file.dropFirst((prefix + folder + "/").count).split(separator: "/")
                return rest.count > 1 ? String(rest[0]) : nil
            })
            guard !inner.isEmpty else { return base }
            base = prefix + folder
        }
    }

    static func commonFolder(_ folders: [String]) -> String {
        guard var common = folders.first?.split(separator: "/").map(String.init) else { return "" }
        for folder in folders.dropFirst() {
            let parts = folder.split(separator: "/").map(String.init)
            var shared = 0
            while shared < min(common.count, parts.count), common[shared] == parts[shared] { shared += 1 }
            common = Array(common.prefix(shared))
        }
        return common.joined(separator: "/")
    }

    /// "…/src/main/java" for a base inside one, so packages map to folders.
    static func jvmSourceRoot(of base: String) -> String? {
        for marker in ["src/main/java", "src/main/kotlin"] {
            if base == marker || base.hasPrefix(marker + "/") { return marker }
            if let range = base.range(of: "/" + marker) { return String(base[..<range.upperBound]) }
        }
        return nil
    }

    /// The repo paths a file imports from the project itself (folders or files, without
    /// extensions): Java and Kotlin packages, relative and `@/` JavaScript imports, Python
    /// modules, Go packages in the module.
    static func imports(of file: String, text: String, javaRoot: String?, base: String, goModule: (path: String, folder: String)?) -> [String] {
        let folder = (file as NSString).deletingLastPathComponent
        var found: [String] = []
        switch (file as NSString).pathExtension.lowercased() {
        case "java", "kt":
            guard let javaRoot else { return [] }
            for match in text.matches(of: /(?m)^\s*import\s+(?:static\s+)?([\w.]+)/) {
                found.append(javaRoot + "/" + match.1.replacingOccurrences(of: ".", with: "/"))
            }
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte":
            for match in text.matches(of: /(?:from\s+|import\s+|require\(\s*|import\(\s*)["']([.@][^"']*)["']/) {
                let spec = String(match.1)
                if spec.hasPrefix("@/") {
                    found.append(normalised(base + "/" + spec.dropFirst(2)))
                } else if spec.hasPrefix(".") {
                    found.append(normalised(folder + "/" + spec))
                }
            }
        case "py":
            for match in text.matches(of: /(?m)^\s*(?:from\s+(\.*[\w.]*)\s+import|import\s+([\w.]+))/) {
                let module = String(match.1 ?? match.2 ?? "")
                if module.hasPrefix(".") {
                    let dots = module.prefix { $0 == "." }.count
                    var target = folder
                    for _ in 1..<max(dots, 1) { target = (target as NSString).deletingLastPathComponent }
                    found.append(normalised(target + "/" + module.dropFirst(dots).replacingOccurrences(of: ".", with: "/")))
                } else {
                    let path = module.replacingOccurrences(of: ".", with: "/")
                    found.append(normalised(base + "/" + path))
                    found.append(normalised(((base as NSString).deletingLastPathComponent) + "/" + path))
                }
            }
        case "go":
            guard let goModule else { return [] }
            for path in goImports(text) where path.hasPrefix(goModule.path + "/") {
                found.append(normalised(goModule.folder + "/" + path.dropFirst(goModule.path.count + 1)))
            }
        default:
            break
        }
        return found
    }

    static func normalised(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == "..", !parts.isEmpty { parts.removeLast() } else { parts.append(part) }
        }
        return parts.joined(separator: "/")
    }

    static func isEntryPoint(_ file: String, text: String) -> Bool {
        let name = (file as NSString).lastPathComponent
        if ["main.go", "main.py", "__main__.py", "manage.py", "main.ts", "main.tsx", "main.js", "index.tsx", "App.tsx", "app.py", "main.rs", "Program.cs"].contains(name) { return true }
        return SystemMap.isJVM(file) && (SystemMap.has(text, "@SpringBootApplication") || SystemMap.has(text, "static void main("))
    }

    /// What a piece mostly is, when its files say so: "3 controllers", "5 services".
    static func role(of files: [String], text: (String) -> String) -> String? {
        let roles: [(marker: String, one: String, many: String)] = [
            ("@RestController", "controller", "controllers"), ("@Controller", "controller", "controllers"),
            ("@Service", "service", "services"), ("@Repository", "repository", "repositories"),
            ("@Entity", "entity", "entities"), ("@Configuration", "configuration", "configurations"),
            ("@Component", "component", "components"),
        ]
        let jvm = files.filter(SystemMap.isJVM)
        guard !jvm.isEmpty else { return nil }
        for role in roles {
            let count = jvm.filter { SystemMap.has(text($0), role.marker) }.count
            if count * 2 >= jvm.count { return "\(count) \(count == 1 ? role.one : role.many) · \(files.count) file\(files.count == 1 ? "" : "s")" }
        }
        return nil
    }
}

extension SystemMap {
    /// Whether a part can be opened: code with a folder of its own and smaller pieces in it.
    /// The entry piece of an opened part (its loose files) has nothing further inside.
    /// Tables open into the code that reaches them; a file into its methods (with `read`,
    /// only when it has two or more).
    public func opens(_ part: Part, files: [String], read: ((String) -> String?)? = nil) -> Bool {
        guard !entries.contains(part.id) else { return false }
        if part.kind == .table { return true }
        guard let path = part.path else { return false }
        if Self.isCode(path) {
            guard part.id.hasPrefix("code:") else { return false }
            guard let read else { return true }
            return read(path).map { Self.members(of: path, text: $0).count >= 2 } ?? false
        }
        guard part.lane == .backend || (part.lane == .clients && part.id.hasPrefix("client:")) else { return false }
        return ArchitectureGraph.pieces(files: files, root: path == "." ? "" : path) != nil
    }

    /// The map inside `part`: its pieces (from `ArchitectureGraph.inner`) in the middle lane,
    /// the routes they serve, the tables and stores they use and the services they call.
    /// Nil when it has nothing inside worth opening.
    public static func inside(_ part: Part, files: [String], read: (String) -> String?) -> SystemMap? {
        if part.kind == .table { return trace(table: part.name, files: files, read: read) }
        guard let path = part.path else { return nil }
        if isCode(path) { return inside(file: path, files: files, read: read) }
        let root = path == "." ? "" : path
        let prefix = root.isEmpty ? "" : root + "/"
        guard let graph = ArchitectureGraph.inner(files: files, root: root, read: read) else { return nil }
        // Its own files, plus SQL anywhere (schemas often live in a folder of their own).
        let subset = files.filter { $0.hasPrefix(prefix) || ($0 as NSString).pathExtension.lowercased() == "sql" }
        // Narrow the picture, but keep security configuration outside the opened folder.
        let accessRules = AccessRules.load(files: files, read: read)
        var map = build(files: subset, read: read, modules: graph, findsClients: false, accessRules: accessRules)
        map.laneTitles[.backend] = "Inside \(part.name)"
        if let base = graph.base { map.entries = Set(map.parts.filter { $0.lane == .backend && ($0.path == base || $0.path == nil) }.map(\.id)) }
        // Only what these pieces touch: the whole schema beside a folder of controllers is noise.
        let linked = Set(map.links.flatMap { [$0.from, $0.to] })
        map.parts.removeAll { $0.lane != .backend && !linked.contains($0.id) }
        for index in map.parts.indices where map.parts[index].lane == .backend && map.parts[index].kind == .package && map.parts[index].path.map(isCode) == true {
            map.parts[index].kind = .structure
        }
        return map
    }
}

private extension String {
    var nonEmptyName: String? { isEmpty ? nil : self }
}
