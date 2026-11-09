import Foundation
import Yams

/// An App Platform app as the API describes it.
public struct DOApp: Equatable, Sendable, Identifiable {
    public var id: String
    public var spec: DOAppSpec?
    /// The spec exactly as DigitalOcean holds it (secrets encrypted), for merging into an update.
    public var specJSON: Data?
    public var liveURL: URL?
    public var region: String?
    public var tier: String?
    public var created: Date?
    public var updated: Date?
    public var active: DODeployment?
    public var inProgress: DODeployment?
    public var pending: DODeployment?

    public var name: String { spec?.name ?? id }

    /// The newest deployment it knows of: one under way, else the live one.
    public var current: DODeployment? { inProgress ?? pending ?? active }

    struct Wire: Decodable {
        var id: String
        var liveUrl: String?
        var region: Region?
        var tierSlug: String?
        var createdAt: String?
        var updatedAt: String?
        var activeDeployment: DODeployment?
        var inProgressDeployment: DODeployment?
        var pendingDeployment: DODeployment?
        struct Region: Decodable { var slug: String? }
    }

    /// One app from its JSON object (`{"app": {…}}`'s inside, or an element of `apps`).
    public static func parse(_ object: Any) -> DOApp? {
        guard let dictionary = object as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let wire = try? DOJSON.decoder.decode(Wire.self, from: data) else { return nil }
        let specJSON = (dictionary["spec"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
        return DOApp(id: wire.id, spec: specJSON.flatMap(DOAppSpec.fromJSON), specJSON: specJSON, liveURL: wire.liveUrl.flatMap(URL.init(string:)),
                     region: wire.region?.slug, tier: wire.tierSlug, created: wire.createdAt.flatMap(DOJSON.date), updated: wire.updatedAt.flatMap(DOJSON.date),
                     active: wire.activeDeployment, inProgress: wire.inProgressDeployment, pending: wire.pendingDeployment)
    }
}

public struct DODeployment: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var phase: Phase
    public var cause: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var progress: Progress?
    public var services: [ComponentState]?
    public var staticSites: [ComponentState]?
    public var workers: [ComponentState]?
    public var jobs: [ComponentState]?

    public var created: Date? { createdAt.flatMap(DOJSON.date) }
    public var updated: Date? { updatedAt.flatMap(DOJSON.date) }

    public enum Phase: String, Decodable, Sendable {
        case unknown = "UNKNOWN", pendingBuild = "PENDING_BUILD", building = "BUILDING", pendingDeploy = "PENDING_DEPLOY"
        case deploying = "DEPLOYING", active = "ACTIVE", superseded = "SUPERSEDED", error = "ERROR", canceled = "CANCELED"

        public init(from decoder: Decoder) throws {
            self = Phase(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
        }

        public var isRunning: Bool { [.pendingBuild, .building, .pendingDeploy, .deploying].contains(self) }

        public var title: String {
            switch self {
            case .unknown: "Unknown"
            case .pendingBuild: "Waiting to build"
            case .building: "Building"
            case .pendingDeploy: "Waiting to deploy"
            case .deploying: "Deploying"
            case .active: "Live"
            case .superseded: "Replaced"
            case .error: "Failed"
            case .canceled: "Cancelled"
            }
        }
    }

    public struct Progress: Decodable, Equatable, Sendable {
        public var successSteps: Int?
        public var totalSteps: Int?
        public var errorSteps: Int?
        public var steps: [Step]?
    }

    public struct Step: Decodable, Equatable, Sendable {
        public var name: String?
        public var status: String?
        public var componentName: String?
        public var steps: [Step]?
        public var startedAt: String?
        public var endedAt: String?
        public var reason: Reason?
        public var messageBase: String?

        public struct Reason: Decodable, Equatable, Sendable {
            public var code: String?
            public var message: String?
        }

        public var isError: Bool { status == "ERROR" }
        public var isRunning: Bool { status == "RUNNING" }
        public var isDone: Bool { status == "SUCCESS" }

        /// "build", "deploy", "initialize" as a person would say them.
        public var title: String {
            let raw = (name ?? "step").replacingOccurrences(of: "_", with: " ")
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    public struct ComponentState: Decodable, Equatable, Sendable {
        public var name: String?
        public var sourceCommitHash: String?
        public var sourceImageDigest: String?
    }

    /// The first step that failed with its reason, deepest first ("build › web: exit code 1").
    public var failure: (place: String, message: String)? {
        func search(_ steps: [Step], path: [String]) -> (String, String)? {
            for step in steps where step.isError {
                let here = path + [step.componentName ?? step.title]
                if let deeper = search(step.steps ?? [], path: here) { return deeper }
                return (here.joined(separator: " › "), step.reason?.message ?? step.reason?.code ?? "It failed.")
            }
            return nil
        }
        return search(progress?.steps ?? [], path: [])
    }

    /// The commit it was built from, when it came from git.
    public var commit: String? {
        ((services ?? []) + (staticSites ?? []) + (workers ?? []) + (jobs ?? [])).lazy.compactMap { $0.sourceCommitHash }.first { !$0.isEmpty }
    }

    /// Plain words for `cause` ("commit 1a2b3c pushed", "manual", "app spec updated").
    public var causeText: String {
        guard let cause, !cause.isEmpty else { return "" }
        return cause.prefix(1).uppercased() + cause.dropFirst()
    }
}

/// How each component is doing right now (`/v2/apps/{id}/health`).
public struct DOComponentHealth: Decodable, Equatable, Sendable, Identifiable {
    public var name: String
    public var cpuUsagePercent: Double?
    public var memoryUsagePercent: Double?
    public var replicasDesired: Int?
    public var replicasReady: Int?
    public var state: String?
    public var id: String { name }

    public var isHealthy: Bool { state == nil || state == "HEALTHY" || state == "RUNNING" }

    struct Wrapper: Decodable {
        var appHealth: Inner?
        struct Inner: Decodable { var components: [DOComponentHealth]? }
    }
}

public struct DOAlert: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var componentName: String?
    public var spec: DOAppSpec.Alert?
    public var phase: String?
    public var emails: [String]?
    public var slackWebhooks: [SlackHook]?

    public struct SlackHook: Decodable, Equatable, Sendable { public var channel: String? }

    /// Someone hears about it: an email or a Slack channel.
    public var notifies: Bool { !(emails ?? []).isEmpty || !(slackWebhooks ?? []).isEmpty }
}

public struct DOInstanceSize: Decodable, Equatable, Sendable, Identifiable {
    public var name: String?
    public var slug: String
    public var cpus: String?
    public var memoryBytes: String?
    public var usdPerMonth: String?
    public var tierSlug: String?
    public var id: String { slug }

    public var monthly: Double? { usdPerMonth.flatMap(Double.init) }
    public var memoryGB: Double? { memoryBytes.flatMap(Double.init).map { $0 / 1_073_741_824 } }
}

/// What `/v2/apps/propose` says about a spec before anything is made: is it valid, and what
/// will it cost.
public struct DOProposal: Decodable, Equatable, Sendable {
    public var appIsStatic: Bool?
    public var appNameAvailable: Bool?
    public var appNameSuggestion: String?
    public var existingStaticApps: String?
    public var maxFreeStaticApps: String?
    public var appCost: Double?
    public var appTierDowngradeCost: Double?

    /// "$5.00 a month" or "Free".
    public var costText: String {
        guard let appCost else { return "Cost unknown" }
        return appCost == 0 ? "Free" : String(format: "$%.2f a month", appCost)
    }
}

public struct DOLogLinks: Decodable, Equatable, Sendable {
    public var liveUrl: String?
    public var historicUrls: [String]?
}

public struct DORegistry: Decodable, Equatable, Sendable {
    public var name: String
    public var region: String?
    public var storageUsageBytes: Int?
}

/// Whether pushing these repositories fits the registry's plan. A team's registry may be on
/// Starter (one repository) and already hold another project's, and then the push would fail
/// after the build.
public enum DORegistryRoom {
    /// The repositories the push would add, when they don't fit; empty when they do.
    public static func overflow(limit: Int?, existing: [String], pushing: [String]) -> [String] {
        guard let limit, limit > 0 else { return [] }
        let new = Array(Set(pushing).subtracting(existing)).sorted()
        return Set(existing).count + new.count > limit ? new : []
    }
}

/// A metric over time: (time, value) pairs.
public struct DOSeries: Equatable, Sendable {
    public var points: [(Date, Double)]

    public static func == (a: DOSeries, b: DOSeries) -> Bool {
        a.points.map(\.0) == b.points.map(\.0) && a.points.map(\.1) == b.points.map(\.1)
    }

    /// `data.result[]`'s values, summed per time across replicas.
    public static func parse(_ data: Data) -> DOSeries {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let inner = json["data"] as? [String: Any],
              let results = inner["result"] as? [[String: Any]] else { return DOSeries(points: []) }
        var sums: [Double: Double] = [:]
        for result in results {
            for pair in result["values"] as? [[Any]] ?? [] where pair.count == 2 {
                guard let time = (pair[0] as? Double) ?? (pair[0] as? Int).map(Double.init),
                      let value = (pair[1] as? String).flatMap(Double.init) ?? (pair[1] as? Double) else { continue }
                sums[time, default: 0] += value
            }
        }
        return DOSeries(points: sums.keys.sorted().map { (Date(timeIntervalSince1970: $0), sums[$0]!) })
    }

    public var last: Double? { points.last?.1 }
    public var peak: Double? { points.map(\.1).max() }
}

/// The account a token belongs to.
public struct DOAccountInfo: Decodable, Equatable, Sendable {
    public var email: String?
    public var status: String?
    public var team: Team?
    public struct Team: Decodable, Equatable, Sendable { public var name: String? }
}

enum DOJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Turns `.do/app.yaml` into the JSON the API takes, without losing anything Dante doesn't
/// model, and fills in what's only known at deploy time: the image tags just pushed and the
/// secrets, which come from what you typed or else stay as DigitalOcean already holds them.
public enum DOSpecSend {
    /// Keys whose values are always text, even when YAML would read `1.0` as a number.
    static let textKeys: Set<String> = ["tag", "version", "value", "branch", "repo", "name", "key", "digest", "repository", "registry",
                                        "domain", "repo_clone_url", "source_dir", "build_command", "run_command", "http_path", "region"]

    public static func object(yaml: String) -> Result<[String: Any], DOAppSpec.SpecProblem> {
        do {
            guard let node = try Yams.compose(yaml: yaml), let object = json(node, key: nil) as? [String: Any] else {
                return .failure(DOAppSpec.SpecProblem(message: "The spec is empty."))
            }
            return .success(object)
        } catch {
            return .failure(DOAppSpec.SpecProblem(message: "It isn't valid YAML: \(error.localizedDescription)"))
        }
    }

    static func json(_ node: Node, key: String?) -> Any {
        switch node {
        case .scalar(let scalar):
            if let key, textKeys.contains(key) { return scalar.string }
            if scalar.style == .singleQuoted || scalar.style == .doubleQuoted { return scalar.string }
            if node.null != nil { return NSNull() }
            if let value = node.bool { return value }
            if let value = node.int { return value }
            if let value = node.float { return value }
            return scalar.string
        case .mapping(let mapping):
            var object: [String: Any] = [:]
            for (name, value) in mapping {
                guard let name = name.string else { continue }
                object[name] = json(value, key: name)
            }
            return object
        case .sequence(let sequence):
            return sequence.map { json($0, key: nil) }
        default:
            return NSNull()
        }
    }

    static let componentLists = ["services", "static_sites", "workers", "jobs", "functions"]

    /// A secret the deploy still needs: `component` is nil for an app-wide one.
    public struct Needed: Equatable, Sendable, Hashable, Identifiable {
        public var component: String?
        public var key: String
        public var id: String { (component.map { $0 + "/" } ?? "") + key }
    }

    /// Fills `spec` for sending. `tags` maps a component to the image tag just pushed;
    /// `secrets` maps `Needed.id` to what was typed; `live` is the app's current spec. Returns
    /// the secrets that are still missing (send nothing while there are any).
    @discardableResult
    public static func prepare(_ spec: inout [String: Any], tags: [String: String] = [:], secrets: [String: String] = [:], live: [String: Any]? = nil) -> [Needed] {
        var missing: [Needed] = []
        let databases = spec["databases"] as? [[String: Any]] ?? []

        func fill(_ envs: [[String: Any]], component: String?, liveEnvs: [[String: Any]]) -> [[String: Any]] {
            envs.map { env in
                var env = env
                guard (env["type"] as? String)?.uppercased() == "SECRET", let key = env["key"] as? String,
                      ((env["value"] as? String) ?? "").isEmpty else { return env }
                let needed = Needed(component: component, key: key)
                if let typed = secrets[needed.id], !typed.isEmpty {
                    env["value"] = typed
                } else if let bound = binding(key: key, databases: databases) {
                    // The app's own database hands it this; a value from this Mac would be wrong there.
                    env["value"] = bound
                    env["type"] = "GENERAL"
                } else if let kept = liveEnvs.first(where: { ($0["key"] as? String) == key })?["value"] as? String, !kept.isEmpty {
                    env["value"] = kept
                } else {
                    missing.append(needed)
                }
                return env
            }
        }

        if let envs = spec["envs"] as? [[String: Any]] {
            spec["envs"] = fill(envs, component: nil, liveEnvs: live?["envs"] as? [[String: Any]] ?? [])
        }
        for list in componentLists {
            guard var components = spec[list] as? [[String: Any]] else { continue }
            let liveComponents = live?[list] as? [[String: Any]] ?? []
            for index in components.indices {
                guard let name = components[index]["name"] as? String else { continue }
                if let envs = components[index]["envs"] as? [[String: Any]] {
                    let liveEnvs = liveComponents.first { ($0["name"] as? String) == name }?["envs"] as? [[String: Any]] ?? []
                    components[index]["envs"] = fill(envs, component: name, liveEnvs: liveEnvs)
                }
                if let tag = tags[name], var image = components[index]["image"] as? [String: Any] {
                    image["tag"] = tag
                    image.removeValue(forKey: "digest")
                    components[index]["image"] = image
                }
            }
            spec[list] = components
        }
        return missing
    }

    /// The spec as JSON for the API.
    public static func json(_ spec: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: spec, options: .sortedKeys)) ?? Data("{}".utf8)
    }

    /// Which of a database's bindable values a variable names: `POSTGRES_PASSWORD` is the
    /// password, `DB_HOST` the hostname, `DATABASE_URL` the whole address. Nil for anything else.
    public static func databaseField(_ key: String) -> String? {
        let key = key.uppercased()
        let databaseWords = ["POSTGRES", "PG", "DB", "DATABASE", "MYSQL", "MARIADB"]
        let words = key.split(separator: "_").map(String.init)
        if ["DATABASE_URL", "DB_URL", "POSTGRES_URL", "POSTGRESQL_URL", "PG_URL", "MYSQL_URL"].contains(key) || key.hasSuffix("_DATABASE_URL") { return "DATABASE_URL" }
        if ["PGPASSWORD", "PGUSER", "PGHOST", "PGPORT", "PGDATABASE"].contains(key) {
            return ["PGPASSWORD": "PASSWORD", "PGUSER": "USERNAME", "PGHOST": "HOSTNAME", "PGPORT": "PORT", "PGDATABASE": "DATABASE"][key]
        }
        guard let first = words.first, databaseWords.contains(first), words.count >= 2 else { return nil }
        switch words.dropFirst().joined(separator: "_") {
        case "PASSWORD", "PASS", "PWD": return "PASSWORD"
        case "USER", "USERNAME": return "USERNAME"
        case "HOST", "HOSTNAME": return "HOSTNAME"
        case "PORT": return "PORT"
        case "DB", "NAME", "DATABASE": return "DATABASE"
        case "CA_CERT", "SSL_CA", "CA": return "CA_CERT"
        default: return nil
        }
    }

    /// `${db.PASSWORD}` and friends for a variable the spec's database can answer: the
    /// Postgres one when there are several.
    public static func binding(key: String, databases: [[String: Any]]) -> String? {
        guard let field = databaseField(key) else { return nil }
        let database = databases.first { ($0["engine"] as? String)?.uppercased() == "PG" } ?? databases.first
        guard let name = database?["name"] as? String, !name.isEmpty else { return nil }
        return "${\(name).\(field)}"
    }

    /// The secrets the spec's database answers, with the value each gets, for the deploy sheet.
    public static func databaseBindings(in spec: [String: Any]) -> [(needed: Needed, binding: String)] {
        let databases = spec["databases"] as? [[String: Any]] ?? []
        guard !databases.isEmpty else { return [] }
        let empty = Set(secrets(in: spec).map(\.id))
        var found: [(Needed, String)] = []
        func scan(_ envs: Any?, component: String?) {
            for env in envs as? [[String: Any]] ?? [] where (env["type"] as? String)?.uppercased() == "SECRET" && ((env["value"] as? String) ?? "").isEmpty {
                guard let key = env["key"] as? String, let bound = binding(key: key, databases: databases) else { continue }
                let needed = Needed(component: component, key: key)
                if empty.contains(needed.id) { found.append((needed, bound)) }
            }
        }
        scan(spec["envs"], component: nil)
        for list in componentLists {
            for component in spec[list] as? [[String: Any]] ?? [] { scan(component["envs"], component: component["name"] as? String) }
        }
        return found
    }

    /// Every secret the file asks for, for the deploy sheet.
    public static func secrets(in spec: [String: Any]) -> [Needed] {
        var all: [Needed] = []
        func scan(_ envs: Any?, component: String?) {
            for env in envs as? [[String: Any]] ?? [] where (env["type"] as? String)?.uppercased() == "SECRET" {
                if let key = env["key"] as? String { all.append(Needed(component: component, key: key)) }
            }
        }
        scan(spec["envs"], component: nil)
        for list in componentLists {
            for component in spec[list] as? [[String: Any]] ?? [] { scan(component["envs"], component: component["name"] as? String) }
        }
        return all
    }
}

extension DOAppSpec.SpecProblem {
    init(message: String) { self.message = message }
}
