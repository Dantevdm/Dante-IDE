import AppKit
import DanteEditor
import DanteKit
import Observation
import PDFKit
import UniformTypeIdentifiers

/// The areas in the workspace rail, one per screen in the design canvas.
enum Area: String, CaseIterable, Identifiable {
    case home, map, code, tests, environments, data, ship, run, timeline, claude, agents, docs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .map: "Map"
        case .code: "Code"
        case .tests: "Tests"
        case .environments: "Env"
        case .data: "Data"
        case .ship: "Ship"
        case .run: "Run"
        case .timeline: "Timeline"
        case .claude: "Claude"
        case .agents: "Agents"
        case .docs: "Docs"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .map: "point.3.connected.trianglepath.dotted"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .tests: "testtube.2"
        case .environments: "shippingbox"
        case .data: "cylinder.split.1x2"
        case .ship: "paperplane"
        case .run: "waveform.path.ecg"
        case .timeline: "clock.arrow.circlepath"
        case .claude: "sparkle"
        case .agents: "circle.hexagongrid"
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
        case .environments: "Docker Compose services with logs, shells and restarts, and Docker files Claude can write."
        case .data: "The project's databases: create one, browse tables, run queries and see the schema as a diagram."
        case .ship: "A release checklist, a changelog drafted from commits, and the CI pipeline."
        case .run: "Production metrics, errors and alarms."
        case .timeline: "Commits, releases, Claude sessions, test runs and CI in one stream, newest first."
        case .claude: "How Claude works on this project: usage, skills, memory, connectors and permissions."
        case .agents: "Claude and the local models it delegates to: jobs, tokens kept local and how each agent is doing."
        case .docs: "Specs and decisions as documents, with live diagrams and test status, in Paper mode."
        }
    }

    static let main: [Area] = [.home, .map, .code, .tests, .environments, .data, .ship, .run, .timeline, .claude, .agents]
    static let footer: [Area] = [.docs]
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
    /// Language servers for the open project's files.
    private(set) var languages: LanguageServices?
    private var watcher: DirectoryWatcher?
    /// Open files that changed on disk while they had unsaved edits.
    var conflicts: Set<URL> = []

    var area: Area = .code
    var showsTerminal = true
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
        applyClaudePreferences(to: claude)
        return claude
    }

    /// Settings Claude starts with; a change applies from the next message.
    func applyClaudePreferences(to claude: ClaudeSession? = nil) {
        guard let claude = claude ?? self.claude else { return }
        claude.asksFirst = Preferences.shared.claudeAsksFirst
        claude.requestedModel = Preferences.shared.claudeModel.argument
        // The dante MCP server carries local models, and Grok and Jev when they have keys.
        var environment = AgentKeys.environment()
        let local = Preferences.shared.delegatesToLocalModels
        if !environment.isEmpty {
            if !local { environment[DelegateEnvironment.local] = "0" }
            if !Preferences.shared.grokModel.isEmpty { environment[DelegateEnvironment.grokModel] = Preferences.shared.grokModel }
        }
        claude.delegateCommand = local || !environment.isEmpty ? Self.danteCommand : nil
        claude.delegateEnvironment = environment
        claude.ledger = .standard
        claude.approvalLevel = Preferences.shared.approvalLevel
    }

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
