import Foundation

/// The whole system in lanes, left to right: the clients people use, the API routes they
/// call, the backend code behind the routes, the data it keeps, and the outside services it
/// talks to. Built from the code itself: route registrations, the paths a frontend fetches,
/// imports, and URLs, plus the compose file. Pure; `read` returns a file's text.
public struct SystemMap: Equatable, Sendable {
    public enum Lane: Int, CaseIterable, Sendable, Comparable {
        case clients, api, backend, data, outside

        public var title: String {
            switch self {
            case .clients: "Clients"
            case .api: "API"
            case .backend: "Backend"
            case .data: "Data"
            case .outside: "Outside services"
            }
        }

        public static func < (a: Lane, b: Lane) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Kind: String, Sendable {
        case web, mobile, routes, app, package, database, table, cache, container, email, messaging, ai, payments, storage, monitoring, service
    }

    /// A line inside a part: a screen, a route, a table. Routes keep where they're declared.
    public struct Item: Equatable, Sendable, Hashable {
        public var text: String
        public var file: String?
        public var line: Int?

        public init(_ text: String, file: String? = nil, line: Int? = nil) {
            self.text = text
            self.file = file
            self.line = line
        }
    }

    public struct Part: Identifiable, Equatable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var lane: Lane
        public var kind: Kind
        public var detail: String
        public var path: String?
        public var items: [Item]
        /// The compose service it runs in, when there is one.
        public var container: String?
        /// Environment variables it reads, by name only (from code and compose).
        public var env: [String] = []
        /// Incoming webhooks: routes in this group that outside services call.
        public var isWebhook = false

        public init(id: String, name: String, lane: Lane, kind: Kind, detail: String = "", path: String? = nil, items: [Item] = [], container: String? = nil) {
            self.id = id
            self.name = name
            self.lane = lane
            self.kind = kind
            self.detail = detail
            self.path = path
            self.items = items
            self.container = container
        }
    }

    public struct Link: Equatable, Sendable, Hashable {
        public var from: String
        public var to: String
        /// How many calls, imports or mentions it stands for.
        public var weight: Int

        public init(from: String, to: String, weight: Int = 1) {
            self.from = from
            self.to = to
            self.weight = weight
        }
    }

    public var parts: [Part]
    public var links: [Link]

    public init(parts: [Part], links: [Link]) {
        self.parts = parts
        self.links = links
    }

    public func part(_ id: String) -> Part? { parts.first { $0.id == id } }
    public func uses(_ id: String) -> [Part] { links.filter { $0.from == id }.compactMap { part($0.to) } }
    public func usedBy(_ id: String) -> [Part] { links.filter { $0.to == id }.compactMap { part($0.from) } }

    /// Lanes that have something in them, in order.
    public var lanes: [(lane: Lane, parts: [Part])] {
        Lane.allCases.compactMap { lane in
            let inLane = parts.filter { $0.lane == lane }
            return inLane.isEmpty ? nil : (lane, inLane)
        }
    }

    /// Worth showing over the plain module graph: it spans at least two lanes.
    public var isUseful: Bool { Set(parts.map(\.lane)).count >= 2 }

    public var routeCount: Int { parts.filter { $0.lane == .api }.reduce(0) { $0 + $1.items.count } }

    // MARK: Building

    static let codeExtensions: Set<String> = ["go", "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte", "py", "rb", "java", "kt", "cs", "php", "rs", "swift"]
    static let skippedFolders: Set<String> = ["node_modules", "vendor", "dist", "build", ".build", "public", "static", "target", "out", ".next", ".nuxt", "coverage", "Pods", ".venv", "venv", "__pycache__", "testdata", "fixtures"]
    static let frontendNames: Set<String> = ["frontend", "web", "webapp", "client", "ui", "app-web", "site", "www"]

    static func isTest(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        // Class-style names need the capital: "ParserTests.swift", but not "Latest.swift".
        let testNames = ["Tests.swift", "Test.swift", "Test.java", "Test.kt", "Tests.cs", "Test.cs", "_spec.rb", "_test.rb", "_test.py", "_test.exs"]
        let testFolders: Set<String> = ["tests", "test", "__tests__", "spec", "specs", "testdata", "fixtures", "__mocks__", "e2e"]
        return name.hasSuffix("_test.go") || name.contains(".test.") || name.contains(".spec.") || name.hasPrefix("test_")
            || testNames.contains { name.hasSuffix($0) && name.count > $0.count }
            || path.split(separator: "/").dropLast().contains { testFolders.contains($0.lowercased()) }
    }

    /// Files the map reads: code and the manifests that name frameworks and drivers.
    public static func isReadable(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return codeExtensions.contains((path as NSString).pathExtension.lowercased())
            || (path as NSString).pathExtension.lowercased() == "sql"
            || ["package.json", "go.mod", "requirements.txt", "pyproject.toml", "Cargo.toml", "Gemfile", "pubspec.yaml", "index.html", "schema.prisma", "pom.xml", "build.gradle"].contains(name)
    }

    /// Whether `body` holds `needle`, compared byte for byte. `String.contains` walks
    /// characters, which made the map take a minute on a repo of a few thousand files.
    static func has(_ body: some StringProtocol, _ needle: String) -> Bool {
        let found = body.utf8.withContiguousStorageIfAvailable { hay in
            needle.utf8.withContiguousStorageIfAvailable { word -> Bool in
                guard !word.isEmpty else { return true }
                guard hay.count >= word.count, let h = hay.baseAddress, let w = word.baseAddress else { return false }
                return memmem(h, hay.count, w, word.count) != nil
            }
        }
        return (found ?? nil) ?? body.contains(needle)
    }

    /// The lines of `text` that hold one of `needles` (and the line after each, with
    /// `andNext`), so a regex only scans the lines that could match.
    static func lines(of text: String, holding needles: [String], andNext: Bool = false) -> String {
        var kept: [Substring] = []
        var keepNext = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let holds = needles.contains { has(line, $0) }
            if holds || keepNext { kept.append(line) }
            keepNext = andNext && holds
        }
        return kept.joined(separator: "\n")
    }

    static func isCode(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard codeExtensions.contains((path as NSString).pathExtension.lowercased()) else { return false }
        return !parts.dropLast().contains { skippedFolders.contains($0) || $0.hasPrefix(".") } && !isTest(path)
    }

    public static func build(files: [String], read: (String) -> String?, compose: ComposeFile? = nil, modules: ArchitectureGraph? = nil) -> SystemMap {
        let code = files.filter(isCode)
        var parts: [Part] = []
        var links: [String: Link] = [:]
        func link(_ from: String, _ to: String, _ weight: Int = 1) {
            guard from != to else { return }
            links["\(from)→\(to)", default: Link(from: from, to: to, weight: 0)].weight += weight
        }
        var texts: [String: String] = [:]
        func text(_ path: String) -> String {
            if let known = texts[path] { return known }
            // Native UTF-8, so the byte searches below don't go through a bridged NSString.
            var value = read(path) ?? ""
            value.makeContiguousUTF8()
            texts[path] = value
            return value
        }
        var lowered: [String: String] = [:]
        func lower(_ path: String) -> String {
            if let known = lowered[path] { return known }
            var value = text(path).lowercased()
            value.makeContiguousUTF8()
            lowered[path] = value
            return value
        }

        // Clients
        let clients = frontends(files: files, read: read)
        func root(_ part: Part) -> String { part.path == "." ? "" : part.path ?? "" }
        let clientRoots = clients.map(root)
        var clientOf: [String: Part?] = [:]
        func clientOwning(_ path: String) -> Part? {
            if let known = clientOf[path] { return known }
            let found = clients.filter { root($0).isEmpty || path.hasPrefix(root($0) + "/") }.max { root($0).count < root($1).count }
            clientOf[path] = .some(found)
            return found
        }
        parts += clients

        // Backend: the module graph's own parts, minus anything inside a frontend.
        let backendFiles = code.filter { file in !clientRoots.contains { $0.isEmpty || file.hasPrefix($0 + "/") } }
        var backend: [Part] = []
        if let modules {
            let graph = modules.withoutTests
            let inside = graph.nodes.filter { node in
                guard node.kind != .external, node.kind != .test else { return false }
                let path = node.path ?? ""
                return !clientRoots.contains { !$0.isEmpty && (path == $0 || path.hasPrefix($0 + "/")) }
            }
            // Top of the lane is what runs first: order by the module graph's columns.
            let order = Dictionary(graph.columns.enumerated().flatMap { column, nodes in nodes.map { ($0.id, column) } }) { a, _ in a }
            backend = inside.sorted { (order[$0.id] ?? 0, $0.name) < (order[$1.id] ?? 0, $1.name) }.map { node in
                Part(id: "code:" + node.id, name: node.name, lane: .backend, kind: node.kind == .app ? .app : .package, detail: node.detail, path: node.path)
            }
            let ids = Set(inside.map(\.id))
            for edge in graph.edges where ids.contains(edge.from) && ids.contains(edge.to) {
                link("code:" + edge.from, "code:" + edge.to)
            }
        }
        if backend.isEmpty, !backendFiles.isEmpty {
            backend = [Part(id: "code:server", name: "server", lane: .backend, kind: .app, detail: "\(backendFiles.count) files")]
        }
        // By folder: every file in one folder has the same owner.
        var owners: [String: Part?] = [:]
        func owner(_ file: String) -> Part? {
            let folder = (file as NSString).deletingLastPathComponent
            if let known = owners[folder] { return known }
            let found = findOwner(folder)
            owners[folder] = .some(found)
            return found
        }
        func findOwner(_ folder: String) -> Part? {
            let candidates = backend.filter { part in
                guard let path = part.path else { return false }
                return path == "." ? !folder.contains("/") || folder.isEmpty : (folder == path || folder.hasPrefix(path + "/"))
            }
            return candidates.max { ($0.path ?? "").count < ($1.path ?? "").count } ?? (backend.count == 1 ? backend.first : nil)
        }

        // API routes, grouped by their first meaningful path segment.
        var webhookFiles: [(group: String, file: String)] = []
        var groups: [String: (items: [Item], owners: [String: Int])] = [:]
        for file in backendFiles {
            let found = routes(in: text(file))
            guard !found.isEmpty else { continue }
            let ownerID = owner(file)?.id
            for route in found where route.path != "/" {
                let key = routeGroup(route.path)
                // Mutated in place: copying the entry out and back copies its items each time.
                groups[key, default: ([], [:])].items.append(Item([route.method, route.path].compactMap { $0 }.joined(separator: " "), file: file, line: route.line))
                if let ownerID { groups[key, default: ([], [:])].owners[ownerID, default: 0] += 1 }
            }
        }
        if groups.count > 12 {
            // Ties go by name, so the same repo always keeps the same groups.
            let kept = groups.sorted { ($1.value.items.count, $0.key) < ($0.value.items.count, $1.key) }.prefix(11).map(\.key)
            var other: ([Item], [String: Int]) = ([], [:])
            for (key, value) in groups where !kept.contains(key) {
                other.0 += value.items
                other.1.merge(value.owners, uniquingKeysWith: +)
                groups[key] = nil
            }
            groups["…"] = other
        }
        for (key, value) in groups.sorted(by: { $0.key < $1.key }) {
            let methods = Array(Set(value.items.compactMap { $0.text.split(separator: " ").first.map(String.init) }.filter { $0.uppercased() == $0 && !$0.hasPrefix("/") }))
            let order = ["GET", "POST", "PUT", "PATCH", "DELETE"]
            let detail = "\(value.items.count) route\(value.items.count == 1 ? "" : "s")" + (methods.isEmpty ? "" : " · " + methods.sorted { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }.joined(separator: " "))
            let id = "route:" + key
            var part = Part(id: id, name: key == "…" ? "Other routes" : key, lane: .api, kind: .routes, detail: detail, items: value.items)
            let hooks = value.items.filter { isWebhookRoute($0.text) }
            if !hooks.isEmpty {
                part.isWebhook = true
                part.detail += " · webhook"
                for hook in hooks { if let file = hook.file { webhookFiles.append((id, file)) } }
            }
            parts.append(part)
            for (owner, count) in value.owners { link(id, owner, count) }
        }

        // What each client calls. A screen that calls the API gets a box of its own, so the
        // map shows which screens use which routes; calls from shared files stay on the app.
        for client in clients {
            let screenFiles = Dictionary(client.items.compactMap { item in item.file.map { ($0, item.text) } }) { a, _ in a }
            var screenCalls: [String: [String: Int]] = [:]
            for file in code where clientOwning(file)?.id == client.id {
                for path in calledPaths(in: text(file)) {
                    let key = routeGroup(path)
                    guard groups[key] != nil else { continue }
                    if let screen = screenFiles[file] {
                        screenCalls[screen, default: [:]]["route:" + key, default: 0] += 1
                    } else {
                        link(client.id, "route:" + key)
                    }
                }
            }
            guard screenCalls.count >= 2, screenCalls.count <= 24 else {
                for (_, calls) in screenCalls { for (route, count) in calls { link(client.id, route, count) } }
                continue
            }
            for item in client.items where screenCalls[item.text] != nil {
                let id = "screen:\(client.id):\(item.text)"
                let calls = screenCalls[item.text]!
                parts.append(Part(id: id, name: item.text, lane: .clients, kind: client.kind,
                                  detail: "\(client.name) · \(calls.count) route group\(calls.count == 1 ? "" : "s")", path: item.file, items: [item]))
                for (route, count) in calls { link(id, route, count) }
            }
        }
        parts += backend

        // Data
        let profile = DataDetector.detect(paths: files, compose: compose, read: read)
        var stores: [(id: String, name: String, kind: Kind, detail: String, words: [String])] = []
        for engine in profile.engines {
            let label = profile.signals.first { $0.engine == engine }?.label ?? ""
            let words: [String] = switch engine {
            case .postgres: ["postgres", "pgx", "lib/pq", "psycopg", "asyncpg"]
            case .mysql: ["mysql", "mariadb"]
            case .sqlite: ["sqlite"]
            }
            stores.append(("db:" + engine.rawValue, engine.name, .database, label, words))
        }
        for store in profile.otherStores {
            let lower = store.lowercased()
            let kind: Kind = lower.contains("redis") || lower.contains("memcache") ? .cache : .database
            stores.append(("db:" + lower, store, kind, "", [lower.components(separatedBy: " ").first ?? lower]))
        }
        // Tables, from CREATE TABLE in the repo's SQL and code (never from a live database),
        // with arrows from the packages whose queries name them.
        var tableNames: [String] = []
        let backendSet = Set(backendFiles)
        // Without a database in sight, CREATE TABLE in code is more likely an example or a
        // tool's own fixtures than this app's schema, so only .sql files count.
        let hasDatabase = !profile.engines.isEmpty || profile.otherStores.contains { !$0.lowercased().contains("redis") && !$0.lowercased().contains("memcache") }
        for file in files where (file as NSString).pathExtension.lowercased() == "sql" || (hasDatabase && backendSet.contains(file)) {
            guard !isTest(file), has(lower(file), "create table") else { continue }
            for table in tables(in: text(file)) where !tableNames.contains(table) { tableNames.append(table) }
        }
        var tableUsers: [String: [String: Int]] = [:]
        if !tableNames.isEmpty, let pattern = queryPattern(tableNames) {
            for file in backendFiles {
                let body = lower(file)
                guard has(body, "select") || has(body, "insert") || has(body, "update") || has(body, "delete"),
                      let owner = owner(file) else { continue }
                // Only lines with a keyword (and the line after, for "FROM" at a line's end).
                let query = lines(of: body, holding: ["from", "into", "update", "join", "table"], andNext: true)
                let range = NSRange(query.startIndex..., in: query)
                for match in pattern.matches(in: query, range: range) {
                    if let name = Range(match.range(at: 1), in: query).map({ String(query[$0]) }),
                       let table = tableNames.first(where: { $0.lowercased() == name }) {
                        tableUsers[table, default: [:]][owner.id, default: 0] += 1
                    }
                }
            }
        }
        let databases = stores.filter { $0.kind == .database }
        let tableHome = databases.count == 1 ? databases[0].name : nil
        let shownTables = tableNames.count <= 14 ? tableNames
            : Array(tableNames.sorted { (tableUsers[$0]?.values.reduce(0, +) ?? 0) > (tableUsers[$1]?.values.reduce(0, +) ?? 0) }.prefix(13))
        var ownersWithTables: Set<String> = []
        for table in shownTables {
            for (owner, _) in tableUsers[table] ?? [:] { ownersWithTables.insert(owner) }
        }

        for store in stores {
            let items = store.kind == .database && store.id == databases.first?.id ? tableNames.map { Item($0) } : []
            let detail = items.isEmpty ? store.detail : "\(items.count) table\(items.count == 1 ? "" : "s")" + (store.detail.isEmpty ? "" : " · " + store.detail)
            parts.append(Part(id: store.id, name: store.name, lane: .data, kind: store.kind, detail: detail, items: items))
            var linked = false
            for file in backendFiles {
                let body = lower(file)
                if store.words.contains(where: { has(body, $0) }), let owner = owner(file) {
                    linked = true
                    if !ownersWithTables.contains(owner.id) || store.kind != .database { link(owner.id, store.id) }
                }
            }
            if !linked { for part in backend where part.kind == .app { link(part.id, store.id) } }
        }
        for table in shownTables {
            let users = tableUsers[table] ?? [:]
            parts.append(Part(id: "table:" + table, name: table, lane: .data, kind: .table,
                              detail: [tableHome.map { "\($0) table" } ?? "table", users.isEmpty ? "no queries found" : nil].compactMap { $0 }.joined(separator: " · ")))
            for (owner, count) in users { link(owner, "table:" + table, count) }
        }

        // Outside services, from imports and URLs. Packages that only store settings (db,
        // models, migrations) mention hosts without calling them, so they don't count.
        let storageNames: Set<String> = ["db", "database", "store", "storage", "models", "model", "migrations", "migrate", "seed", "repository", "repo", "schema", "persistence"]
        let mentionsWhatsApp = backendFiles.contains { has(lower($0), "whatsapp") }
        // Which services each file names: by host, package or name in backend code, but only
        // by host or package in a client, where a bare word ("ollama") is usually a label on
        // a settings screen rather than the browser calling the service itself.
        let servicePatterns = outsideServices.map { service in
            let server = service.patterns.map { $0.lowercased() }
            return (server: server, client: server.filter { $0.contains(".") || $0.contains("/") || $0.contains("@") })
        }
        var named: [String: [Int]] = [:]
        for file in code {
            let body = lower(file)
            let inClient = clientOwning(file) != nil
            let hits = servicePatterns.indices.filter { index in
                (inClient ? servicePatterns[index].client : servicePatterns[index].server).contains { has(body, $0) }
            }
            // A file naming many services is a list of them (a tool's own catalogue, a
            // settings screen), not code that calls them all.
            if !hits.isEmpty, hits.count < 6 { named[file] = hits }
        }
        for (index, service) in outsideServices.enumerated() {
            var users: [String: Int] = [:]
            for file in code where named[file]?.contains(index) == true {
                if let client = clientOwning(file) {
                    users[client.id, default: 0] += 1
                } else if let owner = owner(file), !storageNames.contains(owner.name.lowercased()) {
                    users[owner.id, default: 0] += 1
                }
            }
            guard !users.isEmpty else { continue }
            let name = service.id == "meta" && mentionsWhatsApp ? "WhatsApp Cloud API" : service.name
            parts.append(Part(id: "ext:" + service.id, name: name, lane: .outside, kind: service.kind, detail: service.detail))
            for (user, count) in users { link(user, "ext:" + service.id, count) }
        }
        // Incoming webhooks: the service whose name or host the handler mentions calls the route.
        for (group, file) in webhookFiles {
            let body = lower(file)
            for service in outsideServices where parts.contains(where: { $0.id == "ext:" + service.id }) {
                if service.patterns.contains(where: { has(body, $0.lowercased()) }) || has(body, service.id + " webhook") {
                    link("ext:" + service.id, group)
                }
            }
        }

        // Containers: services built from the repo mark the parts they run; data images join
        // their store; anything else is a service of its own.
        for service in compose?.services ?? [] {
            if let context = service.build {
                let folder = context == "." || context == "./" ? "" : context.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
                for index in parts.indices where parts[index].lane == .backend || parts[index].lane == .clients {
                    let path = parts[index].path ?? ""
                    let inside = folder.isEmpty ? parts[index].lane == .backend : (path == folder || path.hasPrefix(folder + "/"))
                    if inside, parts[index].container == nil { parts[index].container = service.name }
                }
                continue
            }
            let image = (service.image ?? "").lowercased()
            let base = (image.split(separator: "/").last.map(String.init) ?? image).split(separator: ":").first.map(String.init) ?? image
            if let store = ["postgres": "db:postgres", "postgis": "db:postgres", "mysql": "db:mysql", "mariadb": "db:mysql"][base],
               let index = parts.firstIndex(where: { $0.id == store }) {
                parts[index].container = service.name
                continue
            }
            if let index = parts.firstIndex(where: { $0.lane != .backend && $0.lane != .clients && ($0.id.hasSuffix(":" + base) || $0.name.lowercased() == base) }) {
                parts[index].container = service.name
                continue
            }
            let known = outsideServices.first { $0.id == base }
            let isData = ["redis", "mongo", "memcached", "elasticsearch", "opensearch", "minio", "clickhouse", "cassandra", "valkey", "rabbitmq", "nats", "kafka"].contains(base)
            let id = "svc:" + service.name
            parts.append(Part(id: id, name: known?.name ?? service.name, lane: isData ? .data : .outside, kind: known?.kind ?? (isData ? .database : .container),
                              detail: service.image ?? "", container: service.name))
            for dependent in compose?.services ?? [] where dependent.dependsOn.contains(service.name) && dependent.build != nil {
                for part in parts where part.container == dependent.name && part.lane == .backend && part.kind == .app { link(part.id, id) }
            }
        }

        // Environment variables each part reads: names from the code, and compose's
        // environment for the container a part runs in.
        var env: [String: Set<String>] = [:]
        for file in code {
            let body = text(file)
            guard has(body, "env") || has(body, "ENV") else { continue }
            let names = environmentNames(in: lines(of: body, holding: ["env", "ENV"]))
            guard !names.isEmpty else { continue }
            if let client = clientOwning(file) {
                env[client.id, default: []].formUnion(names)
            } else if let owner = owner(file) {
                env[owner.id, default: []].formUnion(names)
            }
        }
        for service in compose?.services ?? [] where !service.environment.isEmpty {
            let runs = parts.filter { $0.container == service.name && $0.lane != .api }
            let target = runs.first { $0.kind == .app } ?? runs.first
            if let target { env[target.id, default: []].formUnion(service.environment.keys) }
        }
        for index in parts.indices { parts[index].env = (env[parts[index].id] ?? []).sorted() }

        let ordered = links.values.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        return SystemMap(parts: parts, links: ordered)
    }

    // MARK: Clients

    /// Web and mobile apps in the repo: a folder with a package.json that pulls in a UI
    /// framework, or an index.html next to scripts, or a folder named like a frontend.
    static func frontends(files: [String], read: (String) -> String?) -> [Part] {
        var roots: [String: String] = [:]
        for file in files {
            let parts = file.split(separator: "/").map(String.init)
            guard !parts.dropLast().contains(where: { skippedFolders.contains($0) || $0.hasPrefix(".") }) else { continue }
            let folder = (file as NSString).deletingLastPathComponent
            let name = (file as NSString).lastPathComponent
            if name == "package.json", let text = read(file), let framework = framework(packageJSON: text) {
                roots[folder] = framework
            } else if name == "index.html", roots[folder] == nil,
                      files.contains(where: { $0.hasPrefix(folder.isEmpty ? "" : folder + "/") && ["js", "ts", "mjs", "jsx", "tsx"].contains(($0 as NSString).pathExtension) && !$0.contains("node_modules/") }) {
                roots[folder] = "JavaScript"
            } else if name == "pubspec.yaml" {
                roots[folder] = "Flutter"
            }
        }
        // A frontend folder name counts even without either marker.
        for file in files where isCode(file) {
            let first = file.split(separator: "/").first.map(String.init) ?? ""
            if frontendNames.contains(first.lowercased()), file.contains("/"), roots[first] == nil, !roots.keys.contains(where: { $0.hasPrefix(first + "/") }) {
                roots[first] = ["ts", "tsx"].contains((file as NSString).pathExtension) ? "TypeScript" : "JavaScript"
            }
        }
        // The repo root only counts when nothing else looks like a server.
        if roots[""] != nil, roots.count > 1 { roots[""] = nil }
        // Nested roots (frontend/app inside frontend) collapse into the outer one.
        let kept = roots.keys.filter { root in !roots.keys.contains { $0 != root && !$0.isEmpty && root.hasPrefix($0 + "/") } }
        return kept.sorted().map { root in
            let framework = roots[root]!
            let screens = self.screens(files: files, root: root)
            let mobile = ["Flutter", "React Native", "Expo"].contains(framework)
            let count = files.filter { (root.isEmpty || $0.hasPrefix(root + "/")) && isCode($0) }.count
            let name = root.isEmpty ? (mobile ? "Mobile app" : "Web app") : (root as NSString).lastPathComponent
            let detail = framework + (screens.isEmpty ? " · \(count) files" : " · \(screens.count) screen\(screens.count == 1 ? "" : "s")")
            return Part(id: "client:" + (root.isEmpty ? "." : root), name: name, lane: .clients, kind: mobile ? .mobile : .web,
                        detail: detail, path: root.isEmpty ? "." : root, items: screens.map { Item($0.name, file: $0.file) })
        }
    }

    static func framework(packageJSON text: String) -> String? {
        let checks: [(String, String)] = [("\"react-native\"", "React Native"), ("\"expo\"", "Expo"), ("\"next\"", "Next.js"), ("\"nuxt\"", "Nuxt"),
                                          ("\"@sveltejs/kit\"", "SvelteKit"), ("\"svelte\"", "Svelte"), ("\"@angular/core\"", "Angular"),
                                          ("\"solid-js\"", "Solid"), ("\"vue\"", "Vue"), ("\"react\"", "React"), ("\"preact\"", "Preact"), ("\"lit\"", "Lit")]
        return checks.first { text.contains($0.0) }?.1
    }

    /// Screens: files under views/, pages/, screens/ or routes/ (a page.tsx counts as its folder).
    static func screens(files: [String], root: String) -> [(name: String, file: String)] {
        let folders: Set<String> = ["views", "pages", "screens", "routes", "app"]
        var seen: Set<String> = []
        var found: [(String, String)] = []
        for file in files.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count || ($0.split(separator: "/").count == $1.split(separator: "/").count && $0 < $1) }) where (root.isEmpty || file.hasPrefix(root + "/")) && isCode(file) {
            let relative = root.isEmpty ? file : String(file.dropFirst(root.count + 1))
            let parts = relative.split(separator: "/").map(String.init)
            guard let index = parts.firstIndex(where: { folders.contains($0) }), index < parts.count - 1, index <= 1 else { continue }
            let stem = ((parts.last! as NSString).deletingPathExtension as NSString).deletingPathExtension
            if ["layout", "_app", "_document", "loading", "error", "not-found", "route", "middleware"].contains(stem) || stem.hasPrefix("+layout") { continue }
            // app/ only counts in Next's router, where screens are page files.
            if parts[index] == "app", stem != "page" { continue }
            // A page file is named by its folders under the screens folder: orders/[id]/page → orders/:id.
            let folders = parts[(index + 1)..<(parts.count - 1)].joined(separator: "/")
            var name = ["page", "index", "+page"].contains(stem) ? (folders.isEmpty ? "home" : folders) : stem
            name = name.replacingOccurrences(of: "[", with: ":").replacingOccurrences(of: "]", with: "")
            if seen.insert(name).inserted { found.append((name, file)) }
        }
        return found
    }

    // MARK: Routes

    struct Route: Equatable {
        var method: String?
        var path: String
        var line: Int
    }

    /// Route registrations: Go's ServeMux ("GET /path"), chi/gin/echo/express style
    /// `router.get("/path")`, and Python decorators (`@app.get("/path")`).
    static func routes(in text: String) -> [Route] {
        guard has(text, "(\"/") || has(text, "('/") || has(text, "(`/") || has(text, "( \"/") || has(text, "Handle") else { return [] }
        var found: [Route] = []
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            // Regex matching is slow; most lines can't be a route, so check cheaply first.
            guard has(raw, "(\"/") || has(raw, "('/") || has(raw, "(`/") || has(raw, "( \"/") || has(raw, "Handle") else { continue }
            let line = String(raw)
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            // Examples in comments and doc comments aren't routes.
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") || trimmed.hasPrefix("# ") || trimmed.hasPrefix("--") { continue }
            let range = NSRange(line.startIndex..., in: line)
            func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
                Range(match.range(at: index), in: line).map { String(line[$0]) }
            }
            if let match = RoutePattern.handle.firstMatch(in: line, range: range), let path = group(match, 2) {
                found.append(Route(method: group(match, 1), path: path, line: number + 1))
            } else if let match = RoutePattern.decorator.firstMatch(in: line, range: range), let verb = group(match, 1)?.uppercased(), let path = group(match, 2) {
                found.append(Route(method: verb == "ROUTE" || verb == "API_ROUTE" ? nil : verb, path: path, line: number + 1))
            } else if let match = RoutePattern.router.firstMatch(in: line, range: range), let verb = group(match, 1), let path = group(match, 2) {
                found.append(Route(method: verb.uppercased(), path: path, line: number + 1))
            }
        }
        return found
    }

    /// Compiled once: Swift `Regex` literals were most of the map's build time on big repos.
    private enum RoutePattern {
        nonisolated(unsafe) static let handle = try! NSRegularExpression(pattern: #"Handle(?:Func)?\(\s*"(?:([A-Z]+)\s+)?(/[^"]*)""#)
        nonisolated(unsafe) static let decorator = try! NSRegularExpression(pattern: #"@\w+\.(get|post|put|patch|delete|route|api_route)\(\s*["'](/[^"']*)["']"#)
        nonisolated(unsafe) static let router = try! NSRegularExpression(pattern: #"\b(?:app|router|r|mux|e|g|api|server|srv|routes|v\d|grp|group|[a-z]\w*(?:Router|Group|Routes))\.(get|post|put|patch|delete|Get|Post|Put|Patch|Delete|GET|POST|PUT|PATCH|DELETE)\(\s*["'`](/[^"'`]*)["'`]"#)
    }

    /// "/api/templates/{id}" → "/api/templates". Version and api prefixes are kept as part
    /// of the name but don't count as the group.
    static func routeGroup(_ path: String) -> String {
        let prefixes: Set<String> = ["api", "v1", "v2", "v3", "v4", "rest", "public"]
        let segments = path.split(separator: "/").map(String.init)
        var kept: [String] = []
        for segment in segments {
            if segment.hasPrefix("{") || segment.hasPrefix(":") || segment.hasPrefix("$") || segment.hasPrefix("<") || segment.hasPrefix("[") { break }
            kept.append(segment)
            if !prefixes.contains(segment.lowercased()) { break }
        }
        return "/" + kept.joined(separator: "/")
    }

    /// API paths a client asks for: string literals starting /api or /v1, up to the first
    /// interpolation or query.
    static func calledPaths(in text: String) -> [String] {
        guard has(text, "/api") || has(text, "/v1") || has(text, "/v2") else { return [] }
        return text.matches(of: /["'`](\/(?:api|v\d)(?:\/[^"'`\s?$]*)?)/).map { String($0.1) }
    }

    // MARK: Tables, webhooks and environment

    /// Table names from `CREATE TABLE` statements.
    static func tables(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"create\s+(?:virtual\s+)?table\s+(?:if\s+not\s+exists\s+)?(?:[`"\[]?\w+[`"\]]?\.)?[`"\[]?(\w+)"#, options: .caseInsensitive)
        var found: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            if let name = Range(match.range(at: 1), in: text).map({ String(text[$0]) }), !found.contains(name), !name.lowercased().hasPrefix("sqlite_") {
                found.append(name)
            }
        }
        return found
    }

    /// Matches a query naming one of `tables` (in lowercased text): FROM, INTO, UPDATE, JOIN.
    static func queryPattern(_ tables: [String]) -> NSRegularExpression? {
        let names = tables.map { NSRegularExpression.escapedPattern(for: $0.lowercased()) }.joined(separator: "|")
        return try? NSRegularExpression(pattern: #"\b(?:from|into|update|join|table)\s+[`"\[]?("# + names + #")\b"#)
    }

    static func isWebhookRoute(_ route: String) -> Bool {
        let lower = route.lowercased()
        return lower.contains("webhook") || lower.contains("/hooks/") || lower.contains("callback")
    }

    /// Environment variable names read in code: Go, JavaScript, Python, Ruby, Rust, Swift.
    static func environmentNames(in text: String) -> Set<String> {
        var names: Set<String> = []
        let range = NSRange(text.startIndex..., in: text)
        for match in environmentPattern.matches(in: text, range: range) {
            for group in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: group), in: text) { names.insert(String(text[range])) }
            }
        }
        return names
    }

    nonisolated(unsafe) private static let environmentPattern = try! NSRegularExpression(pattern: [
            #"os\.(?:Getenv|LookupEnv)\("([A-Za-z_][A-Za-z0-9_]*)""#,
            #"(?:process|import\.meta)\.env\.([A-Za-z_][A-Za-z0-9_]*)"#,
            #"process\.env\[["']([A-Za-z_][A-Za-z0-9_]*)"#,
            #"os\.(?:environ\.get|getenv)\(\s*["']([A-Za-z_][A-Za-z0-9_]*)"#,
            #"os\.environ\[["']([A-Za-z_][A-Za-z0-9_]*)"#,
            #"ENV(?:\.fetch\(|\[)["']([A-Za-z_][A-Za-z0-9_]*)"#,
            #"env::var\("([A-Za-z_][A-Za-z0-9_]*)""#,
            #"environment\["([A-Za-z_][A-Za-z0-9_]*)"\]"#,
        ].joined(separator: "|"))

    /// Names that usually hold a secret: keys, tokens, passwords.
    public static func isSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["SECRET", "TOKEN", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "PRIVATE", "CREDENTIAL", "_KEY", "DSN"].contains { upper.contains($0) }
            || upper.hasSuffix("_PASS") || upper.hasPrefix("KEY_")
    }

    // MARK: Outside services

    struct OutsideService {
        var id: String
        var name: String
        var kind: Kind
        var detail: String
        var patterns: [String]
    }

    static let outsideServices: [OutsideService] = [
        .init(id: "smtp", name: "Email (SMTP)", kind: .email, detail: "outgoing mail", patterns: ["\"net/smtp\"", "gopkg.in/mail.v2", "gopkg.in/gomail", "nodemailer", "import smtplib", "javax.mail", "lettre::"]),
        .init(id: "sendgrid", name: "SendGrid", kind: .email, detail: "email API", patterns: ["sendgrid"]),
        .init(id: "mailgun", name: "Mailgun", kind: .email, detail: "email API", patterns: ["mailgun"]),
        .init(id: "postmark", name: "Postmark", kind: .email, detail: "email API", patterns: ["postmarkapp", "postmark-"]),
        .init(id: "ses", name: "Amazon SES", kind: .email, detail: "email API", patterns: ["aws-sdk-go/service/ses", "client-ses", "sesv2"]),
        .init(id: "meta", name: "Meta Graph API", kind: .messaging, detail: "graph.facebook.com", patterns: ["graph.facebook.com"]),
        .init(id: "twilio", name: "Twilio", kind: .messaging, detail: "SMS and voice", patterns: ["twilio"]),
        .init(id: "slack", name: "Slack", kind: .messaging, detail: "webhooks or API", patterns: ["hooks.slack.com", "slack-go/slack", "@slack/web-api", "slack_sdk"]),
        .init(id: "telegram", name: "Telegram", kind: .messaging, detail: "bot API", patterns: ["api.telegram.org"]),
        .init(id: "ollama", name: "Ollama", kind: .ai, detail: "local models", patterns: ["ollama", ":11434"]),
        .init(id: "openai", name: "OpenAI", kind: .ai, detail: "api.openai.com", patterns: ["api.openai.com", "sashabaranov/go-openai", "from openai", "\"openai\"", "require('openai')"]),
        .init(id: "anthropic", name: "Anthropic", kind: .ai, detail: "Claude API", patterns: ["api.anthropic.com", "@anthropic-ai/sdk", "from anthropic", "anthropic-sdk-go"]),
        .init(id: "gemini", name: "Google Gemini", kind: .ai, detail: "generativelanguage API", patterns: ["generativelanguage.googleapis.com", "@google/generative-ai", "google.golang.org/genai"]),
        .init(id: "stripe", name: "Stripe", kind: .payments, detail: "payments", patterns: ["stripe-go", "api.stripe.com", "\"stripe\"", "import stripe", "@stripe/"]),
        .init(id: "paypal", name: "PayPal", kind: .payments, detail: "payments", patterns: ["api.paypal.com", "paypal-"]),
        .init(id: "s3", name: "Amazon S3", kind: .storage, detail: "object storage", patterns: ["aws-sdk-go-v2/service/s3", "aws-sdk-go/service/s3", "@aws-sdk/client-s3", "s3.amazonaws.com", "boto3.client('s3')", "boto3.client(\"s3\")"]),
        .init(id: "gcs", name: "Google Cloud Storage", kind: .storage, detail: "object storage", patterns: ["cloud.google.com/go/storage", "@google-cloud/storage"]),
        .init(id: "firebase", name: "Firebase", kind: .service, detail: "auth, data, messaging", patterns: ["firebase"]),
        .init(id: "supabase", name: "Supabase", kind: .service, detail: "auth and Postgres", patterns: ["supabase"]),
        .init(id: "auth0", name: "Auth0", kind: .service, detail: "sign-in", patterns: ["auth0"]),
        .init(id: "sentry", name: "Sentry", kind: .monitoring, detail: "error reporting", patterns: ["getsentry/sentry-go", "@sentry/", "sentry_sdk", "sentry.io"]),
        .init(id: "github", name: "GitHub API", kind: .service, detail: "api.github.com", patterns: ["api.github.com", "google/go-github", "@octokit/"]),
        .init(id: "kafka", name: "Kafka", kind: .messaging, detail: "event stream", patterns: ["segmentio/kafka-go", "confluent-kafka", "kafkajs", "IBM/sarama"]),
        .init(id: "rabbitmq", name: "RabbitMQ", kind: .messaging, detail: "queues", patterns: ["amqp091", "streadway/amqp", "amqplib", "import pika"]),
    ]
}

extension SystemMap {
    /// Coverage per part: files under a part's path (or its routes' files), from a report.
    public func coverage(_ report: CoverageReport) -> [String: CoverageReport.Lines] {
        var result: [String: CoverageReport.Lines] = [:]
        let owners = parts.filter { ($0.lane == .backend || ($0.lane == .clients && $0.id.hasPrefix("client:"))) && $0.path != nil }
        for (file, lines) in report.files {
            let owner = owners.filter { part in
                let path = part.path ?? ""
                return path == "." || path.isEmpty ? true : file.hasPrefix(path + "/")
            }.max { ($0.path ?? "").count < ($1.path ?? "").count }
            if let owner { add(lines, to: owner.id) }
            for part in parts where part.lane == .api && part.items.contains(where: { $0.file == file }) || part.id.hasPrefix("screen:") && part.path == file {
                add(lines, to: part.id)
            }
        }
        func add(_ lines: CoverageReport.Lines, to id: String) {
            var total = result[id] ?? CoverageReport.Lines(covered: 0, total: 0)
            total.covered += lines.covered
            total.total += lines.total
            result[id] = total
        }
        return result.filter { $0.value.total > 0 }
    }

    /// The map as a Mermaid flowchart, one subgraph per lane.
    public func mermaid() -> String {
        func node(_ id: String) -> String {
            "n" + String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
        }
        func label(_ text: String) -> String { text.replacingOccurrences(of: "\"", with: "'") }
        var lines = ["flowchart LR"]
        for (lane, parts) in lanes where !parts.isEmpty {
            lines.append("  subgraph \(lane.title.replacingOccurrences(of: " ", with: "_"))[\"\(lane.title)\"]")
            for part in parts {
                let shape = part.kind == .database || part.kind == .table ? ("[(\"", "\")]") : ("[\"", "\"]")
                lines.append("    \(node(part.id))\(shape.0)\(label(part.name))\(shape.1)")
            }
            lines.append("  end")
        }
        for link in links {
            lines.append("  \(node(link.from)) --> \(node(link.to))")
        }
        return lines.joined(separator: "\n")
    }

    static let markerStart = "<!-- dante:system-map -->"
    static let markerEnd = "<!-- /dante:system-map -->"

    /// architecture.md with the map's section added or replaced; the rest is left alone.
    public func exporting(into document: String?, date: Date = .now) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        let section = """
        \(Self.markerStart)
        ## System map

        Drawn by Dante from the code on \(day). Regenerate it from Map → System → Export.

        ```mermaid
        \(mermaid())
        ```
        \(Self.markerEnd)
        """
        guard let document, !document.isEmpty else { return "# Architecture\n\n" + section + "\n" }
        if let start = document.range(of: Self.markerStart), let end = document.range(of: Self.markerEnd, range: start.upperBound..<document.endIndex) {
            return document.replacingCharacters(in: start.lowerBound..<end.upperBound, with: section)
        }
        return document.trimmingCharacters(in: .newlines) + "\n\n" + section + "\n"
    }
}
