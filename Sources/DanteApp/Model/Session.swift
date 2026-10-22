import AppKit
import DanteEditor
import DanteKit
import Observation
import PDFKit
import UniformTypeIdentifiers

/// The areas in the workspace rail, one per screen in the design canvas.
enum Area: String, CaseIterable, Identifiable {
    case home, map, code, tests, security, environments, data, ship, run, timeline, claude, agents, jobs, office, docs

    var id: String { rawValue }

    /// The page's name, from `FeatureGuide` so voice, the agents and the rail say the same.
    var title: String { FeatureGuide.feature(rawValue)?.title ?? rawValue.capitalized }

    /// "Local › Services" for a tab, "Map" for a place of its own.
    var fullTitle: String { place.pages.count > 1 ? "\(place.title) › \(title)" : title }

    /// The rail place it's a tab of.
    var place: RailPlace {
        (RailPlace.main + RailPlace.footer).first { $0.pages.contains(self) } ?? RailPlace(id: rawValue, title: title, pages: [self], footer: false)
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .map: "point.3.connected.trianglepath.dotted"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .tests: "testtube.2"
        case .security: "shield.lefthalf.filled"
        case .environments: "server.rack"
        case .data: "cylinder.split.1x2"
        case .ship: "paperplane"
        case .run: "waveform.path.ecg"
        case .timeline: "clock.arrow.circlepath"
        case .claude: "slider.horizontal.3"
        case .agents: "chart.bar.doc.horizontal"
        case .jobs: "square.stack.3d.up"
        case .office: "building.2"
        case .docs: "doc.text"
        }
    }

    /// What the area is for, shown as the rail button's tooltip.
    var summary: String {
        switch self {
        case .home: "Where the project is: what changed, the environment, Claude and docs at a glance."
        case .map: "Architecture, process flows, data model and cloud diagrams generated from the code."
        case .code: "The editor, file explorer and terminal."
        case .tests: "Tests traced to specs and code paths, coverage by component, and tests Claude can draft."
        case .security: "Secrets, personal information, encryption, injection, dependencies and config: scanned, explained and fixed by Claude or Codex."
        case .environments: "Docker Compose services with logs, shells and restarts, and Docker files Claude can write."
        case .data: "The project's databases: create one, browse tables, run queries and see the schema as a diagram."
        case .ship: "A release checklist, a changelog drafted from commits, and the CI pipeline."
        case .run: "Production metrics, errors and alarms."
        case .timeline: "Commits, releases, Claude sessions, test runs and CI in one stream, newest first."
        case .claude: "How the agents work on this project: usage, skills, memory, connectors and permissions."
        case .agents: "Claude, Codex and the models they delegate to: who did what, who checked what, and why."
        case .jobs: "Work handed to agents that run side by side, each on its own branch in its own worktree: what they're doing, what they need from you, and merging it."
        case .office: "The agents' little office, which grows as they work: rooms open and fill up, and the garage becomes a campus."
        case .docs: "Specs and decisions as documents, with live diagrams and test status, in Paper mode."
        }
    }

}

/// A place in the rail: one page, or several shown as tabs (`FeatureGuide.places`).
struct RailPlace: Identifiable, Equatable {
    let id: String
    let title: String
    let pages: [Area]

    let footer: Bool

    static let all: [RailPlace] = FeatureGuide.places.map { place in
        RailPlace(id: place.id, title: place.title, pages: place.pages.compactMap(Area.init(rawValue:)), footer: place.footer)
    }
    static var main: [RailPlace] {
        // Without the spec (a broken bundle), each page is its own place rather than no rail.
        all.isEmpty ? Area.allCases.filter { $0 != .docs }.map { RailPlace(id: $0.rawValue, title: $0.title, pages: [$0], footer: false) }
                    : all.filter { !$0.footer }
    }
    static var footer: [RailPlace] { all.isEmpty ? [RailPlace(id: "docs", title: "Docs", pages: [.docs], footer: true)] : all.filter(\.footer) }

    var symbol: String {
        switch id {
        case "quality": "checkmark.seal"
        case "local": "shippingbox"
        case "ship": "paperplane"
        case "agents": "circle.hexagongrid"
        default: pages.first?.symbol ?? "square"
        }
    }

    var summary: String {
        switch id {
        case "quality": "Tests and security: what's covered, what fails, and what to fix."
        case "local": "What runs on this Mac: services, databases and the app's health."
        case "ship": "Releases, CI and the project's history."
        case "agents": "Jobs, who did what, and how the agents are set up."
        default: pages.first?.summary ?? ""
        }
    }
}

/// What the command palette searches. ⌘K opens it on everything, ⌘P on files.
enum PaletteScope: String, CaseIterable, Identifiable {
    case all = "All", files = "Files", symbols = "Symbols", docs = "Docs", actions = "Actions"
    var id: String { rawValue }
}

struct TerminalInput: Equatable {
    let id = UUID()
    let text: String
    /// The tab it's for; the one in front when it was sent.
    let tab: UUID
}

/// One shell in the terminal panel.
struct TerminalTab: Identifiable, Equatable {
    let id = UUID()
    var title = "zsh"
    /// Bumped to restart the shell.
    var generation = 0
    var exitCode: Int32??
    var exited: Bool { exitCode != nil }
}

/// Everything one window shows: the open folder, the selected area and panel state.
@MainActor
@Observable
final class Session {
    let recents: RecentProjects
    private(set) var workspace: Workspace?
    private(set) var branch: String?
    private(set) var claude: ClaudeSession?
    /// Agents working beside the main conversation, each in its own worktree.
    let jobs = JobsModel()
    /// The job whose conversation the panel shows; nil for the main conversation.
    var shownJob: String?
    /// The conversation the panel shows.
    var shownClaude: ClaudeSession? { shownJob.flatMap { jobs.sessions[$0] } ?? claude }
    /// Language servers for the open project's files.
    private(set) var languages: LanguageServices?
    private var watcher: DirectoryWatcher?
    /// Open files that changed on disk while they had unsaved edits.
    var conflicts: Set<URL> = []

    var area: Area = .code {
        didSet { lastPage[area.place.id] = area }
    }
    /// The tab each rail place was last on, so going back to a place returns to it.
    var lastPage: [String: Area] = [:]
    /// The view shown inside the area when it has several ("infra" on the Map): set by the
    /// area as it switches, and by voice to ask for one (`FeatureGuide` ids after the dot).
    var areaView: String?
    /// A web app being opened from the Map, with its progress.
    var webLaunch: WebLaunch?
    /// Remembered across windows and launches, so a minimised terminal stays minimised.
    var showsTerminal = UserDefaults.standard.object(forKey: "showsTerminal") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsTerminal, forKey: "showsTerminal") }
    }
    var terminalHeight: Double = 240
    var showsClaude = true
    /// The command palette, when it's open.
    var palette: PaletteScope?
    /// Go to Symbol's scan of the project, for the workspace revision it was made at.
    /// The explorer's selection while one of its rows is being dragged, so a drop moves them all.
    @ObservationIgnored var draggedFiles: [URL] = []
    @ObservationIgnored var symbolIndex: (revision: Int, symbols: [CodeSymbol])?

    /// Bumped when HEAD moves (a commit, checkout or reset), so views comparing against it reload.
    var gitRevision = 0

    enum Sidebar { case files, search, changes, problems, debug }
    var sidebar: Sidebar = .files
    let search = SearchState()
    let semantic = SemanticState()
    /// Source control: status, staging, commits, branches.
    let git = GitModel()
    /// The branch switcher in the title bar is open.
    var showsBranches = false
    /// Claude rewriting code in the editor (⌘I), while its bar is open.
    var inlineEdit: InlineEditModel?
    /// What changed since this project was last closed, for Home; nil when nothing did.
    var sinceLastVisit: SinceLastVisit?
    /// The Data area's connections, schema and tabs.
    let data = DataModel()
    var searchFocusRequest = 0

    /// Edit › Find in Project (⇧⌘F).
    func showSearch() {
        area = .code
        sidebar = .search
        searchFocusRequest += 1
    }

    /// View › Source Control (⌃⇧G).
    func showChanges() {
        area = .code
        sidebar = .changes
    }

    /// View › Problems (⇧⌘M).
    func showProblems() {
        area = .code
        sidebar = .problems
    }

    /// Opens a search result with the match selected.
    func open(_ match: ProjectSearch.Match, in path: String) {
        guard let workspace else { return }
        open(file: workspace.url.appending(path: path))
        guard let document = workspace.activeDocument, document.url.standardizedFileURL == workspace.url.appending(path: path).standardizedFileURL else { return }
        let lines = LineIndex(document.text as NSString)
        let start = lines.offset(of: LSPPosition(line: match.line, character: match.column))
        document.revealRange = NSRange(location: start, length: match.length)
    }
    var claudeWidth: Double = 380

    /// The document the Docs area shows, as a project-relative path.
    var docPath: String?
    struct HTMLPresentation: Identifiable {
        let url: URL
        let root: URL
        let rules: ClaudeRules
        var id: URL { url }
    }
    var htmlPresentation: HTMLPresentation?
    /// A heading to scroll the open doc to.
    var docAnchor: String?
    /// The latest test run, kept while the window is open so it runs on in the background.
    var testRun: TestRun?
    /// Health checks and the production log stream for the Run area.
    let health = HealthMonitor()
    /// Monitoring alarms from `operate.alarms`, polled while the window is open.
    let alarms = AlarmMonitor()
    var logWatch: LogWatch?

    func showDoc(_ path: String) {
        docPath = path
        area = .docs
    }
    /// Text queued for the integrated terminal's shell.
    private(set) var terminalInput: TerminalInput?
    /// Bumped to move keyboard focus to Claude's message box.
    var claudeFocusRequest = 0
    /// The Claude panel's history and usage popovers, so `/history` and `/context` can open them.
    var claudeShowsHistory = false
    var claudeShowsUsage = false
    /// The Map's last build, kept while the window is open.
    @ObservationIgnored var mapCache: MapCache?
    /// A part Home's map was clicked on, for the Map to select when it opens.
    @ObservationIgnored var mapFocus: String?
    /// Critiques of motion pieces, by the version's folder, kept while the window is open.
    var motionCritiques: [URL: MotionCritiqueState] = [:]
    /// The Security area's report, scans and audits.
    let security = SecurityModel()
    /// 1-based breakpoint lines per file path, saved per project on this Mac.
    var breakpoints: [String: Set<Int>] = [:]
    /// The debugging run, while there is one (and after it ends, until the next).
    var debug: DebugSession?
    /// Set while the open folder is a remote project's mirror.
    var remoteSync: RemoteSync?
    /// The window this session draws into, to bring forward when `dante` opens something in it.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var shipCache: ShipCache?
    /// Timeline's last load, shown while it reads the history again.
    @ObservationIgnored var timelineCache: [TimelineEvent]?
    /// Files waiting to go with the next message to Claude.
    var claudeAttachments: [Attachment] = []
    /// Recent Claude usage on this Mac and the signed-in plan, for the panel's meter.
    var claudeUsage: ClaudeUsage?
    var claudeAccount: ClaudeAccount?
    var attachmentsLoading = 0
    var cursor = CursorPosition()
    var isCloning = false
    var showsOpenRemote = false
    var errorMessage: String?

    init(recents: RecentProjects) {
        self.recents = recents
        Sessions.register(self)
    }

    var hasUnsavedChanges: Bool {
        workspace?.documents.contains(where: \.isDirty) ?? false
    }

    // MARK: Projects

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        if panel.runModal() == .OK, let url = panel.url {
            open(folder: url)
        }
    }

    func newProject() {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Project name:"
        panel.nameFieldStringValue = "new-project"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            open(folder: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(folder url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "\(url.lastPathComponent) can’t be found. It may have been moved or deleted."
            recents.prune()
            return
        }
        guard confirmDiscardingChanges(in: workspace?.documents ?? []) else { return }
        recordVisit()
        claude?.stop()
        languages?.stop()
        stopDebugging()
        debug = nil
        // Before anything starts a process in the folder, so commands go to the host.
        attachRemote(for: url)
        let workspace = Workspace(url: url)
        self.workspace = workspace
        loadBreakpoints()
        loadSinceLastVisit(for: workspace)
        claude = makeClaude(for: workspace)
        shownJob = nil
        jobs.makeSession = { [weak self, weak workspace] job in
            guard let self, let workspace else { return ClaudeSession(root: job.worktreeURL, executable: nil, systemPrompt: { "" }) }
            return self.makeJobClaude(for: job, in: workspace)
        }
        jobs.onAwayTimeUp = { [weak self] job in
            self?.notifyClaude(.needsApproval("Its away time is up; from here on each step waits for you."), job: job.title)
        }
        jobs.currentBranch = { [weak self] in self?.branch }
        jobs.onTriggered = { [weak self] job in
            self?.notifyClaude(.needsApproval("Started by itself: \(job.title)"), job: job.title)
        }
        jobs.load(root: url, remote: RemoteRegistry.project(containing: url) != nil)
        languages = LanguageServices(root: url)
        conflicts = []
        mapCache = nil
        shipCache = nil
        timelineCache = nil
        terminalTabs = [TerminalTab()]
        history = NavigationHistory()
        workspace.refreshFileIndex()
        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] changed in self?.filesChanged(changed) }
        branch = Git.currentBranch(in: url)
        area = .code
        recents.note(url)
    }

    func closeProject() {
        guard confirmDiscardingChanges(in: workspace?.documents ?? []) else { return }
        recordVisit()
        claude?.stop()
        claude = nil
        jobs.stopAll()
        shownJob = nil
        languages?.stop()
        languages = nil
        watcher?.stop()
        watcher = nil
        palette = nil
        workspace = nil
        branch = nil
    }

    /// The window closed: stop every process and watcher it started. Unsaved changes were
    /// already handled by the close or quit prompt.
    func shutdown() {
        detachRemote()
        stopDebugging()
        recordVisit()
        claude?.stop()
        jobs.stopAll()
        languages?.stop()
        watcher?.stop()
        logWatch?.stop()
        health.stop()
        alarms.stop()
    }

    /// Notes how the project looks now, for the next "since you were last here".
    func recordVisit() {
        guard let workspace else { return }
        ProjectVisit.now(root: workspace.url, tasks: workspace.tasks.file.tasks).save(for: workspace.url)
    }

    private func loadSinceLastVisit(for workspace: Workspace) {
        sinceLastVisit = nil
        guard let visit = ProjectVisit.load(for: workspace.url) else { return }
        Task {
            let since = await SinceLastVisit.load(since: visit, root: workspace.url, tasks: workspace.tasks.file.tasks)
            guard self.workspace === workspace else { return }
            sinceLastVisit = since.isEmpty ? nil : since
        }
    }

    private func filesChanged(_ changed: [URL]) {
        guard let workspace else { return }
        remoteSync?.request()
        let result = workspace.applyExternalChanges(changed)
        languages?.filesChanged(changed)
        if result.gitHeadChanged {
            refreshBranch()
            gitRevision += 1
        }
        conflicts.formUnion(result.conflicts)
    }

    /// Resolves a disk conflict: reload from disk, or keep the editor's version.
    func resolveConflict(_ document: EditorDocument, reload: Bool) {
        conflicts.remove(document.url)
        if reload {
            do { try document.reloadFromDisk() } catch { errorMessage = error.localizedDescription }
        }
    }

    func refreshBranch() {
        if let url = workspace?.url { branch = Git.currentBranch(in: url) }
    }

    // MARK: Claude

    private func makeClaude(for workspace: Workspace) -> ClaudeSession {
        let claude = ClaudeSession(
            root: workspace.url,
            executable: SystemStatus.detect().claudePath,
            systemPrompt: { [weak workspace] in ClaudeBrief.systemPrompt(for: workspace) },
            rules: { [weak workspace] in workspace?.claudeRules ?? ClaudeRules() }
        )
        claude.onFileChanged = { [weak workspace] url in workspace?.fileChanged(at: url) }
        claude.onAttention = { [weak self] attention in
            self?.notifyClaude(attention)
            self?.pullRemoteTranscripts()
        }
        // Asked about security, the agent runs the Security page's scan: show the page.
        claude.onDanteTool = { [weak self, weak claude] name, input, finished in
            if name == "open_file", !finished { self?.openAgentFile(input); return }
            if name == "show_page", !finished, let feature = input["page"]?.string.flatMap(FeatureGuide.resolve) {
                self?.show(feature)
                return
            }
            if name == "motion_frames", !finished {
                self?.renderMotionFrames(input)
                return
            }
            guard let self, name == "security_report", let root = self.workspace?.url else { return }
            if finished {
                self.security.agentScanFinished(root: root)
            } else {
                self.area = .security
                self.security.agentScanStarted(by: claude?.engine.title ?? "Claude")
            }
        }
        claude.engine = Preferences.shared.agentEngine == .codex && Self.codexPath != nil && claude.remote == nil ? .codex : .claude
        applyClaudePreferences(to: claude)
        return claude
    }

    /// A job's conversation: the project's brief and rules, plus the job's own brief, run in
    /// the job's worktree.
    private func makeJobClaude(for job: JobRecord, in workspace: Workspace) -> ClaudeSession {
        let project = workspace.name
        let claude = ClaudeSession(
            root: job.worktreeURL,
            executable: SystemStatus.detect().claudePath,
            systemPrompt: { [weak workspace] in
                ClaudeBrief.systemPrompt(for: workspace) + "\n\n" + JobPlan.brief(for: job, project: project)
            },
            rules: { [weak workspace] in
                // A job type's paths say where its changes are expected; edits elsewhere get a
                // note, which away mode waits on.
                var rules = workspace?.claudeRules ?? ClaudeRules()
                if let scope = job.scope, !scope.isEmpty { rules.propose = scope }
                return rules
            }
        )
        claude.projectName = project
        // Keeps the board's change count current while the job edits.
        claude.onFileChanged = { [weak self] _ in self?.jobs.changesMayHaveChanged(job.id) }
        claude.onAttention = { [weak self] attention in
            self?.notifyClaude(attention, job: job.title)
            Task { await self?.jobs.refreshChanges(of: job.id) }
        }
        // Every job stays on its branch; away mode and its time decide the rest.
        claude.guardCall = { [weak self] tool, input, flagged in
            guard let record = self?.jobs.record(job.id) else { return nil }
            return JobGuard.verdict(for: record, toolName: tool, input: input, hasNote: flagged)
        }
        // A job making a motion piece looks at its own frames too.
        claude.onDanteTool = { [weak self] name, input, finished in
            if name == "open_file", !finished { self?.openAgentFile(input, root: job.worktreeURL); return }
            if name == "motion_frames", !finished { self?.renderMotionFrames(input, root: job.worktreeURL) }
        }
        claude.engine = job.engine == .codex && Self.codexPath != nil ? .codex : .claude
        applyClaudePreferences(to: claude)
        return claude
    }

    /// Settings Claude starts with; a change applies from the next message.
    func applyClaudePreferences(to claude: ClaudeSession? = nil) {
        guard let claude = claude ?? self.claude else { return }
        claude.automaticTaskRouting = Preferences.shared.automaticTaskRouting
        claude.routesToLocalModels = Preferences.shared.delegatesToLocalModels
        claude.asksFirst = Preferences.shared.claudeAsksFirst
        claude.requestedModel = Preferences.shared.claudeModel.argument
        claude.codexExecutable = Self.codexPath
        claude.switchesAtLimit = Preferences.shared.switchesToCodexAtLimit
        claude.codexModel = Preferences.shared.codexModel.isEmpty ? nil : Preferences.shared.codexModel
        claude.codexEffort = Preferences.shared.codexEffort.isEmpty ? nil : Preferences.shared.codexEffort
        // The dante MCP server carries local models, and Grok and Jev when they have keys.
        var environment = AgentKeys.environment()
        let local = Preferences.shared.delegatesToLocalModels
        if Preferences.shared.asksCodex, let codex = Self.codexPath {
            environment[DelegateEnvironment.codex] = codex
            if !Preferences.shared.codexModel.isEmpty { environment[DelegateEnvironment.codexModel] = Preferences.shared.codexModel }
        }
        if !Preferences.shared.lookerModel.isEmpty { environment[DelegateEnvironment.lookerModel] = Preferences.shared.lookerModel }
        if !Preferences.shared.grokModel.isEmpty, !environment.isEmpty { environment[DelegateEnvironment.grokModel] = Preferences.shared.grokModel }
        if !local { environment[DelegateEnvironment.local] = "0" }
        if Preferences.shared.checksDependenciesOnline { environment[DelegateEnvironment.securityOnline] = "1" }
        // The server always carries the Security page's scan; with Codex in charge, also Claude
        // for second opinions.
        claude.delegateCommand = Self.danteCommand
        // A job's tools file their work under the project, not the worktree's folder.
        if let project = claude.projectName { environment[DelegateEnvironment.project] = project }
        claude.delegateEnvironment = environment
        claude.ledger = .standard
        claude.approvalLevel = Preferences.shared.approvalLevel
    }

    /// The Codex CLI on this Mac, looked for once.
    static let codexPath: String? = Codex.locate()

    /// Whoever is in charge of this window's conversation, for labels: "Ask Codex".
    var agentName: String { claude?.engine.title ?? "Claude" }

    /// The bundled `dante` command, which also serves local models to Claude Code. Missing
    /// when running outside the app bundle.
    static let danteCommand: String? = {
        guard let url = Bundle.main.resourceURL?.appending(path: "bin/dante"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }()

    // MARK: Terminal tabs (methods in Session+Terminal.swift)
    var terminalTabs: [TerminalTab] = [TerminalTab()]
    var selectedTerminalID: UUID?

    // MARK: Back and forward

    /// Where the window is: the area, plus the doc or file it shows.
    struct Place: Equatable, Sendable {
        var area: Area
        var docPath: String?
        var file: URL?
    }

    var history = NavigationHistory<Place>()
    /// Where going back or forward landed, so that move isn't recorded as a new visit.
    private var restoredPlace: Place?

    var place: Place {
        Place(
            area: area,
            docPath: area == .docs ? docPath : nil,
            file: area == .code ? workspace?.activeDocument?.url : nil
        )
    }

    /// Called when `place` changes.
    func placeChanged(from previous: Place) {
        guard previous != place else { return }
        if restoredPlace == place {
            restoredPlace = nil
            return
        }
        restoredPlace = nil
        history.moved(from: previous)
    }

    func goBack() {
        if let target = history.goBack(from: place) { restore(target) }
    }

    func goForward() {
        if let target = history.goForward(from: place) { restore(target) }
    }

    private func restore(_ target: Place) {
        if let file = target.file {
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try? workspace?.open(file)
            } else {
                history.removeAll { $0.file == file }
            }
        }
        if let docPath = target.docPath { self.docPath = docPath }
        area = target.area
        restoredPlace = place
    }

    /// Types a command into the integrated terminal's front tab and runs it.
    func runInTerminal(_ command: String) {
        showsTerminal = true
        terminalInput = TerminalInput(text: command + "\n", tab: selectedTerminal)
    }

    /// Runs a long-lived command (a dev server) in a terminal tab of its own, so the one in
    /// front stays free and its output stays together.
    func runInNewTerminal(_ command: String, title: String) {
        var tab = TerminalTab()
        tab.title = title
        terminalTabs.append(tab)
        selectedTerminal = tab.id
        showsTerminal = true
        // The new shell drops input sent before it exists.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.terminalInput = TerminalInput(text: command + "\n", tab: tab.id)
        }
    }

    /// Types a command without running it, for ones the person should read first (installs).
    func typeInTerminal(_ command: String) {
        showsTerminal = true
        terminalInput = TerminalInput(text: command, tab: selectedTerminal)
    }

}

/// The project in the window used most recently, for the Settings window's project panes.
@MainActor
@Observable
final class ActiveProject {
    static let shared = ActiveProject()
    weak var session: Session?

    /// Follows the main window, once at launch.
    static func install() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if let session = Sessions.all.first(where: { $0.window === window }) { shared.session = session }
            }
        }
    }
}

/// Every open window's session, so app-wide events (quit) can reach them all.
@MainActor
enum Sessions {
    private final class Weak { weak var session: Session?; init(_ session: Session) { self.session = session } }
    private static var entries: [Weak] = []

    static func register(_ session: Session) {
        entries.removeAll { $0.session == nil }
        entries.append(Weak(session))
        PresenceController.shared.sessionsChanged()
    }

    static var all: [Session] { entries.compactMap(\.session) }
}
