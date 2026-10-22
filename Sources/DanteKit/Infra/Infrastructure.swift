import Foundation
import Yams

/// How the project is built, shipped and run in the cloud, read from its own files: the
/// pipelines (Azure DevOps, GitHub Actions, GitLab), the infrastructure templates
/// (CloudFormation and SAM, Terraform, ARM) and the links between them. Pure; `read`
/// returns a file's text.
public struct Infrastructure: Equatable, Sendable {
    /// Where a resource sits in the picture, left to right, then the supporting rows.
    public enum Tier: Int, CaseIterable, Sendable, Comparable {
        case edge, compute, data, messaging, registry, security, network, observability, other

        public var title: String {
            switch self {
            case .edge: "Edge"
            case .compute: "Compute"
            case .data: "Data"
            case .messaging: "Messaging"
            case .registry: "Images"
            case .security: "Security"
            case .network: "Network"
            case .observability: "Observability"
            case .other: "Other"
            }
        }

        /// The traffic path runs through these; the rest support it.
        public var isMain: Bool { [.edge, .compute, .data, .messaging].contains(self) }

        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Provider: String, Sendable {
        case aws = "AWS", azure = "Azure", google = "Google Cloud", other = "Cloud"
    }

    public struct Resource: Identifiable, Equatable, Sendable, Hashable {
        public var id: String
        /// The template's own name for it ("EcsService").
        public var name: String
        /// "AWS::ECS::Service", "aws_ecs_service", "Microsoft.Web/sites".
        public var type: String
        /// "ECS service", "Load balancer listener rule".
        public var service: String
        public var tier: Tier
        public var symbol: String
        public var stack: String
        public var file: String
        public var line: Int?
        /// Not declared in a template: something the pipelines touch that lives elsewhere.
        public var isOutside = false

        public init(id: String, name: String, type: String, service: String, tier: Tier, symbol: String, stack: String, file: String, line: Int? = nil) {
            self.id = id
            self.name = name
            self.type = type
            self.service = service
            self.tier = tier
            self.symbol = symbol
            self.stack = stack
            self.file = file
            self.line = line
        }
    }

    public struct Stack: Identifiable, Equatable, Sendable, Hashable {
        public var id: String
        public var name: String
        /// "CloudFormation", "Terraform", "ARM".
        public var tool: String
        public var files: [String]
        /// non-prod, prod… from file names and parameter files.
        public var environments: [String]
        public var parameters: Int
        public var outputs: Int
    }

    public enum StepKind: String, Sendable, CaseIterable {
        case build, test, scan, image, push, migrate, stack, deploy, approval, script

        public var symbol: String {
            switch self {
            case .build: "hammer"
            case .test: "checkmark.seal"
            case .scan: "shield.lefthalf.filled"
            case .image: "shippingbox"
            case .push: "arrow.up.to.line"
            case .migrate: "cylinder.split.1x2"
            case .stack: "square.stack.3d.up"
            case .deploy: "paperplane"
            case .approval: "hand.raised"
            case .script: "terminal"
            }
        }
    }

    public struct Step: Equatable, Sendable, Hashable {
        public var kind: StepKind
        public var title: String
        /// The command or task, first line only.
        public var detail: String
        public var line: Int?
        /// The whole command, for telling what it touches.
        public var command: String = ""
    }

    public struct Stage: Identifiable, Equatable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var jobs: [String]
        public var dependsOn: [String]
        public var environment: String?
        public var steps: [Step]
        public var line: Int?

        /// What the stage mostly does, for its icon: the most telling step.
        public var kind: StepKind {
            let order: [StepKind] = [.deploy, .stack, .migrate, .push, .image, .approval, .test, .scan, .build, .script]
            return order.first { kind in steps.contains { $0.kind == kind } } ?? .script
        }
    }

    public struct Pipeline: Identifiable, Equatable, Sendable, Hashable {
        public var id: String
        public var name: String
        /// "Azure DevOps", "GitHub Actions", "GitLab CI".
        public var system: String
        public var file: String
        public var branches: [String]
        public var stages: [Stage]
        public var environment: String?
    }

    public struct Link: Equatable, Sendable, Hashable {
        public var from: String
        public var to: String
        /// "routes to", "pulls image", "logs to"…
        public var label: String
        /// Read from a reference in the template, rather than inferred from the kinds.
        public var declared: Bool
    }

    public var provider: Provider
    public var stacks: [Stack]
    public var resources: [Resource]
    public var pipelines: [Pipeline]
    /// Between resources, left to right along the traffic.
    public var links: [Link]
    /// Pipeline stage ids ("pipeline#stage") to the resources they change.
    public var deploys: [Link]
    /// Container builds: the Dockerfiles and what they're built from.
    public var dockerfiles: [String]

    public var isEmpty: Bool { resources.isEmpty && pipelines.isEmpty }
    public func resource(_ id: String) -> Resource? { resources.first { $0.id == id } }
    public var environments: [String] {
        var seen: [String] = []
        for name in stacks.flatMap(\.environments) + pipelines.compactMap(\.environment) where !seen.contains(name) { seen.append(name) }
        return seen
    }

    public init(provider: Provider = .other, stacks: [Stack] = [], resources: [Resource] = [], pipelines: [Pipeline] = [], links: [Link] = [], deploys: [Link] = [], dockerfiles: [String] = []) {
        self.provider = provider
        self.stacks = stacks
        self.resources = resources
        self.pipelines = pipelines
        self.links = links
        self.deploys = deploys
        self.dockerfiles = dockerfiles
    }

    /// Files worth reading: templates, pipelines, Dockerfiles. Everything else is left alone.
    public static func isCandidate(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let ext = (lower as NSString).pathExtension
        if lower.contains("node_modules/") || lower.contains("/.terraform/") { return false }
        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") { return true }
        if ext == "tf" { return true }
        if lower.hasPrefix(".github/workflows/") || name == ".gitlab-ci.yml" || name.hasPrefix("azure-pipelines") { return true }
        return ["json", "yaml", "yml", "template"].contains(ext) && !name.hasPrefix("package") && !name.hasPrefix("tsconfig") && !name.contains("lock")
    }

    // MARK: Building

    public static func detect(files: [String], read: (String) -> String?) -> Infrastructure {
        var stacks: [String: Stack] = [:]
        var resources: [String: Resource] = [:]
        var references: [(from: String, to: String)] = []
        var pipelines: [Pipeline] = []
        var dockerfiles: [String] = []
        // Templates first, so pipelines can name the stacks they deploy.
        for file in files.sorted() where isCandidate(file) {
            let lower = file.lowercased()
            let name = (lower as NSString).lastPathComponent
            if name == "dockerfile" || name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") {
                dockerfiles.append(file)
                continue
            }
            guard let text = read(file), text.utf8.count < 2_000_000 else { continue }
            if let template = Template.read(file: file, text: text) {
                let stackID = stackName(for: file)
                var stack = stacks[stackID] ?? Stack(id: stackID, name: stackID, tool: template.tool, files: [], environments: [], parameters: 0, outputs: 0)
                stack.files.append(file)
                if let environment = environment(in: file), !stack.environments.contains(environment) { stack.environments.append(environment) }
                stack.parameters = max(stack.parameters, template.parameters)
                stack.outputs = max(stack.outputs, template.outputs)
                stacks[stackID] = stack
                // The same resource in a template and its per-environment copies is one box.
                for resource in template.resources {
                    let id = stackID + "/" + resource.name
                    if resources[id] == nil {
                        let (service, tier, symbol) = Catalog.describe(resource.type)
                        resources[id] = Resource(id: id, name: resource.name, type: resource.type, service: service, tier: tier, symbol: symbol, stack: stackID, file: file, line: resource.line)
                    }
                    for target in resource.references { references.append((id, stackID + "/" + target)) }
                }
            } else if let pipeline = PipelineReader.read(file: file, text: text) {
                pipelines.append(pipeline)
            }
        }
        // Parameter files only add environments to the stack in the same folder tree.
        for file in files where isCandidate(file) && environment(in: file) != nil {
            let stackID = stackName(for: file)
            if var stack = stacks[stackID], let environment = environment(in: file), !stack.environments.contains(environment) {
                stack.environments.append(environment)
                stacks[stackID] = stack
            }
        }

        var links: [String: Link] = [:]
        func link(_ a: String, _ b: String, declared: Bool) {
            guard a != b, let first = resources[a], let second = resources[b] else { return }
            // Drawn along the traffic: the earlier tier on the left.
            let (from, to) = first.tier <= second.tier ? (first, second) : (second, first)
            let key = from.id + "→" + to.id
            if links[key] == nil || declared { links[key] = Link(from: from.id, to: to.id, label: verb(from, to), declared: declared) }
        }
        for (from, to) in references { link(from, to, declared: true) }
        // Across stacks (exports and imports rarely name each other plainly): link the
        // kinds that always work together.
        let all = Array(resources.values)
        func of(_ services: [String]) -> [Resource] { all.filter { services.contains($0.service) } }
        let rules: [([String], [String])] = [
            (["DNS record"], ["Listener rule", "Load balancer", "CDN distribution", "API Gateway"]),
            (["CDN distribution"], ["Load balancer", "Storage bucket", "API Gateway"]),
            (["Listener rule"], ["Target group"]),
            (["Load balancer", "Listener"], ["Listener rule", "Target group"]),
            (["Target group"], ["ECS service", "Instance", "Auto Scaling group"]),
            (["API Gateway"], ["Function"]),
            (["ECS service"], ["Task definition", "ECS cluster"]),
            (["Task definition", "Function"], ["Container registry", "Log group"]),
        ]
        for (left, right) in rules {
            for a in of(left) {
                for b in of(right) where !links.values.contains(where: { Set([$0.from, $0.to]) == Set([a.id, b.id]) }) {
                    link(a.id, b.id, declared: false)
                }
            }
        }

        // What each stage changes: the resources its steps name or that its kind of step touches.
        var deploys: Set<Link> = []
        var outside: [String: Resource] = [:]
        for pipeline in pipelines {
            for stage in pipeline.stages {
                let id = pipeline.id + "#" + stage.id
                for step in stage.steps {
                    var targets: [Resource] = []
                    switch step.kind {
                    case .push, .image: targets = of(["Container registry"])
                    case .deploy:
                        let text = step.command.lowercased()
                        if text.contains("ecs") || text.contains("update-service") { targets = of(["ECS service"]) }
                        else if text.contains("lambda") { targets = of(["Function"]) }
                        else if text.contains("s3") { targets = of(["Storage bucket"]) }
                        else if text.contains("webapp") || text.contains("app service") { targets = of(["App Service"]) }
                        else { targets = all.filter { $0.tier == .compute } }
                    case .stack:
                        let named = stacks.values.filter { stack in stack.files.contains { step.command.contains(($0 as NSString).lastPathComponent) } || step.command.contains(stack.name) }
                        targets = named.isEmpty ? [] : all.filter { r in named.contains { $0.id == r.stack } && r.tier.isMain }
                    case .migrate:
                        targets = all.filter { $0.service == "Database" }
                        if targets.isEmpty {
                            let database = outside["database"] ?? {
                                var r = Resource(id: "outside/database", name: "Database", type: "database", service: "Database", tier: .data, symbol: "cylinder.split.1x2", stack: "", file: pipeline.file)
                                r.isOutside = true
                                return r
                            }()
                            outside["database"] = database
                            targets = [database]
                        }
                    default: break
                    }
                    let verb: String = switch step.kind {
                    case .push, .image: "pushes image"
                    case .migrate: "migrates"
                    case .stack: "deploys stack"
                    default: "deploys"
                    }
                    for target in targets { deploys.insert(Link(from: id, to: target.id, label: verb, declared: true)) }
                }
            }
        }
        // An outside database the compute reaches is part of the traffic path.
        var allResources = Array(resources.values) + Array(outside.values)
        if let database = outside["database"] {
            for service in all where service.service == "ECS service" || service.service == "Function" || service.service == "App Service" {
                links[service.id + "→" + database.id] = Link(from: service.id, to: database.id, label: "reads and writes", declared: false)
            }
        }
        allResources.sort { ($0.tier, $0.stack, $0.name) < ($1.tier, $1.stack, $1.name) }
        let types = allResources.map(\.type)
        let provider: Provider = types.contains { $0.hasPrefix("AWS::") || $0.hasPrefix("aws_") } ? .aws
            : types.contains { $0.hasPrefix("Microsoft.") || $0.hasPrefix("azurerm_") } ? .azure
            : types.contains { $0.hasPrefix("google_") } ? .google : .other
        return Infrastructure(provider: provider, stacks: stacks.values.sorted { $0.name < $1.name }, resources: allResources,
                              pipelines: pipelines.sorted { $0.file < $1.file }, links: links.values.sorted { ($0.from, $0.to) < ($1.from, $1.to) },
                              deploys: deploys.sorted { ($0.from, $0.to) < ($1.from, $1.to) }, dockerfiles: dockerfiles)
    }

    static func verb(_ from: Resource, _ to: Resource) -> String {
        switch (to.tier, to.service) {
        case (.registry, _): "pulls image"
        case (.observability, _): "logs to"
        case (.security, _): "secured by"
        case (.network, _): "runs in"
        case (_, "Task definition"): "runs"
        case (_, "ECS cluster"): "on"
        case (.data, _): "reads and writes"
        case (.messaging, _): "sends to"
        default: from.tier == .edge ? "routes to" : "uses"
        }
    }

    /// The stack a file belongs to: the folder above templates/, parameters/ and the like,
    /// else the file's own name.
    static func stackName(for file: String) -> String {
        let parts = file.split(separator: "/").map(String.init)
        let inner: Set<String> = ["templates", "template", "parameters", "params", "config", "environments", "envs", "documentation"]
        if parts.count >= 3, inner.contains(parts[parts.count - 2].lowercased()) { return parts[parts.count - 3] }
        if parts.count >= 2, (file as NSString).pathExtension == "tf" { return parts[parts.count - 2] }
        return ((parts.last ?? file) as NSString).deletingPathExtension
    }

    /// "non-prod" from "…-params-non-prod.json", "prod" from "cd-prod.yml".
    static func environment(in file: String) -> String? {
        let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let words = stem.split(whereSeparator: { "-_.".contains($0) }).map(String.init)
        let joined = words.joined(separator: "-")
        for (pattern, name) in [("non-prod", "non-prod"), ("nonprod", "non-prod"), ("preprod", "pre-prod"), ("pre-prod", "pre-prod"), ("staging", "staging"), ("stage", "staging"),
                                ("uat", "uat"), ("qa", "qa"), ("test", "test"), ("dev", "dev"), ("production", "prod"), ("prod", "prod")] {
            if words.contains(pattern) || (pattern.contains("-") && joined.contains(pattern)) { return name }
        }
        return nil
    }
}

// MARK: Templates

extension Infrastructure {
    struct Template {
        struct Entry {
            var name: String
            var type: String
            var line: Int?
            var references: Set<String>
        }

        var tool: String
        var resources: [Entry]
        var parameters: Int
        var outputs: Int

        static func read(file: String, text: String) -> Template? {
            let ext = (file as NSString).pathExtension.lowercased()
            if ext == "tf" { return terraform(text) }
            guard SystemMap.has(text, "Resources") || SystemMap.has(text, "resources") else { return nil }
            if SystemMap.has(text, "AWSTemplateFormatVersion") || SystemMap.has(text, "AWS::") {
                return cloudFormation(text, json: ext == "json" || text.drop { $0.isWhitespace }.first == "{")
            }
            if SystemMap.has(text, "deploymentTemplate.json"), let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                return arm(root, text: text)
            }
            return nil
        }

        static func cloudFormation(_ text: String, json: Bool) -> Template? {
            let root: [String: Any]?
            if json {
                root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            } else {
                // Short-form functions (!Ref, !Sub…) aren't plain YAML; without the tag the
                // value is still there, and references are found by name below.
                let plain = text.replacingOccurrences(of: #"!(Ref|GetAtt|Sub|Join|Select|Split|If|Equals|Not|And|Or|FindInMap|Base64|Cidr|ImportValue|GetAZs|Condition|Transform)\b"#, with: "", options: .regularExpression)
                root = (try? Yams.load(yaml: plain)) as? [String: Any]
            }
            guard let root, let resources = root["Resources"] as? [String: Any] else { return nil }
            let names = Set(resources.keys)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            var entries: [Entry] = []
            for (name, value) in resources {
                guard let body = value as? [String: Any], let type = body["Type"] as? String else { continue }
                var refs = Set<String>()
                collect(body, names: names, into: &refs)
                if let depends = body["DependsOn"] { for item in (depends as? [Any]) ?? [depends] { if let s = item as? String, names.contains(s) { refs.insert(s) } } }
                refs.remove(name)
                let line = lines.firstIndex { $0.contains("\"\(name)\"") || $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + ":") }.map { $0 + 1 }
                entries.append(Entry(name: name, type: type, line: line, references: refs))
            }
            entries.sort { $0.name < $1.name }
            let sam = (root["Transform"] as? String)?.contains("Serverless") == true
            return Template(tool: sam ? "SAM" : "CloudFormation", resources: entries,
                            parameters: (root["Parameters"] as? [String: Any])?.count ?? 0, outputs: (root["Outputs"] as? [String: Any])?.count ?? 0)
        }

        /// References by name: `{"Ref": "X"}`, a GetAtt "X.Arn" or ["X", "Arn"], "${X}" in a Sub.
        static func collect(_ value: Any, names: Set<String>, into refs: inout Set<String>) {
            switch value {
            case let string as String:
                if names.contains(string) { refs.insert(string) }
                if let dot = string.firstIndex(of: "."), names.contains(String(string[..<dot])) { refs.insert(String(string[..<dot])) }
                if string.contains("${") {
                    for match in string.matches(of: /\$\{(\w+)/) where names.contains(String(match.1)) { refs.insert(String(match.1)) }
                }
            case let dictionary as [String: Any]:
                for (_, item) in dictionary { collect(item, names: names, into: &refs) }
            case let list as [Any]:
                for item in list { collect(item, names: names, into: &refs) }
            default:
                break
            }
        }

        static func terraform(_ text: String) -> Template? {
            let blocks = text.matches(of: /(?m)^resource\s+"(\w+)"\s+"([\w-]+)"/)
            guard !blocks.isEmpty else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let names = Set(blocks.map { "\($0.1).\($0.2)" })
            var entries: [Entry] = []
            for (index, block) in blocks.enumerated() {
                let end = index + 1 < blocks.count ? blocks[index + 1].range.lowerBound : text.endIndex
                let body = text[block.range.upperBound..<end]
                var refs = Set<String>()
                // Not \b: Swift's word boundaries are Unicode's, where "api.arn" is one word.
                for match in body.matches(of: /(?:^|[^\w.])([a-z][a-z0-9]*_[a-z0-9_]+)\.([A-Za-z0-9_-]+)/) where names.contains("\(match.1).\(match.2)") { refs.insert("\(match.1).\(match.2)") }
                let name = "\(block.1).\(block.2)"
                refs.remove(name)
                let line = text[..<block.range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                _ = lines
                entries.append(Entry(name: name, type: String(block.1), line: line, references: refs))
            }
            return Template(tool: "Terraform", resources: entries, parameters: text.matches(of: /(?m)^variable\s+"/).count, outputs: text.matches(of: /(?m)^output\s+"/).count)
        }

        static func arm(_ root: [String: Any], text: String) -> Template? {
            guard let resources = root["resources"] as? [[String: Any]] else { return nil }
            var entries: [Entry] = []
            for (index, resource) in resources.enumerated() {
                guard let type = resource["type"] as? String else { continue }
                let name = (resource["name"] as? String).map { $0.hasPrefix("[") ? type.split(separator: "/").last.map(String.init) ?? type : $0 } ?? "\(type) \(index)"
                let refs = Set(((resource["dependsOn"] as? [String]) ?? []).compactMap { $0.split(separator: "'").dropFirst().first.map(String.init) })
                entries.append(Entry(name: name, type: type, line: nil, references: refs))
            }
            return Template(tool: "ARM", resources: entries, parameters: (root["parameters"] as? [String: Any])?.count ?? 0, outputs: (root["outputs"] as? [String: Any])?.count ?? 0)
        }
    }
}

// MARK: Catalogue

extension Infrastructure {
    /// What a resource type is, for its box: a short name, its tier and an icon.
    enum Catalog {
        static let rules: [(keys: [String], service: String, tier: Tier, symbol: String)] = [
            (["route53recordset", "route53record", "dnsrecord", "dnszones", "managedzone"], "DNS record", .edge, "globe"),
            (["route53hostedzone", "route53zone"], "DNS zone", .edge, "globe"),
            (["cloudfront", "cdnprofile", "frontdoor"], "CDN distribution", .edge, "globe.americas"),
            (["listenerrule", "lblistenerrule"], "Listener rule", .edge, "arrow.triangle.branch"),
            (["targetgroup", "lbtargetgroup"], "Target group", .edge, "scope"),
            (["elasticloadbalancingv2listener", "lblistener", "albl"], "Listener", .edge, "ear"),
            (["loadbalancer", "elasticloadbalancing", "awslb", "awsalb", "applicationgateway"], "Load balancer", .edge, "arrow.left.arrow.right.square"),
            (["apigateway", "serverlessapi", "serverlesshttpapi", "apimanagement"], "API Gateway", .edge, "door.left.hand.open"),
            (["wafv2", "waf"], "Web firewall", .security, "shield.lefthalf.filled"),
            (["ecscluster"], "ECS cluster", .compute, "square.stack.3d.up"),
            (["ecsservice"], "ECS service", .compute, "shippingbox.circle"),
            (["taskdefinition"], "Task definition", .compute, "doc.text"),
            (["lambda", "serverlessfunction", "functionapp"], "Function", .compute, "function"),
            (["autoscalinggroup", "autoscaling"], "Auto Scaling group", .compute, "square.3.layers.3d"),
            (["ec2instance", "awsinstance", "virtualmachine", "computeinstance"], "Instance", .compute, "server.rack"),
            (["eks", "kubernetes", "containerservice", "aks"], "Kubernetes", .compute, "helm"),
            (["apprunner", "containerapps", "cloudrun"], "Container app", .compute, "shippingbox.circle"),
            (["microsoftwebsites", "appservice", "elasticbeanstalk"], "App Service", .compute, "app.badge"),
            (["stepfunctions", "statemachine", "sfn"], "Workflow", .messaging, "flowchart"),
            (["ecr", "containerregistry", "artifactregistry"], "Container registry", .registry, "archivebox"),
            (["rdsdbcluster", "rdsdbinstance", "dbinstance", "dbcluster", "rds", "aurora", "microsoftsql", "postgresql", "mysql", "sqldatabase"], "Database", .data, "cylinder.split.1x2"),
            (["dynamodb", "cosmosdb", "firestore"], "Table store", .data, "tablecells"),
            (["s3bucket", "awss3", "storageaccount", "storagebucket"], "Storage bucket", .data, "externaldrive"),
            (["elasticache", "redis", "memcache"], "Cache", .data, "bolt.horizontal"),
            (["opensearch", "elasticsearch"], "Search", .data, "magnifyingglass"),
            (["sqs", "servicebusqueue", "queue"], "Queue", .messaging, "tray.full"),
            (["sns", "topic"], "Topic", .messaging, "bell.badge"),
            (["eventbridge", "eventsrule", "eventbus", "cloudwatchevent"], "Event rule", .messaging, "dot.radiowaves.left.and.right"),
            (["kinesis", "eventhub", "msk", "kafka"], "Stream", .messaging, "water.waves"),
            (["securitygroupingress", "securitygroupegress", "securitygrouprule"], "Security group rule", .security, "lock.shield"),
            (["securitygroup", "networksecuritygroup", "firewall"], "Security group", .security, "lock.shield"),
            (["iamrole", "iampolicy", "iammanagedpolicy", "iaminstanceprofile", "roleassignment", "serviceaccount", "iam"], "IAM", .security, "person.badge.key"),
            (["kms", "keyvault"], "Encryption key", .security, "key"),
            (["secretsmanager", "secret", "ssmparameter"], "Secret", .security, "lock.rectangle"),
            (["certificatemanager", "acm", "certificate"], "Certificate", .security, "checkmark.seal"),
            (["cognito", "identitypool", "userpool"], "Sign-in", .security, "person.2.badge.key"),
            (["vpc", "virtualnetwork", "subnet", "natgateway", "internetgateway", "routetable", "vpcendpoint", "networkinterface"], "Network", .network, "network"),
            (["loggroup", "logs", "loganalytics", "applicationinsights", "cloudwatchlog"], "Log group", .observability, "text.magnifyingglass"),
            (["alarm", "metricalert", "dashboard", "cloudwatch"], "Alarm", .observability, "bell"),
        ]

        static func describe(_ type: String) -> (service: String, tier: Tier, symbol: String) {
            let key = type.lowercased().filter { $0.isLetter || $0.isNumber }
            for rule in rules where rule.keys.contains(where: { key.contains($0) }) {
                return (rule.service, rule.tier, rule.symbol)
            }
            let last = type.split(whereSeparator: { ":/_".contains($0) }).last.map(String.init) ?? type
            return (last, .other, "cube")
        }
    }
}

// MARK: Pipelines

extension Infrastructure {
    enum PipelineReader {
        static func read(file: String, text: String) -> Pipeline? {
            let lower = file.lowercased()
            let name = (lower as NSString).lastPathComponent
            guard ["yml", "yaml"].contains((lower as NSString).pathExtension) else { return nil }
            let isGitHub = lower.hasPrefix(".github/workflows/")
            let isGitLab = name == ".gitlab-ci.yml"
            let looksLikeADO = name.hasPrefix("azure-pipelines") || lower.contains("azure-devops/") || lower.contains("/pipelines/")
                || (SystemMap.has(text, "stages:") && (SystemMap.has(text, "- task:") || SystemMap.has(text, "vmImage") || SystemMap.has(text, "- stage:")))
            guard isGitHub || isGitLab || looksLikeADO else { return nil }
            // ADO template expressions (${{ if … }}:) aren't keys Yams can read as they stand.
            let plain = text.replacingOccurrences(of: #"\$\{\{[^}]*\}\}"#, with: "expr", options: .regularExpression)
            guard let root = (try? Yams.load(yaml: plain)) as? [String: Any] else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            if isGitHub { return github(root, file: file, stem: stem, lines: lines) }
            if isGitLab { return gitlab(root, file: file, lines: lines) }
            return azure(root, file: file, stem: stem, lines: lines)
        }

        static func line(of needle: String, in lines: [String], after start: Int = 0) -> Int? {
            guard !needle.isEmpty, start < lines.count else { return nil }
            return lines[start...].firstIndex { $0.contains(needle) }.map { $0 + 1 }
        }

        static func strings(_ value: Any?) -> [String] {
            if let string = value as? String { return [string] }
            if value is [Any] { return flattened(value).compactMap { $0 as? String } }
            return []
        }

        /// A list's items with Azure template conditions (`- ${{ if … }}:`, `${{ else }}`, `${{ each … }}`,
        /// read as `expr:` since `pipeline` swaps the expressions out) opened up: the items under
        /// them count, as they do with the parameters' defaults.
        static func flattened(_ value: Any?) -> [Any] {
            guard let list = value as? [Any] else { return [] }
            return list.flatMap { item -> [Any] in
                if let object = item as? [String: Any], object.count == 1, let key = object.keys.first,
                   key == "expr" || key.hasPrefix("${{"), let inner = object[key] as? [Any] {
                    return flattened(inner)
                }
                return [item]
            }
        }

        static func objects(_ value: Any?) -> [[String: Any]] { flattened(value).compactMap { $0 as? [String: Any] } }

        static func branches(_ trigger: Any?) -> [String] {
            if let list = trigger as? [Any] { return list.compactMap { $0 as? String } }
            if let object = trigger as? [String: Any] {
                if let include = (object["branches"] as? [String: Any])?["include"] { return strings(include) }
                return strings(object["branches"])
            }
            if let string = trigger as? String { return string == "none" ? [] : [string] }
            return []
        }

        static func azure(_ root: [String: Any], file: String, stem: String, lines: [String]) -> Pipeline? {
            var stages: [Stage] = []
            func job(_ body: [String: Any]) -> (name: String, environment: String?, steps: [[String: Any]]) {
                let name = (body["displayName"] as? String) ?? (body["job"] as? String) ?? (body["deployment"] as? String) ?? "job"
                var environment = body["environment"] as? String ?? (body["environment"] as? [String: Any])?["name"] as? String
                if environment?.hasPrefix("$(") == true { environment = nil }
                var steps = objects(body["steps"])
                if let strategy = body["strategy"] as? [String: Any] {
                    for (_, value) in strategy {
                        for (_, phase) in (value as? [String: Any]) ?? [:] { steps += objects((phase as? [String: Any])?["steps"]) }
                    }
                }
                return (name, environment, steps)
            }
            func stage(id: String, name: String, dependsOn: [String], jobs: [[String: Any]], line: Int?) -> Stage {
                var steps: [Step] = []
                var names: [String] = []
                var environment: String?
                for body in jobs {
                    let found = job(body)
                    names.append(found.name)
                    environment = environment ?? found.environment
                    steps += found.steps.compactMap { step(azure: $0, lines: lines, after: (line ?? 1) - 1) }
                }
                return Stage(id: id, name: name, jobs: names, dependsOn: dependsOn, environment: environment, steps: steps, line: line)
            }
            if root["stages"] is [Any] {
                var previous: String?
                for body in objects(root["stages"]) {
                    guard let id = body["stage"] as? String else { continue }
                    // No dependsOn means the stage before it; an empty one means none.
                    let depends = body.keys.contains("dependsOn") ? strings(body["dependsOn"]) : previous.map { [$0] } ?? []
                    stages.append(stage(id: id, name: (body["displayName"] as? String) ?? words(id), dependsOn: depends,
                                        jobs: objects(body["jobs"]), line: line(of: "stage: \(id)", in: lines)))
                    previous = id
                }
            } else if root["jobs"] is [Any] {
                stages = [stage(id: "jobs", name: "Jobs", dependsOn: [], jobs: objects(root["jobs"]), line: line(of: "jobs:", in: lines))]
            } else if root["steps"] is [Any] {
                stages = [stage(id: "steps", name: "Steps", dependsOn: [], jobs: [["steps": root["steps"] as Any]], line: line(of: "steps:", in: lines))]
            }
            guard !stages.isEmpty || root["extends"] != nil else { return nil }
            return Pipeline(id: file, name: stem, system: "Azure DevOps", file: file, branches: branches(root["trigger"]), stages: stages,
                            environment: Infrastructure.environment(in: file) ?? stages.compactMap(\.environment).first)
        }

        static func step(azure body: [String: Any], lines: [String], after: Int) -> Step? {
            if body["checkout"] != nil { return nil }
            let display = body["displayName"] as? String
            if let task = body["task"] as? String {
                let inputs = (body["inputs"] as? [String: Any]) ?? [:]
                let script = [inputs["inlineScript"], inputs["script"], inputs["scriptPath"], inputs["command"], inputs["arguments"], inputs["templatePath"], inputs["templateFile"]]
                    .compactMap { $0 as? String }.joined(separator: "\n")
                return classify(title: display, command: task + "\n" + script, line: line(of: task, in: lines, after: after))
            }
            for key in ["script", "bash", "pwsh", "powershell"] {
                if let script = body[key] as? String {
                    return classify(title: display, command: script, line: line(of: display ?? firstLine(script), in: lines, after: after))
                }
            }
            if let template = body["template"] as? String { return Step(kind: .script, title: display ?? "Template \(template)", detail: template, line: line(of: template, in: lines)) }
            return nil
        }

        static func github(_ root: [String: Any], file: String, stem: String, lines: [String]) -> Pipeline? {
            guard let jobs = root["jobs"] as? [String: Any] else { return nil }
            let on = root["on"] ?? root["true"]
            var branchList = branches((on as? [String: Any])?["push"])
            if branchList.isEmpty, let push = (on as? [String: Any])?["push"] as? [String: Any] { branchList = strings(push["branches"]) }
            var stages: [Stage] = []
            for (id, value) in jobs {
                guard let body = value as? [String: Any] else { continue }
                let steps = (body["steps"] as? [[String: Any]] ?? []).compactMap { step -> Step? in
                    let uses = step["uses"] as? String ?? ""
                    if uses.hasPrefix("actions/checkout") || uses.hasPrefix("actions/setup-") || uses.hasPrefix("actions/cache") { return nil }
                    let command = uses + "\n" + (step["run"] as? String ?? "") + "\n" + ((step["with"] as? [String: Any]).map { $0.values.compactMap { $0 as? String }.joined(separator: " ") } ?? "")
                    return classify(title: step["name"] as? String, command: command, line: line(of: (step["name"] as? String) ?? uses, in: lines))
                }
                let environment = body["environment"] as? String ?? (body["environment"] as? [String: Any])?["name"] as? String
                stages.append(Stage(id: id, name: (body["name"] as? String) ?? words(id), jobs: [id], dependsOn: strings(body["needs"]),
                                    environment: environment, steps: steps, line: line(of: "\(id):", in: lines)))
            }
            return Pipeline(id: file, name: (root["name"] as? String) ?? stem, system: "GitHub Actions", file: file, branches: branchList,
                            stages: ordered(stages), environment: Infrastructure.environment(in: file) ?? stages.compactMap(\.environment).first)
        }

        static func gitlab(_ root: [String: Any], file: String, lines: [String]) -> Pipeline? {
            let order = strings(root["stages"])
            var byStage: [String: [(String, [String: Any])]] = [:]
            for (key, value) in root where !key.hasPrefix(".") {
                guard let body = value as? [String: Any], body["script"] != nil else { continue }
                byStage[(body["stage"] as? String) ?? "test", default: []].append((key, body))
            }
            let names = order.isEmpty ? byStage.keys.sorted() : order
            var stages: [Stage] = []
            for (index, name) in names.enumerated() {
                let jobs = (byStage[name] ?? []).sorted { $0.0 < $1.0 }
                guard !jobs.isEmpty else { continue }
                let steps = jobs.compactMap { job, body in classify(title: job, command: strings(body["script"]).joined(separator: "\n"), line: line(of: "\(job):", in: lines)) }
                let environment = jobs.compactMap { ($0.1["environment"] as? String) ?? ($0.1["environment"] as? [String: Any])?["name"] as? String }.first
                stages.append(Stage(id: name, name: words(name), jobs: jobs.map(\.0), dependsOn: index > 0 ? [names[index - 1]] : [], environment: environment, steps: steps, line: line(of: "\(name)", in: lines)))
            }
            guard !stages.isEmpty else { return nil }
            return Pipeline(id: file, name: "GitLab CI", system: "GitLab CI", file: file, branches: [], stages: stages, environment: stages.compactMap(\.environment).first)
        }

        /// By `needs`: each stage after the ones it waits for.
        static func ordered(_ stages: [Stage]) -> [Stage] {
            var done: [Stage] = []
            var left = stages.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
            while !left.isEmpty {
                let ready = left.firstIndex { stage in stage.dependsOn.allSatisfy { need in done.contains { $0.id == need } } } ?? 0
                done.append(left.remove(at: ready))
            }
            return done
        }

        static func firstLine(_ text: String) -> String {
            text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !$0.contains("set -") }
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }

        /// What a step does, from its task or command.
        static func classify(title: String?, command: String, line: Int?) -> Step {
            let text = command.lowercased()
            let has = { (words: [String]) in words.contains { text.contains($0) } }
            let kind: StepKind
            let fallback: String
            if has(["flyway", "liquibase", "migrate", "alembic upgrade", "prisma migrate", "dbmate"]) {
                (kind, fallback) = (.migrate, "Migrate the database")
            } else if has(["cloudformation deploy", "create-stack", "update-stack", "cloudformationcreateorupdatestack", "sam deploy", "cdk deploy", "terraform apply", "terraformtask", "az deployment", "azureresourcemanager", "bicep"]) {
                (kind, fallback) = (.stack, "Deploy the infrastructure")
            } else if has(["update-service", "force-new-deployment", "ecs deploy", "ecsdeploy", "amazon-ecs-deploy", "kubectl apply", "kubectl set image", "helm upgrade", "helm install", "azurewebapp", "az webapp", "update-function-code", "s3 sync", "aws s3 cp", "gcloud run deploy", "firebase deploy", "vercel", "netlify deploy"]) {
                (kind, fallback) = (.deploy, "Deploy")
            } else if has(["docker push", "ecr get-login", "push-image", "docker/build-push-action", "buildah push", "command: push", "pushimage"]) {
                (kind, fallback) = (has(["docker build", "build-push-action", "buildah bud"]) ? .push : .push, has(["docker build", "build-push-action"]) ? "Build and push the image" : "Push the image")
            } else if has(["docker build", "docker@", "buildah bud", "kaniko", "docker buildx", "jib"]) {
                (kind, fallback) = (.image, "Build the container image")
            } else if has(["manualvalidation", "approval", "waitforvalidation"]) {
                (kind, fallback) = (.approval, "Wait for approval")
            } else if has(["sonar", "snyk", "trivy", "gitleaks", "semgrep", "dependency-check", "codeql", "npm audit"]) {
                (kind, fallback) = (.scan, "Scan")
            } else if has(["npm test", "yarn test", "pnpm test", "mvn test", "mvn verify", "gradle test", "go test", "pytest", "dotnet test", "jest", "vitest", "cargo test"]) {
                (kind, fallback) = (.test, "Run the tests")
            } else if has(["mvn", "gradle", "npm run build", "npm ci", "yarn build", "pnpm build", "go build", "dotnet build", "dotnet publish", "cargo build", "maven@"]) {
                (kind, fallback) = (.build, "Build")
            } else {
                (kind, fallback) = (.script, "Run a script")
            }
            // The script's first real line, not the task's name ("AWSShellScript@1").
            let meaningful = command.split(separator: "\n").filter { $0.range(of: #"^[\w.-]+@\d+$"#, options: .regularExpression) == nil }
            let detail = firstLine(meaningful.joined(separator: "\n"))
            return Step(kind: kind, title: title ?? fallback, detail: String((detail.isEmpty ? firstLine(command) : detail).prefix(160)), line: line,
                        command: String(command.prefix(2000)))
        }

        /// "PackageNonProd" → "Package non prod".
        static func words(_ id: String) -> String {
            var result = ""
            var previous: Character?
            for character in id {
                if character == "_" || character == "-" { result += " "; previous = " "; continue }
                if character.isUppercase, let previous, previous.isLowercase || previous.isNumber { result += " " }
                result.append(character)
                previous = character
            }
            let lower = result.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
    }
}
