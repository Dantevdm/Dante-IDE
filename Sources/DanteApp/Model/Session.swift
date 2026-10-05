import AppKit
import DanteEditor
import DanteKit
import Observation

/// The areas in the workspace rail. Code and Plan are built so far; the rest are
/// designed (see the design canvas) and land in later milestones.
enum Area: String, CaseIterable, Identifiable {
    case home, plan, map, code, tests, environments, ship, run, docs, spec

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .plan: "Plan"
        case .map: "Map"
        case .code: "Code"
        case .tests: "Tests"
        case .environments: "Env"
        case .ship: "Ship"
        case .run: "Run"
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
        case .ship: "paperplane"
        case .run: "waveform.path.ecg"
        case .docs: "doc.text"
        case .spec: "book.closed"
        }
    }

    var isBuilt: Bool { self == .code || self == .plan }

    /// What the screen will do, shown until it's built.
    var summary: String {
        switch self {
        case .home: "Where the project is: the current phase and its checklist, tasks, environment and docs at a glance."
        case .plan: "Phases, what “done” means in each, and a task board stored in .dante/tasks.yaml."
        case .map: "Architecture, process flows, data model and cloud diagrams generated from the code."
        case .code: ""
        case .tests: "Tests traced to specs and code paths, coverage by component, and tests Claude can draft."
        case .environments: "Docker Compose services with logs, shells and restarts, and Docker files Claude can write."
        case .ship: "A release checklist, a changelog drafted from tasks and commits, and the CI pipeline."
        case .run: "Production metrics, errors and alarms, each linked back to a task."
        case .docs: "Specs and decisions as documents, with live diagrams and test status, in Paper mode."
        case .spec: "The .dante folder: lifecycle, phase checklists and what Claude may propose."
        }
    }

    static let main: [Area] = [.home, .plan, .map, .code, .tests, .environments, .ship, .run]
    static let footer: [Area] = [.docs, .spec]
}

/// What the command palette searches. ⌘K opens it on everything, ⌘P on files.
enum PaletteScope: String, CaseIterable, Identifiable {
    case all = "All", files = "Files", docs = "Docs", actions = "Actions"
    var id: String { rawValue }
}

struct TerminalInput: Equatable {
    let id = UUID()
    let text: String
}

/// Everything one window shows: the open folder, the selected area and panel state.
@MainActor
@Observable
final class Session {
    let recents: RecentProjects
    private(set) var workspace: Workspace?
    private(set) var branch: String?
    private(set) var claude: ClaudeSession?
    private var watcher: DirectoryWatcher?
    /// Open files that changed on disk while they had unsaved edits.
    private(set) var conflicts: Set<URL> = []

    var area: Area = .code
    var showsTerminal = true
    var terminalHeight: Double = 240
    var showsClaude = true
    /// The command palette, when it's open.
    var palette: PaletteScope?
    var claudeWidth: Double = 380
    /// Text queued for the integrated terminal's shell.
    private(set) var terminalInput: TerminalInput?
    /// Bumped to move keyboard focus to Claude's message box.
    var claudeFocusRequest = 0
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
        claude?.stop()
        let workspace = Workspace(url: url)
        self.workspace = workspace
        claude = makeClaude(for: workspace)
        conflicts = []
        workspace.refreshFileIndex()
        watcher?.stop()
        watcher = DirectoryWatcher(url: url) { [weak self] changed in self?.filesChanged(changed) }
        branch = Git.currentBranch(in: url)
        area = .code
        recents.note(url)
    }

    func closeProject() {
        guard confirmDiscardingChanges(in: workspace?.documents ?? []) else { return }
        claude?.stop()
        claude = nil
        watcher?.stop()
        watcher = nil
        palette = nil
        workspace = nil
        branch = nil
    }

    private func filesChanged(_ changed: [URL]) {
        guard let workspace else { return }
        let result = workspace.applyExternalChanges(changed)
        if result.gitHeadChanged { refreshBranch() }
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
        return claude
    }

    /// Types a command into the integrated terminal and runs it.
    func runInTerminal(_ command: String) {
        showsTerminal = true
        terminalInput = TerminalInput(text: command + "\n")
    }

    /// Starts Claude Code's sign-in in the terminal; the next message starts a fresh session.
    func signInToClaude() {
        guard let claude, let executable = claude.executable else { return }
        claude.reset()
        runInTerminal("'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' auth login")
    }

    func focusClaude() {
        showsClaude = true
        claudeFocusRequest += 1
    }

    /// Sends a message to Claude with what's on screen as context.
    func askClaude(_ text: String) {
        guard let claude, let workspace else { return }
        showsClaude = true
        claude.send(text, context: ClaudeBrief.context(workspace: workspace, line: cursor.line))
    }

    // MARK: Files

    func open(file url: URL) {
        guard let workspace else { return }
        do {
            try workspace.open(url)
            area = .code
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveActive() {
        guard let document = workspace?.activeDocument else { return }
        save(document)
    }

    func saveAll() {
        workspace?.documents.filter(\.isDirty).forEach(save)
    }

    func save(_ document: EditorDocument) {
        do {
            try document.save()
            conflicts.remove(document.url)
            if document.url.path.contains("/.dante/") { workspace?.reloadSpec() }
        } catch {
            errorMessage = "Couldn’t save \(document.name): \(error.localizedDescription)"
        }
    }

    func close(_ document: EditorDocument) {
        guard confirmDiscardingChanges(in: [document]) else { return }
        workspace?.close(document)
    }

    func closeActiveTab() {
        if let document = workspace?.activeDocument {
            close(document)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func selectTab(offset: Int) {
        guard let workspace, !workspace.documents.isEmpty else { return }
        let index = workspace.documents.firstIndex { $0.id == workspace.activeDocumentID } ?? 0
        let next = (index + offset + workspace.documents.count) % workspace.documents.count
        workspace.activeDocumentID = workspace.documents[next].id
    }

    /// Asks before throwing away unsaved edits. Returns false if the user cancels.
    private func confirmDiscardingChanges(in documents: [EditorDocument]) -> Bool {
        Self.confirmDiscardingChanges(in: documents, save: save)
    }

    /// Asks before throwing away unsaved edits. Returns false if the user cancels or a save fails.
    static func confirmDiscardingChanges(in documents: [EditorDocument], save: (EditorDocument) -> Void) -> Bool {
        let dirty = documents.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Save changes to \(dirty[0].name)?"
            : "Save changes to \(dirty.count) files?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            dirty.forEach(save)
            return dirty.allSatisfy { !$0.isDirty }
        case .alertThirdButtonReturn:
            return true
        default:
            return false
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
    }

    static var all: [Session] { entries.compactMap(\.session) }
}
