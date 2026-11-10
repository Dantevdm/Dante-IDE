import Foundation
import Yams

/// The choices the deploy wizard offers, read from the app spec and written back into it.
/// Writing edits the YAML's own tree, so keys the wizard doesn't know about, the order of the
/// file and its header comment survive; only comments inside the body are lost.
public struct DOSetup: Equatable, Sendable {
    public var name: String
    public var region: String
    public var parts: [Part]
    public var databases: [Store]
    public var domains: [String]
    /// App-wide alert rules that are on: `DOSetup.appAlerts` lists the ones offered.
    public var alerts: Set<String>
    /// Alerts every service and worker gets, from `DOSetup.Watch`.
    public var watches: Set<Watch>

    public struct Part: Equatable, Sendable, Identifiable {
        public var kind: DOAppSpec.Kind
        public var name: String
        public var size: String
        public var instances: Int
        public var autoscale: Autoscale?
        public var port: Int?
        public var healthPath: String?
        public var runCommand: String?
        /// The git host's branch, nil for an image.
        public var branch: String?
        public var deploysOnPush: Bool
        public var sourceLabel: String
        public var variables: [Variable]
        public var id: String { name }

        /// Static sites run on the CDN and pre/post-deploy jobs for seconds, so neither has a size to pick.
        public var isSized: Bool { kind != .staticSite }
        public var runsAlways: Bool { kind == .service || kind == .worker }
    }

    public struct Autoscale: Equatable, Sendable {
        public var minimum: Int
        public var maximum: Int
        public var cpuPercent: Int

        public init(minimum: Int, maximum: Int, cpuPercent: Int = 80) {
            self.minimum = minimum
            self.maximum = maximum
            self.cpuPercent = cpuPercent
        }
    }

    public struct Store: Equatable, Sendable, Identifiable {
        public var name: String
        public var engine: String
        public var version: String?
        /// A managed cluster the team already has; nil for a dev database.
        public var cluster: String?
        public var id: String { name }
        public var isManaged: Bool { cluster != nil }
    }

    /// A component's variable. A secret's value is never kept here: the deploy asks for it.
    public struct Variable: Equatable, Sendable, Identifiable {
        public var key: String
        public var value: String
        public var isSecret: Bool
        public var id: String { key }

        public init(key: String, value: String = "", isSecret: Bool = false) {
            self.key = key
            self.value = value
            self.isSecret = isSecret
        }

        /// `${db.DATABASE_URL}` and friends: filled by App Platform, not typed.
        public var isBound: Bool { value.hasPrefix("${") }
    }

    public enum Watch: String, CaseIterable, Sendable {
        case cpu = "CPU_UTILIZATION", memory = "MEM_UTILIZATION", restarts = "RESTART_COUNT"

        public var title: String {
            switch self {
            case .cpu: "CPU above 80% for five minutes"
            case .memory: "Memory above 80% for five minutes"
            case .restarts: "More than three restarts in five minutes"
            }
        }

        var threshold: Int { self == .restarts ? 3 : 80 }
    }

    public static let appAlerts: [(rule: String, title: String)] = [
        ("DEPLOYMENT_FAILED", "A deployment fails"),
        ("DOMAIN_FAILED", "A domain stops working"),
        ("DEPLOYMENT_LIVE", "A deployment goes live"),
    ]

    /// App Platform only scales dedicated-CPU sizes by itself.
    public static func scales(_ size: String) -> Bool { size.hasPrefix("apps-d-") }

    // MARK: Reading

    public init(spec: DOAppSpec, region: String) {
        name = spec.name
        self.region = spec.region ?? region
        parts = spec.components.map { kind, component in
            let repo = component.github ?? component.gitlab ?? component.bitbucket
            return Part(kind: kind, name: component.name, size: component.instanceSizeSlug ?? DOPlan.smallestService,
                        instances: component.instanceCount ?? 1,
                        autoscale: component.autoscaling.map { Autoscale(minimum: $0.minInstanceCount ?? 1, maximum: $0.maxInstanceCount ?? 2) },
                        port: component.httpPort, healthPath: component.healthCheck?.httpPath, runCommand: component.runCommand,
                        branch: repo?.branch ?? component.git?.branch, deploysOnPush: component.deploysOnPush, sourceLabel: component.sourceLabel,
                        variables: (component.envs ?? []).map { Variable(key: $0.key, value: $0.isSecretType ? "" : ($0.value ?? ""), isSecret: $0.isSecretType) })
        }
        databases = (spec.databases ?? []).map {
            Store(name: $0.name, engine: $0.engine ?? "PG", version: $0.version, cluster: $0.production == true ? ($0.clusterName ?? "") : nil)
        }
        domains = (spec.domains ?? []).map(\.domain)
        alerts = Set((spec.alerts ?? []).filter { $0.disabled != true }.map(\.rule))
        // A watch counts as on when every part that runs all the time has it.
        let running = spec.components.filter { $0.kind == .service || $0.kind == .worker }.map(\.component)
        watches = Set(Watch.allCases.filter { watch in
            !running.isEmpty && running.allSatisfy { ($0.alerts ?? []).contains { $0.rule == watch.rawValue && $0.disabled != true } }
        })
    }

    /// Reads the CPU percentage autoscaling aims for, which `DOAppSpec` doesn't keep.
    public mutating func readTargets(from yaml: String) {
        guard let root = try? Yams.compose(yaml: yaml) else { return }
        for index in parts.indices where parts[index].autoscale != nil {
            guard let component = Self.component(named: parts[index].name, in: root),
                  let percent = component["autoscaling"]?["metrics"]?["cpu"]?["percent"]?.int else { continue }
            parts[index].autoscale?.cpuPercent = percent
        }
    }

    // MARK: Checking

    /// What stops the spec being sent, as sentences; empty when it's fine.
    public var problems: [String] {
        var problems: [String] = []
        if DOPlan.appName(name) != name || name.isEmpty { problems.append("The app’s name can only have lowercase letters, digits and dashes.") }
        for part in parts {
            if let scale = part.autoscale {
                if !Self.scales(part.size) { problems.append("\(part.name) scales by itself only on a dedicated-CPU size.") }
                if scale.minimum < 1 || scale.maximum < scale.minimum { problems.append("\(part.name)’s instances must go from at least 1 up to at least that.") }
            }
            if let port = part.port, !(1...65535).contains(port) { problems.append("\(part.name)’s port must be between 1 and 65535.") }
            if let path = part.healthPath, !path.isEmpty, !path.hasPrefix("/") { problems.append("\(part.name)’s health check path starts with /.") }
            let keys = part.variables.map(\.key)
            if Set(keys).count != keys.count { problems.append("\(part.name) has the same variable twice.") }
            if part.variables.contains(where: { $0.key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil }) {
                problems.append("\(part.name) has a variable whose name isn’t letters, digits and underscores.")
            }
        }
        for store in databases where store.isManaged && (store.cluster ?? "").isEmpty {
            problems.append("Pick the cluster \(store.name) uses.")
        }
        for domain in domains where domain.range(of: "^([a-z0-9-]+\\.)+[a-z]{2,}$", options: [.regularExpression, .caseInsensitive]) == nil {
            problems.append("\(domain) isn’t a domain name.")
        }
        return problems
    }

    // MARK: Writing

    /// The spec text with these choices in it.
    public func written(into yaml: String) throws -> String {
        guard var root = try Yams.compose(yaml: yaml), case .mapping = root else {
            throw DOAppSpec.SpecProblem(message: "The spec is empty.")
        }
        Self.set(&root, "name", Self.text(name))
        Self.set(&root, "region", Self.text(region))
        for part in parts {
            guard let list = Self.list(for: part.kind) else { continue }
            Self.edit(&root, list: list, named: part.name) { Self.write(part, watches: watches, into: &$0) }
        }
        for store in databases {
            Self.edit(&root, list: "databases", named: store.name) { node in
                Self.set(&node, "production", store.isManaged ? Node("true") : nil)
                Self.set(&node, "cluster_name", store.cluster.map(Self.text))
            }
        }
        Self.set(&root, "domains", domains.isEmpty ? nil : .sequence(.init(domains.enumerated().map { index, domain in
            Self.mapping([("domain", Self.text(domain.lowercased())), ("type", Node(index == 0 ? "PRIMARY" : "ALIAS"))])
        })))
        // App-wide alerts: the offered ones follow the switches, any others are kept.
        let offered = Set(Self.appAlerts.map(\.rule))
        var kept = (root["alerts"]?.sequence.map(Array.init) ?? []).filter { !offered.contains($0["rule"]?.string ?? "") }
        kept += Self.appAlerts.map(\.rule).filter(alerts.contains).map { Self.mapping([("rule", Node($0))]) }
        Self.set(&root, "alerts", kept.isEmpty ? nil : .sequence(.init(kept)))
        let body = try Yams.serialize(node: root, indent: 2, width: -1, allowUnicode: true)
        let header = yaml.split(separator: "\n", omittingEmptySubsequences: false).prefix { $0.hasPrefix("#") }
        return (header.isEmpty ? "" : header.joined(separator: "\n") + "\n") + body
    }

    static func write(_ part: Part, watches: Set<Watch>, into node: inout Node) {
        if part.isSized {
            set(&node, "instance_size_slug", text(part.size))
            if let scale = part.autoscale {
                set(&node, "instance_count", nil)
                set(&node, "autoscaling", mapping([
                    ("min_instance_count", Node(String(scale.minimum))),
                    ("max_instance_count", Node(String(scale.maximum))),
                    ("metrics", mapping([("cpu", mapping([("percent", Node(String(scale.cpuPercent)))]))])),
                ]))
            } else {
                set(&node, "autoscaling", nil)
                set(&node, "instance_count", part.kind == .job ? node["instance_count"] : Node(String(part.instances)))
            }
        }
        if part.kind == .service {
            set(&node, "http_port", part.port.map { Node(String($0)) })
            var check = node["health_check"] ?? mapping([])
            set(&check, "http_path", part.healthPath.flatMap { $0.isEmpty ? nil : text($0) })
            set(&node, "health_check", check.mapping?.isEmpty == true ? nil : check)
        }
        set(&node, "run_command", part.runCommand.flatMap { $0.isEmpty ? nil : text($0) })
        for host in ["github", "gitlab", "bitbucket", "git"] where node[host] != nil {
            var source = node[host]!
            if let branch = part.branch, !branch.isEmpty { set(&source, "branch", text(branch)) }
            if host != "git" { set(&source, "deploy_on_push", Node(part.deploysOnPush ? "true" : "false")) }
            set(&node, host, source)
        }
        // Variables: plain ones carry their value, secrets go without one (or keep the
        // encrypted EV[…] the API gave back), bound ones stay as written.
        let old = node["envs"]?.sequence.map(Array.init) ?? []
        let envs: [Node] = part.variables.map { variable in
            var entry = old.first { $0["key"]?.string == variable.key } ?? mapping([("key", text(variable.key))])
            if variable.isSecret {
                set(&entry, "type", Node("SECRET"))
                if entry["value"]?.string?.hasPrefix("EV[") != true { set(&entry, "value", nil) }
            } else {
                set(&entry, "type", nil)
                set(&entry, "value", text(variable.value))
            }
            return entry
        }
        set(&node, "envs", envs.isEmpty ? nil : .sequence(.init(envs)))
        if part.runsAlways {
            let watched = Set(Watch.allCases.map(\.rawValue))
            var alerts = (node["alerts"]?.sequence.map(Array.init) ?? []).filter { !watched.contains($0["rule"]?.string ?? "") }
            alerts += Watch.allCases.filter(watches.contains).map { watch in
                mapping([("rule", Node(watch.rawValue)), ("operator", Node("GREATER_THAN")), ("value", Node(String(watch.threshold))), ("window", Node("FIVE_MINUTES"))])
            }
            set(&node, "alerts", alerts.isEmpty ? nil : .sequence(.init(alerts)))
        }
    }

    // MARK: Tree helpers

    static func list(for kind: DOAppSpec.Kind) -> String? {
        switch kind {
        case .service: "services"
        case .staticSite: "static_sites"
        case .worker: "workers"
        case .job: "jobs"
        }
    }

    static func component(named name: String, in root: Node) -> Node? {
        for list in DOSpecSend.componentLists {
            if let found = root[list]?.sequence?.first(where: { $0["name"]?.string == name }) { return found }
        }
        return nil
    }

    static func edit(_ root: inout Node, list: String, named name: String, _ change: (inout Node) -> Void) {
        guard var items = root[list]?.sequence, let index = items.firstIndex(where: { $0["name"]?.string == name }) else { return }
        var item = items[index]
        change(&item)
        items[index] = item
        set(&root, list, .sequence(items))
    }

    static func set(_ node: inout Node, _ key: String, _ value: Node?) {
        guard case .mapping(var mapping) = node else { return }
        mapping[key] = value
        node = .mapping(mapping)
    }

    static func mapping(_ pairs: [(String, Node)]) -> Node {
        .mapping(.init(pairs.map { (Node($0.0), $0.1) }))
    }

    /// A string, quoted when YAML would otherwise read it as something else ("8080", "yes").
    static func text(_ value: String) -> Node {
        let plain = Node(value)
        let reads = plain.null != nil || plain.bool != nil || plain.int != nil || plain.float != nil || value.isEmpty
            || value.hasPrefix("${") || value.contains(": ") || value.contains(" #") || value.first.map { "!&*[]{}|>%@`'\",?#-".contains($0) } == true
        return reads ? Node(value, .implicit, .doubleQuoted) : plain
    }
}

/// A managed database cluster the team has, which an app can use instead of a dev database.
public struct DODatabaseCluster: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var engine: String?
    public var version: String?
    public var region: String?
    public var size: String?
    public var status: String?
    public var numNodes: Int?

    public init(id: String, name: String, engine: String?, version: String?, region: String?, size: String?, status: String?, numNodes: Int?) {
        self.id = id
        self.name = name
        self.engine = engine
        self.version = version
        self.region = region
        self.size = size
        self.status = status
        self.numNodes = numNodes
    }

    /// `pg` is `PG` in an app spec.
    public var specEngine: String { (engine ?? "pg").uppercased() }
}
