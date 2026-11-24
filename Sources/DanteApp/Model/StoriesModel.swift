import AppKit
import DanteKit
import Observation

/// Quality › Stories: the web app's stories (Playwright tests told step by step), their last
/// run with each step's picture, ideas for the ones not yet told, and why a broken one broke.
/// Pictures are copied out of Playwright's output (which it clears every run) into
/// Application Support, with the last passing run's kept beside the latest for comparison.
@MainActor
@Observable
final class StoriesModel {
    /// A scenario's last pass: when, at which commit, and its steps' pictures.
    struct Pass: Codable, Equatable {
        var date: Date
        var commit: String?
        var steps: [StoryScenario.Step]
    }

    /// What's kept per project on this Mac.
    struct Index: Codable {
        var scenarios: [StoryScenario] = []
        var passes: [String: Pass] = [:]
        var serverLines: [String: [String]] = [:]
        var app: String?
    }

    private(set) var root: URL?
    var loaded = false
    var apps: [SystemMap.Part] = []
    var appID: String? {
        didSet { if let root, oldValue != appID { UserDefaults.standard.set(appID, forKey: "stories.app." + root.path) } }
    }
    var target: WebPreview.Target?
    /// The stories folder, from the project root.
    var folder: String?
    var hasKit = false
    var kitOutdated = false
    var hasPlaywright = false
    var storyFiles: [String] = []
    var ideas: [StoryIdea] = []
    var chosenIdeas: Set<String> = []
    var scenarios: [StoryScenario] = []
    var passes: [String: Pass] = [:]
    var serverLines: [String: [String]] = [:]
    var diagnoses: [String: StoryDiagnosis] = [:]
    var run: TestRun?
    /// What the run covers: file names, scenario ids, or "*".
    var running: Set<String> = []
    var listening: Bool?
    var starting = false
    var problem: String?
    var openFeature: String?
    var openScenario: String?
    @ObservationIgnored private var system: SystemMap?
    @ObservationIgnored private var routes: [BliksemRoute] = []
    @ObservationIgnored private var access: AccessGuide?
    @ObservationIgnored private var files: [String] = []
    @ObservationIgnored private var gitRoot: GitLocation?

    var features: [StoryFeature] { StoryReport.features(scenarios.filter { storyFiles.contains($0.file) }) }
    var app: SystemMap.Part? { apps.first { $0.id == appID } ?? apps.first }
    var baseURL: String? { target.map { "http://localhost:\($0.port)" } }
    var isRunning: Bool { run?.isRunning == true }

    // MARK: Loading

    func load(session: Session, workspace: Workspace) async {
        let root = workspace.url
        if self.root != root {
            self.root = root
            let index = Self.readIndex(root: root)
            scenarios = index.scenarios
            passes = index.passes
            serverLines = index.serverLines
            appID = UserDefaults.standard.string(forKey: "stories.app." + root.path)
            openFeature = nil
            openScenario = nil
            chosenIdeas = []
        }
        files = workspace.files
        gitRoot = workspace.git
        let read = MapView.reader(root: root)
        let system: SystemMap
        if let cache = session.mapCache, cache.revision == workspace.revision, let cached = cache.system {
            system = cached
        } else {
            let files = workspace.files
            let compose = ComposeFile.load(projectRoot: root)
            let modules = await MapView.modules(root: root, files: files)
            system = await Task.detached(priority: .utility) { SystemMap.build(files: files, read: read, compose: compose, modules: modules) }.value
        }
        self.system = system
        routes = BliksemRoute.from(system)
        apps = StoryPlan.webApps(system)
        if let appID, !apps.contains(where: { $0.id == appID }) { self.appID = nil }
        if appID == nil {
            // The app that already has stories, else the first.
            appID = apps.first { part in
                let folder = StoryKit.folder(frontend: part.path == "." ? "" : part.path ?? "")
                return workspace.files.contains { $0.hasPrefix(folder + "/") }
            }?.id ?? apps.first?.id
        }
        if let text = try? String(contentsOf: root.appending(path: AccessGuide.path), encoding: .utf8), let guide = AccessGuide.read(yaml: text) {
            access = guide
        } else {
            let files = workspace.files
            access = await Task.detached(priority: .utility) { AccessGuide.detect(files: files, read: read) }.value
        }
        await refresh(root: root)
        loaded = true
    }

    /// Re-reads the chosen app's target, kit, Playwright, stories and ideas.
    func refresh(root: URL) async {
        guard let app, let system else {
            target = nil
            folder = nil
            ideas = []
            return
        }
        let files = files
        let read = MapView.reader(root: root)
        let frontend = app.path == "." ? "" : app.path ?? ""
        var found = await Task.detached(priority: .utility) {
            WebPreview.target(folder: frontend, name: app.name, files: files, read: read)
        }.value
        if let compose = ComposeFile.load(projectRoot: root), let through = WebPreview.throughCompose(found, compose: compose) { found = through }
        target = found
        let folder = StoryKit.folder(frontend: found.folder)
        self.folder = folder
        let fm = FileManager.default
        let config = root.appending(path: folder + "/" + StoryKit.configName)
        let helper = (try? String(contentsOf: root.appending(path: folder + "/" + StoryKit.helperName), encoding: .utf8))
        hasKit = fm.fileExists(atPath: config.path) && helper != nil
        kitOutdated = helper.flatMap(StoryKit.version(of:)).map { $0 < StoryKit.version } ?? false
        let prefix = found.folder.isEmpty ? "" : found.folder + "/"
        hasPlaywright = [prefix + "node_modules/@playwright/test", "node_modules/@playwright/test"].contains { fm.fileExists(atPath: root.appending(path: $0).path) }
        storyFiles = StoryKit.storyFiles(files, folder: folder)
        let written = storyFiles.map { ($0 as NSString).lastPathComponent } + features.map(\.name)
        let access = access
        ideas = await Task.detached(priority: .utility) { StoryPlan.ideas(app: app, map: system, access: access, read: read, written: written) }.value
        if chosenIdeas.isEmpty || !chosenIdeas.isSubset(of: Set(ideas.map(\.id))) { chosenIdeas = Set(ideas.map(\.id)) }
        listening = await Session.isListening(found.port)
        await diagnose(root: root)
    }

    // MARK: Setting up

    /// Writes the kit into the stories folder (the config only when missing).
    func setUp(root: URL) {
        guard let folder else { return }
        let url = root.appending(path: folder)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let files = StoryKit.files { name in try? String(contentsOf: url.appending(path: name), encoding: .utf8) }
            for file in files { try file.text.write(to: url.appending(path: file.name), atomically: true, encoding: .utf8) }
            problem = nil
        } catch {
            problem = "Couldn’t write the story kit into \(folder): \(error.localizedDescription)"
        }
        Task { await refresh(root: root) }
    }

    /// Starts the web app in a terminal tab of its own and waits for its port.
    func startApp(session: Session) {
        guard let target, !starting else { return }
        starting = true
        session.runInNewTerminal(target.command, title: target.name)
        Task {
            defer { starting = false }
            for _ in 0..<150 {
                try? await Task.sleep(for: .seconds(1))
                if await Session.isListening(target.port) {
                    listening = true
                    return
                }
            }
            problem = "\(target.name) didn’t start listening on port \(target.port) within two and a half minutes: its terminal tab says why."
        }
    }

    // MARK: Running

    /// Runs every story, one file's, or some scenarios (by id).
    func start(session: Session, root: URL, files storyFiles: [String] = [], scenarios chosen: [StoryScenario] = []) {
        guard let folder, let baseURL, !isRunning else { return }
        let relative = storyFiles.map { String($0.dropFirst(folder.count + 1)) }
        let grep = chosen.map(\.title)
        let fileArgs = chosen.isEmpty ? relative : Array(Set(chosen.map { String($0.file.dropFirst(folder.count + 1)) })).sorted()
        let command = StoryKit.command(folder: folder, baseURL: baseURL, files: fileArgs, grep: grep)
        running = chosen.isEmpty ? (storyFiles.isEmpty ? ["*"] : Set(storyFiles)) : Set(chosen.map(\.id))
        problem = nil
        let commit = Task { await Self.head(git: gitRoot) }
        let run = TestRun(command: command, projectRoot: root)
        run.onFinish = { [weak self] run in
            Task { @MainActor in
                await self?.finish(run, root: root, commit: await commit.value, ranFiles: chosen.isEmpty && storyFiles.isEmpty)
                TestRunLog.append(run.saved(), for: root)
            }
        }
        self.run = run
        if case .couldNotStart(let reason) = run.state {
            problem = reason
            running = []
        }
    }

    func stop() {
        run?.stop()
        running = []
    }

    private func finish(_ run: TestRun, root: URL, commit: String?, ranFiles all: Bool) async {
        defer { running = [] }
        let date = run.finished ?? .now
        let fresh = StoryReport.scenarios(from: run.results, date: date) { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        if fresh.isEmpty, run.failedOutsideTests {
            problem = "The stories didn’t run: " + (BrokenRunLines.pick(run.output).last ?? "Playwright stopped before any story ran.")
            return
        }
        let archive = Self.archiveFolder(root: root)
        let passes = passes
        let (kept, newPasses) = await Task.detached(priority: .utility) {
            Self.archive(fresh, into: archive, commit: commit, passes: passes)
        }.value
        scenarios = StoryReport.merged(scenarios, with: kept, files: all ? StoryKit.storyFiles(files, folder: folder ?? "") : nil)
        self.passes = newPasses
        // The server's own words about the run, from the project's compose services.
        let log = await Self.serverLog(root: root, since: run.started)
        for scenario in kept where scenario.status == .failed { serverLines[scenario.id] = StoryDiagnosis.errorLines(log) }
        for scenario in kept where scenario.status == .passed { serverLines[scenario.id] = nil }
        saveIndex(root: root)
        StoryShot.forget()
        await diagnose(root: root)
        if let open = openScenario, !scenarios.contains(where: { $0.id == open }) { openScenario = nil }
    }

    /// Diagnoses every broken scenario: what changed since it last passed comes from git.
    func diagnose(root: URL) async {
        var found: [String: StoryDiagnosis] = [:]
        var changedSince: [String: [String]] = [:]
        for scenario in scenarios where scenario.status == .failed {
            var changed: [String]?
            if let commit = passes[scenario.id]?.commit {
                if changedSince[commit] == nil { changedSince[commit] = await Self.changed(since: commit, git: gitRoot) }
                let handlers = scenario.calls.compactMap { call in StoryDiagnosis.route(serving: call, in: routes)?.file }
                changed = StoryDiagnosis.relevant(changedSince[commit] ?? [], frontend: target?.folder ?? "", handlers: handlers)
            }
            found[scenario.id] = StoryDiagnosis.explain(scenario, routes: routes, changed: changed, serverLog: serverLines[scenario.id] ?? [])
        }
        diagnoses = found
    }

    // MARK: The agent

    func writeBrief(session: Session) -> String? {
        guard let folder, let baseURL, let app else { return nil }
        let chosen = ideas.filter { chosenIdeas.contains($0.id) }
        return StoryPlan.brief(ideas: chosen, app: app.name, folder: folder, baseURL: baseURL, access: access,
                               existing: storyFiles.map { ($0 as NSString).lastPathComponent }, map: system,
                               runCommand: rerunCommand(files: []))
    }

    /// What a person (or the agent) types to run stories.
    func rerunCommand(files: [String], grep: String? = nil) -> String {
        guard let folder, let baseURL else { return "" }
        // The web app's own Playwright, else the repo root's.
        let frontend = target?.folder ?? ""
        let inApp = root.map { FileManager.default.fileExists(atPath: $0.appending(path: (frontend.isEmpty ? "" : frontend + "/") + "node_modules/.bin/playwright").path) } ?? true
        let up = String(repeating: "../", count: inApp ? 1 : folder.split(separator: "/").count)
        var line = "cd \(Shell.quote(folder)) && STORY_BASE_URL=\(baseURL) \(up)node_modules/.bin/playwright test"
        line += files.map { " " + Shell.quote(String($0.dropFirst(folder.count + 1))) }.joined()
        if let grep { line += " --grep " + Shell.quote(NSRegularExpression.escapedPattern(for: grep)) }
        return line
    }

    // MARK: Files

    nonisolated static func archiveFolder(root: URL) -> URL {
        let path = root.standardizedFileURL.path
        return URL.applicationSupportDirectory.appending(path: "Dante/stories/\(root.lastPathComponent)-\(String(SemanticIndex.hash(path), radix: 16))", directoryHint: .isDirectory)
    }

    nonisolated static func readIndex(root: URL) -> Index {
        guard let data = try? Data(contentsOf: archiveFolder(root: root).appending(path: "index.json")) else { return Index() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Index.self, from: data)) ?? Index()
    }

    private func saveIndex(root: URL) {
        let index = Index(scenarios: scenarios, passes: passes, serverLines: serverLines, app: appID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let folder = Self.archiveFolder(root: root)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? encoder.encode(index) { try? data.write(to: folder.appending(path: "index.json"), options: .atomic) }
    }

    /// Copies each scenario's pictures and video out of Playwright's output folder, into
    /// `<scenario>/latest` and, when it passed, `<scenario>/passed`, and points the scenario at
    /// the copies.
    nonisolated static func archive(_ scenarios: [StoryScenario], into folder: URL, commit: String?, passes: [String: Pass]) -> ([StoryScenario], [String: Pass]) {
        let fm = FileManager.default
        var passes = passes
        let kept = scenarios.map { original -> StoryScenario in
            var scenario = original
            let base = folder.appending(path: String(SemanticIndex.hash(scenario.id), radix: 16), directoryHint: .isDirectory)
            let latest = base.appending(path: "latest", directoryHint: .isDirectory)
            try? fm.removeItem(at: latest)
            try? fm.createDirectory(at: latest, withIntermediateDirectories: true)
            func copy(_ path: String?, as name: String) -> String? {
                guard let path, fm.fileExists(atPath: path) else { return nil }
                let to = latest.appending(path: name)
                try? fm.copyItem(at: URL(fileURLWithPath: path), to: to)
                return fm.fileExists(atPath: to.path) ? to.path : nil
            }
            for index in scenario.steps.indices {
                scenario.steps[index].shot = copy(scenario.steps[index].shot, as: String(format: "step-%02d.png", index + 1))
            }
            scenario.video = copy(scenario.video, as: "video.webm")
            // The trace stays where Playwright put it: it's large, and only for a broken run.
            if scenario.status == .passed {
                let passed = base.appending(path: "passed", directoryHint: .isDirectory)
                try? fm.removeItem(at: passed)
                try? fm.copyItem(at: latest, to: passed)
                let steps = scenario.steps.map { step in
                    var step = step
                    step.shot = step.shot.map { passed.appending(path: ($0 as NSString).lastPathComponent).path }
                    return step
                }
                passes[scenario.id] = Pass(date: scenario.date ?? .now, commit: commit, steps: steps)
            }
            return scenario
        }
        return (kept, passes)
    }

    nonisolated static func head(git: GitLocation?) async -> String? {
        guard let git else { return nil }
        let output = await Shell.run(["git", "rev-parse", "HEAD"], in: git.root, timeout: .seconds(10))
        return output.succeeded && !output.stdout.isEmpty ? output.stdout : nil
    }

    /// Project paths changed since a commit, committed or not.
    nonisolated static func changed(since commit: String, git: GitLocation?) async -> [String] {
        guard let git else { return [] }
        let diff = await Shell.run(["git", "diff", "--name-only", commit], in: git.root, timeout: .seconds(20))
        let untracked = await Shell.run(["git", "ls-files", "--others", "--exclude-standard"], in: git.root, timeout: .seconds(20))
        let lines = (diff.succeeded ? diff.stdout : "").split(separator: "\n") + (untracked.succeeded ? untracked.stdout : "").split(separator: "\n")
        return Array(Set(lines.map { git.projectPath(String($0)) })).sorted()
    }

    /// The compose services' log since the run began, when the project runs any.
    nonisolated static func serverLog(root: URL, since: Date) async -> [String] {
        guard ComposeFile.load(projectRoot: root) != nil else { return [] }
        let stamp = ISO8601DateFormatter().string(from: since.addingTimeInterval(-2))
        let output = await Shell.run(["docker", "compose", "logs", "--no-color", "--since", stamp], in: root, timeout: .seconds(20))
        return output.succeeded ? output.stdout.split(separator: "\n").suffix(2000).map(String.init) : []
    }
}
