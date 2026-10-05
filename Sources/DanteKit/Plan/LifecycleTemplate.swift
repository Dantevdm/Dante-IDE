import Foundation

/// A starting lifecycle for a kind of project: its phases and what each one's checklist
/// starts with. `lifecycle.template` in project.yaml names one (`app@1`, `infra@1`…).
public struct LifecycleTemplate: Identifiable, Equatable, Sendable {
    public struct Phase: Equatable, Sendable {
        public var name: String
        public var summary: String
        public var ready: [String]
        public var done: [String]
    }

    public var id: String
    public var name: String
    public var summary: String
    public var phases: [Phase]

    public var phaseNames: [String] { phases.map(\.name) }

    public func phase(_ name: String) -> Phase? {
        phases.first { $0.name.lowercased() == name.lowercased() }
    }

    /// `app`, `app@1` and `APP` all name the app template.
    public static func named(_ value: String) -> LifecycleTemplate? {
        let id = value.split(separator: "@").first.map { $0.lowercased() } ?? ""
        return all.first { $0.id == id }
    }

    public static let all: [LifecycleTemplate] = [app, infra, apple, data]

    public static let app = LifecycleTemplate(id: "app", name: "Web or backend app", summary: "Services, APIs and web front ends.", phases: [
        Phase(name: "Discover", summary: "Understand the problem, the people who have it and what already exists.",
              ready: ["A problem worth solving"], done: ["Problem statement written", "Users and constraints listed"]),
        Phase(name: "Define", summary: "Decide what to build and what “done” means for it.",
              ready: ["Discovery notes written"], done: ["Scope agreed", "Acceptance criteria for each feature", "Tasks drafted for Build"]),
        Phase(name: "Design", summary: "Shape the solution: architecture, data, flows and the decisions behind them.",
              ready: ["Requirements agreed"], done: ["Architecture sketched", "Key decisions recorded", "Risky parts prototyped"]),
        Phase(name: "Build", summary: "Turn the agreed design into working, reviewed code.",
              ready: ["Design phase done", "Local environment boots"], done: ["Features implemented", "Code reviewed", "All Build tasks done"]),
        Phase(name: "Test", summary: "Prove it works: automated tests, edge cases and real usage.",
              ready: ["Features complete"], done: ["Tests pass in CI", "Coverage targets met", "Known bugs triaged"]),
        Phase(name: "Release", summary: "Ship it: version, changelog, and a release you can roll back.",
              ready: ["Tests green"], done: ["Changelog written", "Release tagged", "Rollback plan noted"]),
        Phase(name: "Operate", summary: "Run it: watch health, respond to issues and feed lessons back into the plan.",
              ready: ["Released"], done: ["Monitoring in place", "Runbooks for likely incidents"]),
    ])

    public static let infra = LifecycleTemplate(id: "infra", name: "Infrastructure and cloud", summary: "CloudFormation, CDK, Terraform, IAM and the accounts they run in.", phases: [
        Phase(name: "Discover", summary: "What the infrastructure must support, and what already runs where.",
              ready: ["A need for new or changed infrastructure"], done: ["Workloads and their needs listed", "Existing accounts, stacks and owners mapped"]),
        Phase(name: "Design", summary: "Accounts, networks, identities and the decisions behind them.",
              ready: ["Needs agreed"], done: ["Accounts, regions and environments decided", "Network layout sketched", "IAM boundaries and least-privilege roles sketched", "Key decisions recorded"]),
        Phase(name: "Build", summary: "Write the templates and stacks.",
              ready: ["Design agreed"], done: ["Stacks or modules written", "Parameters per environment", "Secrets in a secret store, not in templates"]),
        Phase(name: "Validate", summary: "Check the change before it touches an account.",
              ready: ["Templates written"], done: ["Templates lint clean (cfn-lint, cdk synth or terraform validate)", "Change set or plan reviewed", "IAM policies checked for wildcards", "Cost of the change estimated"]),
        Phase(name: "Release", summary: "Roll the change out, environment by environment.",
              ready: ["Validation passed"], done: ["Applied in a non-production account first", "Applied in production", "Rollback plan noted"]),
        Phase(name: "Operate", summary: "Keep it healthy and affordable.",
              ready: ["Released"], done: ["Alarms on key metrics", "Budget and cost alerts set", "Runbooks for likely incidents"]),
    ])

    public static let apple = LifecycleTemplate(id: "apple", name: "Swift and Apple platforms", summary: "iOS, macOS and other apps and packages for Apple platforms.", phases: [
        Phase(name: "Discover", summary: "Understand the problem, the people who have it and what already exists.",
              ready: ["A problem worth solving"], done: ["Problem statement written", "Users and devices listed"]),
        Phase(name: "Define", summary: "Decide what to build and what “done” means for it.",
              ready: ["Discovery notes written"], done: ["Scope agreed", "Minimum OS versions chosen", "Tasks drafted for Build"]),
        Phase(name: "Design", summary: "Screens, flows, data and the architecture behind them.",
              ready: ["Requirements agreed"], done: ["Key screens designed", "Data model sketched", "Key decisions recorded"]),
        Phase(name: "Build", summary: "Turn the design into working, reviewed code.",
              ready: ["Design phase done", "Project builds"], done: ["Features implemented", "Accessibility labels in place", "All Build tasks done"]),
        Phase(name: "Test", summary: "Prove it works on real devices.",
              ready: ["Features complete"], done: ["Unit and UI tests pass", "Tried on the oldest supported OS", "Known bugs triaged"]),
        Phase(name: "Beta", summary: "Get builds to testers.",
              ready: ["Tests green", "Signing and archives work"], done: ["TestFlight build uploaded", "Tester feedback triaged"]),
        Phase(name: "Release", summary: "Through review and into the store.",
              ready: ["Beta feedback addressed"], done: ["Store listing and screenshots ready", "Submitted for review", "Release tagged"]),
        Phase(name: "Operate", summary: "Watch crashes and reviews, and feed them back into the plan.",
              ready: ["Released"], done: ["Crash reports watched", "Reviews answered"]),
    ])

    public static let data = LifecycleTemplate(id: "data", name: "Data and scripts", summary: "Pipelines, notebooks, analyses and automation scripts.", phases: [
        Phase(name: "Explore", summary: "Find the data and learn its shape.",
              ready: ["A question or a job to automate"], done: ["Sources listed with owners and access", "Sample data profiled"]),
        Phase(name: "Define", summary: "Agree the outputs and how good they must be.",
              ready: ["Sources understood"], done: ["Outputs and their consumers agreed", "Freshness and quality targets set"]),
        Phase(name: "Build", summary: "Write the pipeline, notebook or script.",
              ready: ["Outputs agreed"], done: ["Runs end to end locally", "Config and credentials kept out of the code"]),
        Phase(name: "Validate", summary: "Check the results before anyone relies on them.",
              ready: ["Runs end to end"], done: ["Row counts and checks pass", "Results compared with a known sample"]),
        Phase(name: "Schedule", summary: "Make it run without you.",
              ready: ["Results validated"], done: ["Runs on a schedule or trigger", "Reruns are safe"]),
        Phase(name: "Monitor", summary: "Know when it breaks or drifts.",
              ready: ["Scheduled"], done: ["Failures alert someone", "Quality checks run on every load"]),
    ])

    // MARK: Detection

    /// The template that best fits a project, from its file paths. `read` returns a
    /// file's contents for the few signals that need them.
    public static func suggest(for paths: [String], read: (String) -> String? = { _ in nil }) -> LifecycleTemplate {
        var scores: [String: Int] = [:]
        for path in paths {
            let lower = path.lowercased()
            let name = (lower as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension
            if lower.contains(".xcodeproj/") || lower.contains(".xcworkspace/") || name == "info.plist" || ext == "entitlements" { scores["apple", default: 0] += 5 }
            if ext == "swift" { scores["apple", default: 0] += 1 }
            if ext == "tf" || name == "cdk.json" || name == "samconfig.toml" || name == "serverless.yml" || name == "pulumi.yaml" { scores["infra", default: 0] += 5 }
            if lower.hasPrefix("cloudformation/") || lower.hasPrefix("cfn/") || lower.hasPrefix("terraform/") || lower.hasPrefix("iac/") { scores["infra", default: 0] += 3 }
            if ["template.yaml", "template.yml", "template.json"].contains(name), read(path)?.contains("AWSTemplateFormatVersion") == true { scores["infra", default: 0] += 5 }
            if ext == "ipynb" || name == "dbt_project.yml" { scores["data", default: 0] += 5 }
            if lower.hasPrefix("dags/") || lower.hasPrefix("notebooks/") || lower.hasPrefix("pipelines/") { scores["data", default: 0] += 3 }
            if ["ts", "tsx", "js", "jsx", "go", "rb", "php", "java", "kt", "rs", "cs"].contains(ext) { scores["app", default: 0] += 1 }
            if name == "dockerfile" || name == "docker-compose.yml" || name == "compose.yaml" || name == "package.json" { scores["app", default: 0] += 3 }
            if ext == "py" { scores["app", default: 0] += 1; scores["data", default: 0] += 1 }
        }
        // Swift alone could be a server; it takes Apple project files to tip it.
        if (scores["apple"] ?? 0) > 0, !paths.contains(where: { $0.lowercased().hasSuffix(".swift") || $0.lowercased().contains(".xcodeproj/") }) { scores["apple"] = 0 }
        let best = scores.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }
        return best.flatMap { named($0.key) } ?? app
    }

    // MARK: Files

    public func phaseDoc(_ phase: String) -> String {
        let found = self.phase(phase)
        let summary = found?.summary ?? "What this phase is for."
        let ready = found?.ready ?? ["Previous phase done"]
        let done = found?.done ?? ["Agreed with yourself that it's done"]
        return """
        # \(found?.name ?? phase.capitalized)

        \(summary)

        ## Ready when
        \(ready.map { "- [ ] \($0)" }.joined(separator: "\n"))

        ## Done when
        \(done.map { "- [ ] \($0)" }.joined(separator: "\n"))

        """
    }

    public func projectYAML(name: String, summary: String?, current: String) -> String {
        var lines = ["name: \(Self.yamlString(name))"]
        if let summary, !summary.isEmpty { lines.append("summary: \(Self.yamlString(summary))") }
        lines += ["", "lifecycle:", "  template: \(id)@1", "  current: \(current.lowercased())", ""]
        return lines.joined(separator: "\n")
    }

    static func yamlString(_ value: String) -> String {
        let plain = value.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._()/-]*$"#, options: .regularExpression) != nil
        return plain ? value : "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
