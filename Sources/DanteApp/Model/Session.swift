import AppKit
import DanteEditor
import DanteKit
import Observation
import PDFKit
import UniformTypeIdentifiers

/// The areas in the workspace rail, one per screen in the design canvas.
enum Area: String, CaseIterable, Identifiable {
    case home, plan, map, code, tests, environments, data, ship, run, timeline, docs, spec

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .plan: "Plan"
        case .map: "Map"
        case .code: "Code"
        case .tests: "Tests"
        case .environments: "Env"
        case .data: "Data"
        case .ship: "Ship"
        case .run: "Run"
        case .timeline: "Timeline"
        case .docs: "Docs"
        case .spec: "Spec"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .plan: "checklist"
        case .map: "point.3.connected.trianglepath.dotted"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .tests: "testtube.2"
        case .environments: "shippingbox"
        case .data: "cylinder.split.1x2"
        case .ship: "paperplane"
        case .run: "waveform.path.ecg"
        case .timeline: "clock.arrow.circlepath"
        case .docs: "doc.text"
        case .spec: "book.closed"
        }
    }

    /// What the area is for, shown as the rail button's tooltip.
    var summary: String {
        switch self {
        case .home: "Where the project is: the current phase and its checklist, tasks, environment and docs at a glance."
        case .plan: "Phases, what “done” means in each, and a task board stored in .dante/tasks.yaml."
        case .map: "Architecture, process flows, data model and cloud diagrams generated from the code."
        case .code: "The editor, file explorer and terminal."
        case .tests: "Tests traced to specs and code paths, coverage by component, and tests Claude can draft."
        case .environments: "Docker Compose services with logs, shells and restarts, and Docker files Claude can write."
        case .data: "The project's databases: create one, browse tables, run queries and see the schema as a diagram."
        case .ship: "A release checklist, a changelog drafted from tasks and commits, and the CI pipeline."
        case .run: "Production metrics, errors and alarms, each linked back to a task."
        case .timeline: "Commits, releases, Claude sessions, test runs and CI in one stream, newest first."
        case .docs: "Specs and decisions as documents, with live diagrams and test status, in Paper mode."
        case .spec: "The .dante folder: lifecycle, phase checklists and what Claude may propose."
        }
    }

    static let main: [Area] = [.home, .plan, .map, .code, .tests, .environments, .data, .ship, .run, .timeline]
    static let footer: [Area] = [.docs, .spec]
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
    /// The phase Plan shows; nil follows the project's current phase.
    var planPhase: String?
    var showsTerminal = true
    var terminalHeight: Double = 240
    var showsClaude = true
    /// The command palette, when it's open.
    var palette: PaletteScope?
    /// Go to Symbol's scan of the project, for the workspace revision it was made at.
    @ObservationIgnored var symbolIndex: (revision: Int, symbols: [CodeSymbol])?

    /// Bumped when HEAD moves (a commit, checkout or reset), so views comparing against it reload.
    var gitRevision = 0

    enum Sidebar { case files, search, changes, problems }
    var sidebar: Sidebar = .files
    let search = SearchState()
    /// Source control: status, staging, commits, branches.
    let git = GitModel()
    /// The branch switcher in the title bar is open.
    var showsBranches = false
    /// The Finish Task sheet, while open.
    var finishing: FinishTaskModel?
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

    /// Opens Plan on a phase, as the title bar's ribbon does.
    func showPhase(_ phase: String) {
        planPhase = phase
        area = .plan
    }

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
    /// Files waiting to go with the next message to Claude.
    var claudeAttachments: [Attachment] = []
    var attachmentsLoading = 0
    var cursor = CursorPosition()
    var isCloning = false
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
        let workspace = Workspace(url: url)
        self.workspace = workspace
        loadSinceLastVisit(for: workspace)
        claude = makeClaude(for: workspace)
        languages = LanguageServices(root: url)
        conflicts = []
        terminalTabs = [TerminalTab()]
        history = NavigationHistory()
        workspace.refreshFileIndex()
        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] changed in self?.filesChanged(changed) }
        branch = Git.currentBranch(in: url)
        area = .code
        recents.note(url)
        if !workspace.lifecycle.hasSpec { offerSetup() }
    }

    // MARK: Project setup

    /// Shows the setup sheet for a project without `.dante/project.yaml` once Dante has
    /// looked at its files and history. Projects the user said "Not now" to are skipped
    /// unless `force` is set.
    var setupProfile: ProjectProfile?
    private static let declinedSetupKey = "declinedSetup"

    func offerSetup(force: Bool = false) {
        guard let workspace else { return }
        let root = workspace.url
        if !force, UserDefaults.standard.stringArray(forKey: Self.declinedSetupKey)?.contains(root.path) == true { return }
        Task {
            let paths = await Task.detached(priority: .userInitiated) { FileIndex.scan(root) }.value
            let commits = await Shell.run(["git", "rev-list", "--count", "HEAD"], in: root)
            let tags = await Shell.run(["git", "tag"], in: root)
            let profile = ProjectProfile.detect(
                paths: paths,
                commits: commits.status == 0 ? Int(commits.stdout) ?? 0 : 0,
                tags: tags.status == 0 ? tags.stdout.split(separator: "\n").count : 0,
                testCommand: TestCommand.detect(projectRoot: root)?.label,
                summary: Workspace.readmeSummary(in: root)
            ) { path in try? String(contentsOf: root.appending(path: path), encoding: .utf8) }
            guard self.workspace?.url == root else { return }
            setupProfile = profile
        }
    }

    func declineSetup() {
        guard let root = workspace?.url.path else { return }
        var declined = UserDefaults.standard.stringArray(forKey: Self.declinedSetupKey) ?? []
        if !declined.contains(root) { declined.append(root) }
        UserDefaults.standard.set(declined, forKey: Self.declinedSetupKey)
        setupProfile = nil
    }

    /// Writes the skeleton `.dante/` and, if any parts were picked, asks Claude to fill it in.
    func setUpProject(_ request: ProjectSetupRequest) {
        guard let workspace, let profile = setupProfile else { return }
        do {
            try workspace.setUp(with: request.template, current: request.phase)
        } catch {
            errorMessage = "Couldn’t create .dante/: \(error.localizedDescription)"
            return
        }
        setupProfile = nil
        area = .plan
        if !request.parts.isEmpty { askClaude(request.summary, instructions: request.prompt(profile: profile)) }
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
        applyClaudePreferences(to: claude)
        return claude
    }

    /// Settings Claude starts with; a change applies from the next message.
    func applyClaudePreferences(to claude: ClaudeSession? = nil) {
        guard let claude = claude ?? self.claude else { return }
        claude.asksFirst = Preferences.shared.claudeAsksFirst
        claude.requestedModel = Preferences.shared.claudeModel.argument
    }

    // MARK: Terminal tabs (methods in Session+Terminal.swift)
    var terminalTabs: [TerminalTab] = [TerminalTab()]
    var selectedTerminalID: UUID?

    // MARK: Back and forward

    /// Where the window is: the area, plus the doc, file or phase it shows.
    struct Place: Equatable, Sendable {
        var area: Area
        var docPath: String?
        var file: URL?
        var planPhase: String?
    }

    var history = NavigationHistory<Place>()
    /// Where going back or forward landed, so that move isn't recorded as a new visit.
    private var restoredPlace: Place?

    var place: Place {
        Place(
            area: area,
            docPath: area == .docs ? docPath : nil,
            file: area == .code ? workspace?.activeDocument?.url : nil,
            planPhase: area == .plan ? planPhase : nil
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
        if target.area == .plan { planPhase = target.planPhase }
        area = target.area
        restoredPlace = place
    }

    /// Types a command into the integrated terminal's front tab and runs it.
    func runInTerminal(_ command: String) {
        showsTerminal = true
        terminalInput = TerminalInput(text: command + "\n", tab: selectedTerminal)
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
    }

    static var all: [Session] { entries.compactMap(\.session) }
}
