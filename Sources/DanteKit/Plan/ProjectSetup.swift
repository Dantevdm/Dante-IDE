import Foundation

/// What Dante can tell about a project before it has a `.dante/` folder, without asking
/// Claude: the stack, the lifecycle that fits, roughly where it is in it, and what to keep
/// Claude away from. The setup sheet shows this and Claude fills in the rest.
public struct ProjectProfile: Equatable, Sendable {
    /// Roughly how far along a project is, independent of any template's phase names.
    public enum Stage: Int, Comparable, Sendable {
        case starting, building, verifying, releasing, operating

        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    public var stack: [String]
    public var template: LifecycleTemplate
    public var stage: Stage
    /// Why Dante thinks the project is at that stage, for the sheet.
    public var stageReason: String
    public var summary: String?
    public var testCommand: String?
    public var sourceFiles: Int
    public var testFiles: Int
    public var commits: Int
    public var tags: Int
    public var hasCI: Bool
    public var hasDeployConfig: Bool
    /// Paths that look like secrets, offered as `never` rules for Claude.
    public var sensitivePaths: [String]

    /// The template phase that matches the stage.
    public var phase: String { Self.phase(for: stage, in: template) }

    static let sourceExtensions: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "rb", "java", "kt", "cs", "php", "c", "cc", "cpp", "h", "m", "scala", "ex", "exs", "tf", "sql", "ipynb", "vue", "svelte", "dart"]

    public static func detect(paths: [String], commits: Int = 0, tags: Int = 0, testCommand: String? = nil,
                              summary: String? = nil, read: (String) -> String? = { _ in nil }) -> ProjectProfile {
        let lower = paths.map { $0.lowercased() }
        let names = Set(lower.map { ($0 as NSString).lastPathComponent })
        func has(_ name: String) -> Bool { names.contains(name) }
        func under(_ prefix: String) -> Bool { lower.contains { $0.hasPrefix(prefix) } }

        var stack: [String] = []
        let markers: [(Bool, String)] = [
            (has("package.swift"), "Swift package"),
            (lower.contains { $0.contains(".xcodeproj/") }, "Xcode project"),
            (has("package.json"), lower.contains { $0.hasSuffix(".ts") || $0.hasSuffix(".tsx") } ? "TypeScript" : "Node.js"),
            (has("go.mod"), "Go"),
            (has("cargo.toml"), "Rust"),
            (has("pyproject.toml") || has("requirements.txt") || has("setup.py"), "Python"),
            (has("gemfile"), "Ruby"),
            (has("pom.xml") || has("build.gradle") || has("build.gradle.kts"), "JVM"),
            (lower.contains { $0.hasSuffix(".csproj") || $0.hasSuffix(".sln") }, ".NET"),
            (has("dockerfile"), "Docker"),
            (has("docker-compose.yml") || has("docker-compose.yaml") || has("compose.yaml") || has("compose.yml"), "Docker Compose"),
            (lower.contains { $0.hasSuffix(".tf") }, "Terraform"),
            (has("cdk.json"), "AWS CDK"),
            (has("serverless.yml") || has("samconfig.toml"), "Serverless"),
            (lower.contains { $0.hasSuffix(".ipynb") }, "Notebooks"),
            (has("dbt_project.yml"), "dbt"),
            (under(".github/workflows/"), "GitHub Actions"),
            (has(".gitlab-ci.yml"), "GitLab CI"),
            (under("k8s/") || under("kubernetes/") || has("chart.yaml") || has("kustomization.yaml"), "Kubernetes"),
            (has("fly.toml") || has("vercel.json") || has("netlify.toml") || has("render.yaml") || has("app.yaml") || has("procfile"), "Hosted deploy"),
        ]
        for (present, label) in markers where present && !stack.contains(label) { stack.append(label) }

        let sources = lower.filter { sourceExtensions.contains(($0 as NSString).pathExtension) }
        let tests = sources.filter { path in
            let name = (path as NSString).lastPathComponent
            return path.hasPrefix("tests/") || path.hasPrefix("test/") || path.contains("/tests/") || path.contains("/test/") || path.contains("__tests__/")
                || name.contains("test.") || name.contains("tests.") || name.contains(".spec.") || name.hasPrefix("test_")
        }
        let hasCI = under(".github/workflows/") || has(".gitlab-ci.yml") || has("jenkinsfile") || under(".circleci/") || has("bitrise.yml")
        let hasDeploy = stack.contains { ["Kubernetes", "Hosted deploy", "Terraform", "AWS CDK", "Serverless"].contains($0) }
            || under("deploy/") || has("fastfile") || has("appfile")

        let stage: Stage, reason: String
        if sources.isEmpty {
            (stage, reason) = (.starting, "No source code yet")
        } else if tags > 0, hasDeploy {
            (stage, reason) = (.operating, "\(tags) tagged release\(tags == 1 ? "" : "s") and deploy config")
        } else if tags > 0 {
            (stage, reason) = (.releasing, "\(tags) tagged release\(tags == 1 ? "" : "s"), no deploy config found")
        } else if sources.count < 5, commits < 10 {
            (stage, reason) = (.starting, "Only \(sources.count) source file\(sources.count == 1 ? "" : "s") so far")
        } else {
            (stage, reason) = (.building, "\(sources.count) source files\(tests.isEmpty ? " and no tests" : ", \(tests.count) of them tests"), no releases tagged yet")
        }

        let secretNames: Set<String> = ["id_rsa", "id_ed25519", "credentials", "credentials.json", "secrets.yaml", "secrets.yml", "secrets.json", "serviceaccount.json"]
        var sensitive: [String] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent.lowercased()
            let ext = (name as NSString).pathExtension
            let pattern: String?
            if name.hasPrefix(".env"), name != ".env.example", name != ".env.sample", name != ".env.template" { pattern = ".env*" }
            else if ["pem", "key", "p12", "pfx", "keystore", "jks", "mobileprovision"].contains(ext) { pattern = "*.\(ext)" }
            else if secretNames.contains(name) { pattern = path }
            else if let top = path.split(separator: "/").first, ["secrets", ".secrets"].contains(top.lowercased()), path.contains("/") { pattern = "\(top)/" }
            else { pattern = nil }
            if let pattern, !sensitive.contains(pattern) { sensitive.append(pattern) }
        }

        return ProjectProfile(
            stack: stack, template: LifecycleTemplate.suggest(for: paths, read: read), stage: stage, stageReason: reason,
            summary: summary, testCommand: testCommand, sourceFiles: sources.count, testFiles: tests.count,
            commits: commits, tags: tags, hasCI: hasCI, hasDeployConfig: hasDeploy, sensitivePaths: sensitive
        )
    }

    /// Each stage's phase by name in the template, falling back to its position.
    public static func phase(for stage: Stage, in template: LifecycleTemplate) -> String {
        let names = template.phaseNames
        let wanted: [String] = switch stage {
        case .starting: [names.first ?? "Discover"]
        case .building: ["Build"]
        case .verifying: ["Test", "Validate"]
        case .releasing: ["Release", "Beta", "Schedule"]
        case .operating: ["Operate", "Monitor"]
        }
        if let match = names.first(where: { wanted.contains($0) }) { return match }
        let index = min(names.count - 1, Int((Double(stage.rawValue) / 4 * Double(names.count - 1)).rounded()))
        return names.isEmpty ? "Discover" : names[max(0, index)]
    }
}

/// What the user asked Claude to fill in when setting a project up.
public struct ProjectSetupRequest: Equatable, Sendable {
    public enum Part: String, CaseIterable, Sendable, Identifiable {
        case summary, phases, tasks, tests, rules, architecture, operate
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .summary: "Project summary and goals"
            case .phases: "Phase checklists for this codebase"
            case .tasks: "Tasks from the open work"
            case .tests: "How to run the tests"
            case .rules: "Keep Claude away from secrets"
            case .architecture: "Architecture notes"
            case .operate: "Health checks and production logs"
            }
        }

        public var detail: String {
            switch self {
            case .summary: "name, summary and goals in project.yaml, from the README and code"
            case .phases: "“Ready when” and “Done when” for each phase, ticked where the repo already shows it"
            case .tasks: "from TODOs, FIXMEs, the README’s roadmap and open GitHub issues"
            case .tests: "test.command in project.yaml"
            case .rules: "never rules in project.yaml, so Claude can’t read or edit them"
            case .architecture: ".dante/architecture.md: the parts, how they talk, and the key decisions"
            case .operate: "operate.checks and operate.logs, for the Run area"
            }
        }
    }

    public var template: LifecycleTemplate
    public var phase: String
    public var parts: Set<Part>

    public init(template: LifecycleTemplate, phase: String, parts: Set<Part>) {
        self.template = template
        self.phase = phase
        self.parts = parts
    }

    /// The parts ticked by default for a profile.
    public static func defaultParts(for profile: ProjectProfile) -> Set<Part> {
        var parts: Set<Part> = [.summary, .phases, .tasks]
        if profile.testCommand == nil, profile.testFiles > 0 { parts.insert(.tests) }
        if !profile.sensitivePaths.isEmpty { parts.insert(.rules) }
        if profile.sourceFiles >= 20 { parts.insert(.architecture) }
        if profile.hasDeployConfig, profile.stage >= .releasing { parts.insert(.operate) }
        return parts
    }

    /// The short line shown in the transcript; `prompt` carries the detail.
    public var summary: String {
        let names = Part.allCases.filter(parts.contains).map { $0.title.prefix(1).lowercased() + $0.title.dropFirst() }
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? ""
        return "Set this project up for Dante (\(template.name.lowercased()), at \(phase)): \(list)."
    }

    /// The message to Claude. Dante has already written the skeleton files, so Claude edits them.
    public func prompt(profile: ProjectProfile) -> String {
        var lines = [
            "Dante has just created .dante/ for this project with the \(template.name.lowercased()) lifecycle (\(template.phaseNames.joined(separator: " → "))), currently at \(phase). Fill it in from what's really in the repo. Read the README, docs, build files, code and git history first.",
            "",
            "What Dante detected: \(profile.stack.isEmpty ? "no known build files" : profile.stack.joined(separator: ", ")); \(profile.sourceFiles) source files, \(profile.testFiles) tests; \(profile.commits) commits, \(profile.tags) tags\(profile.testCommand.map { "; tests run with `\($0)`" } ?? "").",
            "",
            "Please:",
        ]
        let ordered = Part.allCases.filter(parts.contains)
        for part in ordered {
            let line: String = switch part {
            case .summary: "In .dante/project.yaml, set name and a two-sentence summary, and add a short goals list. Keep lifecycle as it is unless the repo clearly shows another phase; if so, say why."
            case .phases: "Rewrite each .dante/phases/<phase>.md so its “Ready when” and “Done when” checklists are specific to this codebase. Tick items the repo already shows are done."
            case .tasks: "Add the open work to .dante/tasks.yaml: TODO and FIXME comments worth tracking, roadmap items in the README or docs, and open GitHub issues if `gh` works here. Give each a phase; mark what's being worked on now as in_progress. No more than about 25."
            case .tests: "Add test.command to .dante/project.yaml with the command that runs this project's tests."
            case .rules: "Add a claude: block to .dante/project.yaml with never: rules for \(profile.sensitivePaths.isEmpty ? "any secrets you find" : profile.sensitivePaths.joined(separator: ", ")), plus anything else that looks like secrets. Don't open those files."
            case .architecture: "Write .dante/architecture.md: the main parts, how they talk to each other (a ```mermaid flowchart), where data lives, and the key decisions you can infer."
            case .operate: "Add an operate: block to .dante/project.yaml with health check URLs and a command that streams production logs, from the deploy config. Ask me for anything you can't find."
            }
            lines.append("- \(line)")
        }
        lines += ["", "Propose the edits for me to review. Afterwards, give me a short summary of the project and what you'd do next."]
        return lines.joined(separator: "\n")
    }
}
