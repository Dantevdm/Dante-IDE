import Foundation
import Yams

/// The part of an App Platform app spec Dante reads and writes (docs: App Platform › Reference ›
/// App Specification). Keys are DigitalOcean's own snake_case, so the same type reads the
/// API's JSON and `.do/app.yaml`. Only what Dante plans and checks is modelled; a spec is sent
/// to DigitalOcean from the file itself (`DOSpecSend`), so nothing else in it is ever lost.
public struct DOAppSpec: Codable, Equatable, Sendable {
    public var name: String
    public var region: String?
    public var services: [Component]?
    public var staticSites: [Component]?
    public var workers: [Component]?
    public var jobs: [Component]?
    public var databases: [Database]?
    public var envs: [Env]?
    public var alerts: [Alert]?
    public var domains: [Domain]?
    public var ingress: Ingress?

    enum CodingKeys: String, CodingKey {
        case name, region, services, staticSites = "static_sites", workers, jobs, databases, envs, alerts, domains, ingress
    }

    public init(name: String, region: String? = nil) {
        self.name = name
        self.region = region
    }

    public enum Kind: String, Sendable, CaseIterable {
        case service, staticSite = "static_site", worker, job

        public var title: String {
            switch self {
            case .service: "Service"
            case .staticSite: "Static site"
            case .worker: "Worker"
            case .job: "Job"
            }
        }
    }

    /// Every component with its kind, services first.
    public var components: [(kind: Kind, component: Component)] {
        (services ?? []).map { (.service, $0) } + (staticSites ?? []).map { (.staticSite, $0) }
            + (workers ?? []).map { (.worker, $0) } + (jobs ?? []).map { (.job, $0) }
    }

    public struct Component: Codable, Equatable, Sendable {
        public var name: String
        public var github: RepoSource?
        public var gitlab: RepoSource?
        public var bitbucket: RepoSource?
        public var git: GitSource?
        public var image: ImageSource?
        public var sourceDir: String?
        public var dockerfilePath: String?
        public var buildCommand: String?
        public var runCommand: String?
        public var outputDir: String?
        public var httpPort: Int?
        public var instanceCount: Int?
        public var instanceSizeSlug: String?
        public var autoscaling: Autoscaling?
        public var healthCheck: HealthCheck?
        public var envs: [Env]?
        public var alerts: [Alert]?
        public var kind: String?
        public var logDestinations: [LogDestination]?

        enum CodingKeys: String, CodingKey {
            case name, github, gitlab, bitbucket, git, image
            case sourceDir = "source_dir", dockerfilePath = "dockerfile_path", buildCommand = "build_command", runCommand = "run_command"
            case outputDir = "output_dir", httpPort = "http_port", instanceCount = "instance_count", instanceSizeSlug = "instance_size_slug"
            case autoscaling, healthCheck = "health_check", envs, alerts, kind, logDestinations = "log_destinations"
        }

        public init(name: String) { self.name = name }

        /// Where the code comes from, in words.
        public var sourceLabel: String {
            if let github { return "GitHub \(github.repo ?? "") · \(github.branch ?? "main")" }
            if let gitlab { return "GitLab \(gitlab.repo ?? "") · \(gitlab.branch ?? "main")" }
            if let bitbucket { return "Bitbucket \(bitbucket.repo ?? "") · \(bitbucket.branch ?? "main")" }
            if let git { return "git \(git.repoCloneURL ?? "") · \(git.branch ?? "main")" }
            if let image {
                let registry = image.registryType == "DOCR" ? "your DigitalOcean registry" : image.registryType ?? "a registry"
                return "image \(image.repository ?? ""):\(image.tag ?? "latest") from \(registry)"
            }
            return "no source"
        }

        public var deploysOnPush: Bool {
            github?.deployOnPush == true || gitlab?.deployOnPush == true || bitbucket?.deployOnPush == true || image?.deployOnPush?.enabled == true
        }
    }

    public struct RepoSource: Codable, Equatable, Sendable {
        public var repo: String?
        public var branch: String?
        public var deployOnPush: Bool?

        enum CodingKeys: String, CodingKey { case repo, branch, deployOnPush = "deploy_on_push" }

        public init(repo: String, branch: String, deployOnPush: Bool) {
            self.repo = repo
            self.branch = branch
            self.deployOnPush = deployOnPush
        }
    }

    public struct GitSource: Codable, Equatable, Sendable {
        public var repoCloneURL: String?
        public var branch: String?

        enum CodingKeys: String, CodingKey { case repoCloneURL = "repo_clone_url", branch }
    }

    public struct ImageSource: Codable, Equatable, Sendable {
        public struct Push: Codable, Equatable, Sendable { public var enabled: Bool? }
        public var registryType: String?
        public var registry: String?
        public var repository: String?
        public var tag: String?
        public var digest: String?
        public var deployOnPush: Push?

        enum CodingKeys: String, CodingKey { case registryType = "registry_type", registry, repository, tag, digest, deployOnPush = "deploy_on_push" }
    }

    public struct Env: Codable, Equatable, Sendable {
        public var key: String
        public var value: String?
        public var scope: String?
        public var type: String?

        public init(key: String, value: String? = nil, scope: String? = nil, type: String? = nil) {
            self.key = key
            self.value = value
            self.scope = scope
            self.type = type
        }

        public var isSecretType: Bool { type?.uppercased() == "SECRET" }
        /// DigitalOcean hands secrets back encrypted (`EV[1:…]`).
        public var isEncrypted: Bool { value?.hasPrefix("EV[") == true }
    }

    public struct HealthCheck: Codable, Equatable, Sendable {
        public var httpPath: String?
        public var port: Int?
        public var initialDelaySeconds: Int?
        public var periodSeconds: Int?
        public var timeoutSeconds: Int?
        public var failureThreshold: Int?

        enum CodingKeys: String, CodingKey {
            case httpPath = "http_path", port, initialDelaySeconds = "initial_delay_seconds", periodSeconds = "period_seconds"
            case timeoutSeconds = "timeout_seconds", failureThreshold = "failure_threshold"
        }

        public init(httpPath: String) { self.httpPath = httpPath }
    }

    public struct Autoscaling: Codable, Equatable, Sendable {
        public var minInstanceCount: Int?
        public var maxInstanceCount: Int?

        enum CodingKeys: String, CodingKey { case minInstanceCount = "min_instance_count", maxInstanceCount = "max_instance_count" }
    }

    public struct Alert: Codable, Equatable, Sendable {
        public var rule: String
        public var disabled: Bool?
        public var `operator`: String?
        public var value: Double?
        public var window: String?

        public init(rule: String, operator: String? = nil, value: Double? = nil, window: String? = nil) {
            self.rule = rule
            self.operator = `operator`
            self.value = value
            self.window = window
        }
    }

    public struct Database: Codable, Equatable, Sendable {
        public var name: String
        public var engine: String?
        public var production: Bool?
        public var clusterName: String?
        public var version: String?

        enum CodingKeys: String, CodingKey { case name, engine, production, clusterName = "cluster_name", version }

        public init(name: String, engine: String, production: Bool) {
            self.name = name
            self.engine = engine
            self.production = production
        }
    }

    public struct Domain: Codable, Equatable, Sendable {
        public var domain: String
        public var type: String?
        public var minimumTLSVersion: String?

        enum CodingKeys: String, CodingKey { case domain, type, minimumTLSVersion = "minimum_tls_version" }
    }

    /// Which component answers which path, when there's more than one.
    public struct Ingress: Codable, Equatable, Sendable {
        public var rules: [Rule]?

        public struct Rule: Codable, Equatable, Sendable {
            public var match: Match?
            public var component: Target?

            public init(prefix: String, component: String) {
                match = Match(path: .init(prefix: prefix))
                self.component = Target(name: component)
            }
        }

        public struct Match: Codable, Equatable, Sendable {
            public var path: Path?
            public struct Path: Codable, Equatable, Sendable { public var prefix: String? }
        }

        public struct Target: Codable, Equatable, Sendable {
            public var name: String?
            public var preservePathPrefix: Bool?

            enum CodingKeys: String, CodingKey { case name, preservePathPrefix = "preserve_path_prefix" }
        }
    }

    public struct LogDestination: Codable, Equatable, Sendable {
        public var name: String?
    }

    // MARK: Reading and writing

    public static let path = ".do/app.yaml"

    /// Reads `.do/app.yaml` (or a spec the API sent as JSON, which YAML reads too).
    public static func read(_ text: String) -> Result<DOAppSpec, SpecProblem> {
        do {
            return .success(try YAMLDecoder().decode(DOAppSpec.self, from: text))
        } catch {
            return .failure(SpecProblem(error))
        }
    }

    public static func fromJSON(_ data: Data) -> DOAppSpec? {
        try? JSONDecoder().decode(DOAppSpec.self, from: data)
    }

    /// YAML in the spec's own order, with a header saying what the file is.
    public func yaml(header: [String] = []) -> String {
        let body = (try? YAMLEncoder().encode(self)) ?? ""
        return header.map { "# " + $0 }.joined(separator: "\n") + (header.isEmpty ? "" : "\n") + body
    }

    public struct SpecProblem: Error, Equatable, Sendable {
        public var message: String

        init(_ error: Error) {
            switch error {
            case DecodingError.keyNotFound(let key, let context):
                message = "\(Self.place(context.codingPath + [key])) is missing."
            case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
                message = "\(Self.place(context.codingPath)) isn't the right kind of value."
            case DecodingError.dataCorrupted(let context):
                message = context.underlyingError.map { "It isn't valid YAML: \($0.localizedDescription)" } ?? "It isn't valid YAML."
            default:
                message = "It isn't valid YAML: \(error.localizedDescription)"
            }
        }

        static func place(_ path: [CodingKey]) -> String {
            path.isEmpty ? "The spec" : path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
    }
}
