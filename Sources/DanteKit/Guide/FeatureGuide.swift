import Foundation

/// A page or view in Dante, described for voice and the agents: what it is, what it shows,
/// what you can do there, and the words people use for it.
public struct DanteFeature: Identifiable, Equatable, Sendable {
    /// "map", or "map.infra" for a view inside a page.
    public var id: String
    /// The `Session.Area` it lives in ("settings" for the Settings window, "stage" for the Stage).
    public var area: String
    /// The view inside the area, when it has several ("infra" on the Map).
    public var view: String?
    public var title: String
    /// One spoken sentence: what it's for.
    public var summary: String
    /// What it shows and what you can do there, a sentence each.
    public var details: [String]
    /// Words that name it, lowercased: "pipelines", "cloud".
    public var phrases: [String]

    public init(_ id: String, area: String? = nil, view: String? = nil, title: String, summary: String, details: [String] = [], phrases: [String] = []) {
        self.id = id
        self.area = area ?? String(id.split(separator: ".").first ?? "")
        self.view = view ?? (id.contains(".") ? id.split(separator: ".").last.map(String.init) : nil)
        self.title = title
        self.summary = summary
        self.details = details
        self.phrases = phrases
    }
}

/// Every page and view in Dante. Voice opens and explains them from here and the agents get
/// it in their brief, so each new page or view gets an entry here as it's added
/// (`FeatureGuideTests` fails when an area has none).
public enum FeatureGuide {
    public static let features: [DanteFeature] = [
        DanteFeature("home", title: "Home",
                     summary: "Home is the project at a glance: what changed since you were last here, recent commits, the local environment, the docs and what the agent knows about the project.",
                     details: ["Since you were last here lists new commits and changed tasks.", "Local environment says which services are up.", "What the agent knows shows the CLAUDE.md memory it reads."],
                     phrases: ["home", "overview", "start page", "dashboard", "summary"]),
        DanteFeature("map", title: "Map",
                     summary: "The Map draws the system from its code: the clients and their screens, the API routes, the backend, the data and outside services, with arrows along the real calls.",
                     details: ["Select a box to see what it uses and what uses it.", "Boxes with an expand mark open: a part into its folders, a folder into its classes, a class into its methods with their routes, tables and calls.",
                               "Tables open the other way, back through the code to the routes that reach them, with their columns.",
                               "A web app or one of its screens opens in the browser: when its dev server isn't running, Dante says so, starts it in a terminal tab and opens the page once it's up.",
                               "Export writes the map as Mermaid into .dante/architecture.md."],
                     phrases: ["map", "system map", "architecture", "system", "diagram", "how it fits together"]),
        DanteFeature("map.infra", title: "Infrastructure",
                     summary: "The Infra view on the Map shows how a change is delivered and where it runs: the pipelines stage by stage, then the cloud resources by tier, with traffic flowing from users to the data.",
                     details: ["It reads CloudFormation, Terraform and ARM templates and Azure DevOps, GitHub Actions and GitLab pipelines.",
                               "How it works says in sentences how a change ships and how a request travels.",
                               "Select a stage or resource to see its steps or settings and open its file.",
                               "The agent in charge can explain it, review it, write an architecture document, or write a missing pipeline or templates."],
                     phrases: ["infra", "infrastructure", "pipelines", "pipeline", "cloud", "aws", "azure", "cloudformation", "terraform", "deployment", "devops"]),
        DanteFeature("map.modules", title: "Modules",
                     summary: "The Modules view on the Map shows the code's packages or folders and which imports which.",
                     phrases: ["modules", "packages", "dependency graph", "imports"]),
        DanteFeature("map.services", title: "Services",
                     summary: "The Services view on the Map shows the docker compose services and how they depend on each other.",
                     phrases: ["services view", "compose services", "service graph"]),
        DanteFeature("code", title: "Code",
                     summary: "Code is the editor: the file explorer, search, problems and the debugger beside it, the terminal below and the agent's panel on the right.",
                     details: ["Command I edits the selection with the agent.", "Search finds text, or code by meaning.", "Changes shows the git diff and commits."],
                     phrases: ["code", "editor", "files", "explorer", "source"]),
        DanteFeature("tests", title: "Tests",
                     summary: "Tests runs the project's tests and shows failures, flaky tests, the tests written per area and the functions no test names, which the agent can draft tests for.",
                     details: ["Run changed runs only the tests the changes touch."],
                     phrases: ["tests", "test", "testing", "test results", "failures", "coverage", "quality"]),
        DanteFeature("security", title: "Security",
                     summary: "Security scores the project out of a hundred and lists its findings, most serious first: secrets, personal information under POPIA, encryption, injection, containers, CI and dependencies.",
                     details: ["Fix with the agent sends findings to the agent in charge, and the other agent checks the fix.", "A deep audit asks for a read-only review.", "Accepted risks are kept in .dante/security.yaml."],
                     phrases: ["security", "vulnerabilities", "secrets", "popia", "audit", "score", "findings"]),
        DanteFeature("environments", title: "Services",
                     summary: "Services is the local environment: the docker compose services and their logs, the project's apps you can run, its other containers, and the ports in use.",
                     details: ["It says why a service isn't up and can move a port that's taken.", "Apps in this project can be run, or added to compose by the agent."],
                     phrases: ["services", "env", "environment", "environments", "local", "docker", "compose", "containers", "ports", "local setup"]),
        DanteFeature("data", title: "Data",
                     summary: "Data connects to the project's databases: browse tables, run queries, read query plans with index suggestions and preview migrations before they run.",
                     details: ["It finds databases from compose, env files and the project's containers.", "Passwords are kept in the Keychain."],
                     phrases: ["data", "database", "databases", "tables", "sql", "queries", "postgres", "schema"]),
        DanteFeature("ship", title: "Release",
                     summary: "Release is for shipping: the CI runs, pull requests and a release checklist.",
                     phrases: ["ship", "release", "releases", "ci", "ci runs", "pull requests", "deploy", "shipping"]),
        DanteFeature("run", title: "Health",
                     summary: "Health watches the running app: its health and the errors in its logs since the window opened.",
                     phrases: ["run", "runtime", "health", "errors", "alarms", "logs", "running app", "monitoring"]),
        DanteFeature("timeline", title: "History",
                     summary: "History is the project's history in one stream: commits, the agent's conversations, test runs and CI.",
                     phrases: ["timeline", "history", "what happened"]),
        DanteFeature("claude", title: "Setup",
                     summary: "Setup is how the agents are set up for this project: skills, memory files, connectors, plugins, permissions and recent conversations.",
                     details: ["It suggests skills worth adding for the project and drafts them."],
                     phrases: ["setup", "skills", "memory", "connectors", "plugins", "permissions", "claude setup", "mcp"]),
        DanteFeature("agents", title: "Activity",
                     summary: "Activity shows who did the work: Claude, Codex and the local models, the jobs each did, who checked whose work, and the models on this Mac.",
                     phrases: ["agents", "agent activity", "activity", "models", "local models", "ollama", "who did what", "ledger"]),
        DanteFeature("jobs", title: "Jobs",
                     summary: "Jobs are agents working beside the main conversation, each in its own git worktree, with their changes to merge or discard, and job types that start on their own when CI fails.",
                     details: ["Away mode lets a job carry on without asking for routine steps for a set time."],
                     phrases: ["jobs", "job", "background jobs", "worktrees", "board"]),
        DanteFeature("docs", title: "Docs",
                     summary: "Docs is the project's documentation library: markdown with diagrams, PDFs and Word files, grouped by folder.",
                     phrases: ["docs", "documentation", "readme", "library", "documents"]),
        DanteFeature("settings", area: "settings", title: "Settings",
                     summary: "Settings holds the appearance, editor, keyboard shortcuts, language servers, files, agents and voice, tools and the project's own settings.",
                     phrases: ["settings", "preferences", "options", "configuration"]),
        DanteFeature("stage", area: "stage", title: "Stage",
                     summary: "The Stage is Dante full screen: the orb, the agents at work, the reply as it's spoken and anything waiting for approval.",
                     phrases: ["stage"]),
    ]

    /// The rail's places, in order, each with its pages as tabs (the first is where it opens).
    /// The app's rail is built from this list.
    public struct Place: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var pages: [String]
    }

    public static let places: [Place] = [
        Place(id: "home", title: "Home", pages: ["home"]),
        Place(id: "map", title: "Map", pages: ["map"]),
        Place(id: "code", title: "Code", pages: ["code"]),
        Place(id: "quality", title: "Quality", pages: ["tests", "security"]),
        Place(id: "local", title: "Local", pages: ["environments", "data", "run"]),
        Place(id: "ship", title: "Ship", pages: ["ship", "timeline"]),
        Place(id: "agents", title: "Agents", pages: ["jobs", "agents", "claude"]),
        Place(id: "docs", title: "Docs", pages: ["docs"]),
    ]

    /// The place a page is in.
    public static func place(of page: String) -> Place? { places.first { $0.pages.contains(page) } }

    public static func feature(_ id: String) -> DanteFeature? { features.first { $0.id == id } }

    /// The page a request names, when that's all it names: "the infrastructure", "data page",
    /// "the map view". Nil for anything longer ("where the data is saved"), which is a
    /// question for the agent.
    public static func match(_ spoken: String) -> DanteFeature? {
        var words = spoken.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" }.split(separator: " ").map(String.init)
        while let first = words.first, ["the", "my", "our", "this", "a"].contains(first) { words.removeFirst() }
        while let last = words.last, ["page", "view", "tab", "screen", "area", "section", "for", "do", "please", "now", "then", "again"].contains(last) { words.removeLast() }
        // "infra on the map": the view's name is enough.
        if let on = words.lastIndex(where: { $0 == "on" || $0 == "in" }), on > 0, words[(on + 1)...].filter({ $0 != "the" }) == ["map"] {
            words = Array(words[..<on])
        }
        let name = words.joined(separator: " ")
        guard !name.isEmpty else { return nil }
        // A page's own title first ("services" is the Services tab, not the Map's view), then
        // a view's words over a page's ("pipelines" is the Infra view).
        if let page = features.first(where: { $0.view == nil && $0.title.lowercased() == name }) { return page }
        let found = features.filter { $0.title.lowercased() == name || $0.phrases.contains(name) }
        return found.first { $0.view != nil } ?? found.first
    }

    /// Spoken: what it is and the first things to know.
    public static func explanation(of feature: DanteFeature) -> String {
        ([feature.summary] + feature.details.prefix(2)).joined(separator: " ")
    }

    /// Spoken: the places in a breath, with the pages inside each.
    public static var overview: String {
        let spoken = places.map { place -> String in
            let pages = place.pages.compactMap { feature($0)?.title }
            return pages == [place.title] ? place.title : "\(place.title), with \(list(pages))"
        }
        return "Dante has \(spoken.count) places: " + spoken.joined(separator: "; ") + ". Say open and a page's name, or ask what one does."
    }

    private static func list(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// For the agents' brief: every page and view in a line, so they can send the user there.
    public static var brief: String {
        let lines = features.map { feature -> String in
            let place: String
            if feature.view != nil {
                place = "\(self.feature(feature.area)?.title ?? feature.area.capitalized) › \(feature.title)"
            } else if let group = self.place(of: feature.id), group.pages.count > 1 {
                place = "\(group.title) › \(feature.title)"
            } else {
                place = feature.title
            }
            return "- \(place): \(feature.summary)"
        }
        return "Dante (the IDE the user is in) has these pages; point the user to one when it shows what they ask about:\n" + lines.joined(separator: "\n")
    }
}
