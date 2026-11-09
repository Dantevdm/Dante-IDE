import Foundation

/// Security findings and recommendations for a DigitalOcean deploy: the app spec (the file in
/// the repo and the app as it runs), the Dockerfiles that build it, the live site's headers,
/// and the app's health, alerts and databases. Pure: the page gathers the inputs.
public struct DOAdvice: Equatable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable, CaseIterable {
        case info, low, medium, high, critical

        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .info: "Tip"
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            case .critical: "Critical"
            }
        }
    }

    public enum Area: String, Sendable {
        case secrets, network, image, reliability, monitoring, cost, data

        public var title: String {
            switch self {
            case .secrets: "Secrets"
            case .network: "Network and HTTPS"
            case .image: "Image"
            case .reliability: "Reliability"
            case .monitoring: "Monitoring"
            case .cost: "Cost"
            case .data: "Data"
            }
        }
    }

    /// Stable across runs: rule and where.
    public var id: String
    public var severity: Severity
    public var area: Area
    public var title: String
    /// Why it matters, in a sentence or two.
    public var detail: String
    /// What to do.
    public var fix: String
    /// Where: "web", ".do/app.yaml", "api/Dockerfile".
    public var place: String?

    /// Security findings, as opposed to recommendations.
    public var isSecurity: Bool { [.secrets, .network, .image, .data].contains(area) && severity >= .medium }

    public struct Inputs: Sendable {
        /// `.do/app.yaml`, when the project has one.
        public var file: DOAppSpec?
        /// Its text, to spot values written into it.
        public var fileText: String?
        /// The app as DigitalOcean runs it.
        public var live: DOApp?
        /// Dockerfiles by path, and whether the context has a .dockerignore that leaves out .env.
        public var dockerfiles: [String: String]
        public var ignoresEnv: [String: Bool]
        /// The context folders that hold a .env file.
        public var envFiles: Set<String>
        /// The live URL's response headers (lowercased names), when it answered.
        public var headers: [String: String]?
        public var health: [DOComponentHealth]
        public var alerts: [DOAlert]
        public var restarts: [String: Double]
        public var sizes: [DOInstanceSize]
        /// Trusted sources per managed database cluster the spec names.
        public var trustedSources: [String: [DOClient.FirewallRule]]

        public init(file: DOAppSpec? = nil, fileText: String? = nil, live: DOApp? = nil, dockerfiles: [String: String] = [:], ignoresEnv: [String: Bool] = [:],
                    envFiles: Set<String> = [], headers: [String: String]? = nil, health: [DOComponentHealth] = [], alerts: [DOAlert] = [],
                    restarts: [String: Double] = [:], sizes: [DOInstanceSize] = [], trustedSources: [String: [DOClient.FirewallRule]] = [:]) {
            self.file = file
            self.fileText = fileText
            self.live = live
            self.dockerfiles = dockerfiles
            self.ignoresEnv = ignoresEnv
            self.envFiles = envFiles
            self.headers = headers
            self.health = health
            self.alerts = alerts
            self.restarts = restarts
            self.sizes = sizes
            self.trustedSources = trustedSources
        }
    }

    public static func analyse(_ inputs: Inputs) -> [DOAdvice] {
        var advice: [DOAdvice] = []
        func add(_ id: String, _ severity: Severity, _ area: Area, _ title: String, _ detail: String, fix: String, place: String?) {
            let key = id + "|" + (place ?? "")
            guard !advice.contains(where: { $0.id == key }) else { return }
            advice.append(DOAdvice(id: key, severity: severity, area: area, title: title, detail: detail, fix: fix, place: place))
        }
        let spec = inputs.file ?? inputs.live?.spec

        // Secrets
        if let file = inputs.file {
            for (component, env) in allEnvs(file) {
                let place = component ?? "app"
                guard let value = env.value, !value.isEmpty, !value.hasPrefix("${"), !env.isEncrypted else { continue }
                if env.isSecretType {
                    add("secret-in-file", .critical, .secrets, "\(env.key) has its value in .do/app.yaml",
                        "The file is in the repository, so the secret is in git history for anyone who can read it.",
                        fix: "Remove the value from the file (Dante asks for it when deploying), then change the secret where it was issued.", place: place)
                } else if SystemMap.isSecret(env.key) || looksLikeCredential(value) {
                    add("plain-secret", .critical, .secrets, "\(env.key) looks like a secret written in plain text",
                        "It's in .do/app.yaml in the repository and stored unencrypted by App Platform, visible to everyone on the team.",
                        fix: "Mark it type: SECRET without a value, deploy, and change the secret where it was issued.", place: place)
                }
            }
        }
        if let live = inputs.live?.spec {
            for (component, env) in allEnvs(live) where !env.isSecretType && SystemMap.isSecret(env.key) && !(env.value ?? "").hasPrefix("${") && !(env.value ?? "").isEmpty {
                add("plain-secret-live", .high, .secrets, "\(env.key) isn't stored as a secret",
                    "App Platform keeps GENERAL variables in plain text and shows them to everyone on the team.",
                    fix: "Make it type: SECRET.", place: component ?? "app")
            }
        }
        if let spec {
            for (component, env) in allEnvs(spec) where env.isSecretType && (env.scope ?? "RUN_AND_BUILD_TIME").uppercased() != "RUN_TIME" {
                add("secret-at-build", .low, .secrets, "\(env.key) is available while building",
                    "A secret that reaches the build can end up in the image or in build logs.",
                    fix: "Set scope: RUN_TIME unless the build needs it.", place: component ?? "app")
            }
        }

        // Images and Dockerfiles
        for (path, text) in inputs.dockerfiles.sorted(by: { $0.key < $1.key }) {
            let folder = (path as NSString).deletingLastPathComponent
            let lines = instructions(text)
            if !lines.contains(where: { $0.0 == "USER" && !["root", "0"].contains($0.1.trimmingCharacters(in: .whitespaces)) }) {
                add("root-user", .medium, .image, "The container runs as root",
                    "Anyone who gets code running in the app gets root inside the container, which makes breaking out or tampering easier.",
                    fix: "Add a user and switch to it before CMD (for example USER node, or adduser and USER app).", place: path)
            }
            let froms = lines.filter { $0.0 == "FROM" }.map { $0.1.split(separator: " ").filter { !$0.hasPrefix("--") }.map(String.init) }
            let stages = Set(froms.compactMap { words in words.count >= 3 && words[1].uppercased() == "AS" ? words[2].lowercased() : nil })
            for words in froms {
                let image = words.first ?? ""
                guard !image.isEmpty, !image.contains("$"), image.lowercased() != "scratch", !stages.contains(image.lowercased()) else { continue }
                let name = image.split(separator: "@").first.map(String.init) ?? image
                let tag = name.split(separator: "/").last?.split(separator: ":").dropFirst().first.map(String.init)
                if !image.contains("@") && (tag == nil || tag == "latest") {
                    add("unpinned-base", .low, .image, "\(name) has no version",
                        "Each build may pick up a different base image, so a deploy that worked can break without a code change.",
                        fix: "Pin a version (node:22-alpine) or a digest.", place: path)
                }
            }
            if inputs.envFiles.contains(folder), inputs.ignoresEnv[folder] != true, lines.contains(where: { $0.0 == "COPY" || $0.0 == "ADD" }) {
                add("env-in-image", .high, .secrets, "The .env file goes into the image",
                    "The build copies \(folder.isEmpty ? "the project" : folder) and nothing leaves out .env, so its secrets are baked into the image and pushed to the registry.",
                    fix: "Add .env and .env.* to .dockerignore.", place: folder.isEmpty ? ".dockerignore" : folder + "/.dockerignore")
            }
        }
        if let spec {
            for (_, component) in spec.components {
                guard let image = component.image else { continue }
                if image.digest == nil && (image.tag == nil || image.tag == "latest") {
                    add("latest-tag", .medium, .image, "\(component.name) deploys :latest",
                        "Whatever was last pushed goes live, and a rollback can't bring back the image it replaced.",
                        fix: "Deploy versioned tags (Dante tags each build with its commit).", place: component.name)
                }
                if image.registryType?.uppercased() == "DOCKER_HUB" && image.digest == nil {
                    add("public-image", .low, .image, "\(component.name) comes from Docker Hub by tag",
                        "A tag on someone else's image can be moved to different contents.",
                        fix: "Pin it by digest, or copy it into your DigitalOcean registry.", place: component.name)
                }
            }
        }

        // Network and HTTPS
        if let headers = inputs.headers {
            let checks: [(String, String, String, Severity)] = [
                ("strict-transport-security", "No HSTS header", "Browsers may still try plain HTTP first, where a network attacker can step in.", .medium),
                ("x-content-type-options", "No X-Content-Type-Options", "Browsers may guess a response's type and run a file as script.", .low),
                ("content-security-policy", "No Content-Security-Policy", "Without one, an injected script runs with the page's full rights.", .low),
            ]
            for (header, title, detail, severity) in checks where headers[header] == nil {
                add("header-" + header, severity, .network, title, detail, fix: "Have the app send \(header.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")).", place: "live site")
            }
            if headers["content-security-policy"] == nil, headers["x-frame-options"] == nil {
                add("header-frames", .low, .network, "Other sites can frame the page",
                    "A page shown inside another site's frame can be used to trick people into clicking (clickjacking).",
                    fix: "Send X-Frame-Options: DENY or a frame-ancestors policy.", place: "live site")
            }
            for header in ["x-powered-by", "server"] {
                guard let value = headers[header], value.rangeOfCharacter(from: .decimalDigits) != nil || header == "x-powered-by" else { continue }
                add("banner-" + header, .low, .network, "The site says what it runs (\(header): \(value))",
                    "Naming the framework and version tells attackers which known holes to try.",
                    fix: "Turn the header off (app.disable('x-powered-by') in Express, server_tokens off in nginx).", place: "live site")
            }
        }
        if let spec {
            for domain in spec.domains ?? [] where domain.minimumTLSVersion == "1.2" || domain.minimumTLSVersion == nil {
                add("tls", .info, .network, "\(domain.domain) accepts TLS 1.2",
                    "1.2 is still safe; 1.3 alone is faster and drops older ciphers, if every client you serve supports it.",
                    fix: "Set minimum_tls_version: \"1.3\" on the domain.", place: domain.domain)
            }
        }

        // Data
        if let spec {
            for database in spec.databases ?? [] {
                if database.production != true {
                    add("dev-db", .medium, .data, "\(database.name) is a dev database",
                        "Dev databases have no backups, no standby and limited connections: fine to try things, not for real data.",
                        fix: "Move to a managed database cluster (production: true with cluster_name) before real data goes in.", place: database.name)
                } else if let cluster = database.clusterName {
                    let rules = inputs.trustedSources[cluster]
                    if rules?.isEmpty == true {
                        add("open-db", .high, .data, "\(cluster) accepts connections from anywhere",
                            "With no trusted sources, anyone on the internet who learns the password can connect.",
                            fix: "Add the app as a trusted source in the database's settings (App Platform adds it when you tick Trusted sources).", place: cluster)
                    }
                }
            }
        }

        // Reliability
        if let spec {
            for component in spec.services ?? [] {
                if component.healthCheck?.httpPath == nil {
                    add("no-health", .medium, .reliability, "\(component.name) has no health check path",
                        "App Platform only checks the port opens, so a deploy that starts but can't serve still replaces the working one.",
                        fix: "Add health_check: http_path: /healthz (a route that answers 200 when the app is ready).", place: component.name)
                }
                if (component.instanceCount ?? 1) < 2 && component.autoscaling == nil {
                    add("single", .info, .reliability, "\(component.name) runs one instance",
                        "If it crashes, the site is down until it restarts.",
                        fix: "Run two instances or turn on autoscaling (dedicated sizes) when it matters.", place: component.name)
                }
                if component.deploysOnPush && ["main", "master"].contains(component.github?.branch ?? component.gitlab?.branch ?? component.bitbucket?.branch ?? "") {
                    add("push-deploys", .info, .reliability, "Every push to main goes live",
                        "A push deploys before any tests run, unless CI guards the branch.",
                        fix: "Protect main with required checks, or deploy from a release branch.", place: component.name)
                }
            }
        }
        for health in inputs.health where !health.isHealthy || (health.replicasReady ?? 1) < (health.replicasDesired ?? 1) {
            add("unhealthy", .high, .reliability, "\(health.name) isn't healthy",
                "\(health.replicasReady ?? 0) of \(health.replicasDesired ?? 1) instances are ready (\(health.state?.lowercased() ?? "unknown")).",
                fix: "Look at its runtime logs below.", place: health.name)
        }
        for (component, count) in inputs.restarts.sorted(by: { $0.key < $1.key }) where count >= 1 {
            add("restarts", count >= 3 ? .high : .medium, .reliability, "\(component) restarted \(Int(count)) time\(count == 1 ? "" : "s") in the last day",
                "Restarts usually mean it ran out of memory or crashed.", fix: "Check the runtime logs around the restarts; size up if memory was full.", place: component)
        }

        // Monitoring
        if let spec {
            let rules = Set((spec.alerts ?? []).map(\.rule))
            if !rules.contains("DEPLOYMENT_FAILED") {
                add("alert-deploy", .medium, .monitoring, "Nobody hears about a failed deploy",
                    "Without the alert, a failed deploy is only seen by whoever looks.", fix: "Add alerts: - rule: DEPLOYMENT_FAILED.", place: "app")
            }
            if !rules.contains("DOMAIN_FAILED"), !(spec.domains ?? []).isEmpty {
                add("alert-domain", .low, .monitoring, "No alert when a domain stops working",
                    "Certificates and DNS can fail silently.", fix: "Add alerts: - rule: DOMAIN_FAILED.", place: "app")
            }
            for component in spec.services ?? [] where !(component.alerts ?? []).contains(where: { ["CPU_UTILIZATION", "MEM_UTILIZATION", "RESTART_COUNT"].contains($0.rule) }) {
                add("alert-component", .low, .monitoring, "\(component.name) has no CPU, memory or restart alert",
                    "You find out it's struggling when people do.",
                    fix: "Add alerts on the component: MEM_UTILIZATION over 80 for five minutes, and RESTART_COUNT over 2.", place: component.name)
            }
            if (spec.services ?? []).allSatisfy({ $0.logDestinations == nil }), !(spec.services ?? []).isEmpty {
                add("logs", .info, .monitoring, "Logs stay only in App Platform",
                    "Runtime logs are kept for a short while; older ones are gone when you need them.",
                    fix: "Forward logs (log_destinations) to Papertrail, Datadog, Logtail or OpenSearch.", place: "app")
            }
        }
        if !inputs.alerts.isEmpty, !inputs.alerts.contains(where: \.notifies) {
            add("alert-nobody", .medium, .monitoring, "Alerts don't notify anyone",
                "The app has alerts but no email or Slack channel, so they fire into the void.",
                fix: "Add an email or Slack destination to the alerts in the app's settings.", place: "app")
        }

        // Cost
        for health in inputs.health {
            guard let component = spec?.services?.first(where: { $0.name == health.name }), let slug = component.instanceSizeSlug,
                  let size = inputs.sizes.first(where: { $0.slug == slug }) else { continue }
            if let memory = health.memoryUsagePercent, memory > 85 {
                add("size-up", .medium, .cost, "\(health.name) is using \(Int(memory))% of its memory",
                    "Near the limit it gets killed and restarted.", fix: "Move up from \(size.name ?? slug) to the next size.", place: health.name)
            } else if let cpu = health.cpuUsagePercent, let memory = health.memoryUsagePercent, cpu < 5, memory < 30, (size.monthly ?? 0) > 12 {
                add("size-down", .info, .cost, "\(health.name) is mostly idle",
                    "It uses \(Int(cpu))% CPU and \(Int(memory))% memory on \(size.name ?? slug) ($\(Int(size.monthly ?? 0)) a month).",
                    fix: "A smaller size would likely do.", place: health.name)
            }
        }

        return advice.sorted { ($0.severity, $1.title) > ($1.severity, $0.title) }
    }

    // MARK: Helpers

    static func allEnvs(_ spec: DOAppSpec) -> [(String?, DOAppSpec.Env)] {
        (spec.envs ?? []).map { (nil, $0) } + spec.components.flatMap { _, component in (component.envs ?? []).map { (component.name, $0) } }
    }

    /// (INSTRUCTION, rest) per Dockerfile line, continuation lines joined.
    static func instructions(_ text: String) -> [(String, String)] {
        var joined: [String] = []
        var current = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasSuffix("\\") {
                current += line.dropLast() + " "
            } else {
                joined.append(current + line)
                current = ""
            }
        }
        return joined.compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let first = parts.first else { return nil }
            return (first.uppercased(), parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// Values shaped like keys: known prefixes, or long random-looking strings.
    static func looksLikeCredential(_ value: String) -> Bool {
        let prefixes = ["sk_live_", "sk-", "ghp_", "gho_", "xox", "AKIA", "dop_v1_", "doo_v1_", "AIza", "-----BEGIN"]
        if prefixes.contains(where: { value.hasPrefix($0) }) { return true }
        if value.contains("://"), let at = value.firstIndex(of: "@"), value[..<at].contains(":") { return true }  // user:password@host
        let letters = value.filter { $0.isLetter }.count, digits = value.filter(\.isNumber).count
        return value.count >= 32 && !value.contains(" ") && letters > 8 && digits > 4
    }
}
