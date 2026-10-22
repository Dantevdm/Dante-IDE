import AppKit
import DanteKit
import Foundation
import UserNotifications

/// A window's pipelines: Azure DevOps (through its REST API with a token from the Keychain)
/// or GitHub Actions (through gh). Polled while the project is open, every 20 s while a run
/// is going and every 90 s otherwise; history is kept per Mac; a start or finish notifies;
/// a failed run can be healed by the agent and its failed stage run again.
@MainActor @Observable
final class PipelineMonitor {
    enum Source: Equatable {
        case azure(AzureDevOpsRemote)
        case github
    }

    private(set) var source: Source?
    private(set) var history = PipelineHistory()
    /// Why nothing can be read: no token yet, a refused token, no gh…
    private(set) var problem: String?
    /// Nobody is signed in to Azure DevOps (no Microsoft sign-in and no token), or it was refused.
    private(set) var needsToken = false
    /// The project has Azure DevOps pipeline files but its code isn't there, so Dante needs a
    /// pipeline's link to know which to read.
    private(set) var wantsLink = false
    private(set) var signingIn = false
    private(set) var checked: Date?
    private(set) var loading = false
    /// What failed in a run, read on demand (with the logs) for its card and the heal brief.
    private(set) var failures: [Int: [PipelineFailure]] = [:]
    private(set) var retrying: Set<Int> = []
    var autoHeals = false { didSet { saveAutoHeal() } }

    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var hasPipelineFiles = false
    @ObservationIgnored weak var session: Session?
    /// Runs auto-heal already acted on, so a failure starts one job or one re-run, never a loop.
    @ObservationIgnored private var handled: Set<Int> = []
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?

    var runs: [PipelineRun] { history.runs }
    var isActive: Bool { runs.contains { $0.status.isActive } }
    var hasPipelines: Bool { source != nil && (hasPipelineFiles || !runs.isEmpty) }

    /// Runs for as long as the window shows the project (the caller's task is cancelled when it closes).
    func watch(_ root: URL) async {
        self.root = root
        history = PipelineHistory.load(for: root)
        failures = [:]
        handled = Set(history.runs.map(\.id))
        autoHeals = (UserDefaults.standard.stringArray(forKey: Self.autoHealKey) ?? []).contains(root.standardizedFileURL.path)
        await detect(root)
        while !Task.isCancelled, self.root == root {
            if source != nil { await refresh() }
            let seconds = isActive ? 20.0 : 90.0
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
                group.addTask { await self.waitForWake() }
                await group.next()
                group.cancelAll()
                self.wake?.resume()
                self.wake = nil
            }
        }
    }

    private func waitForWake() async {
        await withCheckedContinuation { continuation in wake = continuation }
    }

    /// Looks now rather than at the next tick.
    func refreshNow() {
        wake?.resume()
        wake = nil
    }

    private func detect(_ root: URL) async {
        let remote = await Shell.run(["git", "remote", "get-url", "origin"], in: root).stdout
        let files = Self.pipelineFiles(in: root)
        wantsLink = false
        if let linked = Self.linked(Self.links(for: root)) {
            source = .azure(linked)
            hasPipelineFiles = true
        } else if let azure = AzureDevOpsRemote.parse(remote) {
            source = .azure(azure)
            hasPipelineFiles = !files.azure.isEmpty
        } else if !files.azure.isEmpty {
            source = nil
            wantsLink = true
        } else if !files.github.isEmpty {
            source = .github
            hasPipelineFiles = true
        } else {
            source = nil
        }
    }

    static func pipelineFiles(in root: URL) -> (azure: [String], github: [String]) {
        let github = CIRun.hasWorkflows(projectRoot: root) ? [".github/workflows"] : []
        var azure: [String] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                if ["node_modules", "build", "dist", ".build", "vendor"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                let name = url.lastPathComponent.lowercased()
                if (name.hasPrefix("azure-pipelines") || url.path.contains("/azure-devops/")) && (name.hasSuffix(".yml") || name.hasSuffix(".yaml")) {
                    azure.append(url.path)
                }
                if azure.count > 20 { break }
            }
        }
        return (azure, github)
    }

    // MARK: Looking

    func refresh() async {
        guard let root, let source else { return }
        loading = true
        defer { loading = false }
        let fresh: [PipelineRun]
        switch source {
        case .azure(let remote):
            guard let client = await client(remote) else {
                needsToken = true
                problem = nil
                return
            }
            do {
                var runs = try await client.runs()
                // Stages for what's running and what finished without them yet.
                for index in runs.indices.prefix(8) where runs[index].status.isActive || history.runs.first(where: { $0.id == runs[index].id })?.stages.isEmpty ?? true {
                    if let timeline = try? await client.timeline(of: runs[index].id) {
                        runs[index].stages = timeline.stages
                        if runs[index].status == .failed, failures[runs[index].id] == nil { failures[runs[index].id] = timeline.failures }
                    }
                }
                fresh = runs
                problem = nil
                needsToken = false
            } catch {
                problem = error.message
                needsToken = error == .unauthorised
                return
            }
        case .github:
            switch await CIRun.load(projectRoot: root, limit: 30) {
            case .success(let runs):
                fresh = runs.map(PipelineRun.init)
                problem = nil
            case .failure(.noGitHubCLI):
                problem = "Needs the GitHub CLI, signed in (gh auth login)."
                return
            case .failure(.noWorkflows):
                problem = nil
                return
            case .failure(.failed(let message)):
                problem = message
                return
            }
        }
        guard self.root == root else { return }
        let events = history.events(after: fresh)
        history = history.merging(fresh)
        history.save(for: root)
        checked = .now
        for event in events { announce(event) }
    }

    /// A saved token wins (it was chosen for this organisation), else the Microsoft sign-in.
    private func client(_ remote: AzureDevOpsRemote) async -> AzureDevOpsClient? {
        if let token = PipelineTokens.token(for: remote.organization) { return AzureDevOpsClient(remote: remote, token: token) }
        if let bearer = await MicrosoftAccount.accessToken() { return AzureDevOpsClient(remote: remote, bearer: bearer) }
        return nil
    }

    /// Signs in with Microsoft in the browser, then looks.
    func signIn() async {
        signingIn = true
        defer { signingIn = false }
        switch await MicrosoftSignIn.signIn(open: { url in Task { @MainActor in NSWorkspace.shared.open(url) } }) {
        case .success:
            needsToken = false
            problem = nil
            refreshNow()
        case .failure(let failure):
            problem = failure.message
        }
    }

    func signOut() {
        MicrosoftAccount.signOut()
        needsToken = true
    }

    // MARK: Links

    static func linksKey(_ root: URL) -> String { "pipelineLinks." + root.standardizedFileURL.path }

    static func links(for root: URL) -> [String] { UserDefaults.standard.stringArray(forKey: linksKey(root)) ?? [] }

    /// The pipelines the links name, when they're all in one project.
    static func linked(_ links: [String]) -> AzureDevOpsRemote? {
        let remotes = links.compactMap(AzureDevOpsRemote.link)
        guard let first = remotes.first else { return nil }
        return remotes.dropFirst().reduce(first) { merged, next in
            next.organization.lowercased() == merged.organization.lowercased() && next.project.lowercased() == merged.project.lowercased()
                ? merged.adding(next) : merged
        }
    }

    /// Adds a pipeline (or run) link for this project on this Mac. A run's link is turned into
    /// its pipeline once Dante can ask Azure DevOps. Returns why it can't, if it can't.
    func addLink(_ text: String) async -> String? {
        guard let root else { return nil }
        guard var remote = AzureDevOpsRemote.link(text) else { return "That isn't an Azure DevOps link. Copy it from the pipeline's page in the browser." }
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if remote.definitions.isEmpty, let run = AzureDevOpsRemote.linkedRun(link) {
            guard let client = await client(remote) else {
                needsToken = true
                return "Sign in first, so Dante can find which pipeline that run belongs to."
            }
            do {
                guard let pipeline = try await client.pipeline(ofRun: run) else { return "Azure DevOps didn't say which pipeline that run belongs to." }
                remote.definitions = [pipeline]
                link = remote.base.appending(path: "_build").absoluteString + "?definitionId=\(pipeline)"
            } catch {
                return error.message
            }
        }
        var links = Self.links(for: root)
        if !links.contains(link) { links.append(link) }
        UserDefaults.standard.set(links, forKey: Self.linksKey(root))
        await detect(root)
        refreshNow()
        return nil
    }

    func forgetLinks() {
        guard let root else { return }
        UserDefaults.standard.removeObject(forKey: Self.linksKey(root))
        Task { await detect(root); refreshNow() }
    }

    var hasLinks: Bool { root.map { !Self.links(for: $0).isEmpty } ?? false }

    func saveToken(_ token: String) {
        guard case .azure(let remote) = source else { return }
        PipelineTokens.set(token, for: remote.organization)
        needsToken = false
        problem = nil
        refreshNow()
    }

    func forgetToken() {
        guard case .azure(let remote) = source else { return }
        PipelineTokens.set(nil, for: remote.organization)
        needsToken = true
    }

    /// What failed in a run, with the end of each failed step's log.
    func loadFailures(_ run: PipelineRun) async -> [PipelineFailure] {
        if let known = failures[run.id], known.allSatisfy({ !$0.log.isEmpty || $0.logURL == nil }) { return known }
        guard case .azure(let remote) = source, let client = await client(remote) else { return failures[run.id] ?? [] }
        var found: [PipelineFailure]
        if let known = failures[run.id] { found = known } else { found = (try? await client.timeline(of: run.id))?.failures ?? [] }
        for index in found.indices.prefix(4) {
            if let url = found[index].logURL, found[index].log.isEmpty, let log = try? await client.log(url) { found[index].log = log }
        }
        failures[run.id] = found
        return found
    }

    // MARK: Acting

    /// Runs the failed stage again (Azure) or the failed jobs (GitHub). Production asks first,
    /// in the view; this only acts.
    func retry(_ run: PipelineRun) async {
        guard let root, let source else { return }
        retrying.insert(run.id)
        defer { retrying.remove(run.id) }
        switch source {
        case .azure(let remote):
            guard let client = await client(remote) else { return }
            guard let stage = run.failedStage ?? run.stages.last(where: { $0.state == .canceled }) else {
                session?.errorMessage = "Dante can't tell which stage to run again; re-run it from Azure DevOps."
                return
            }
            do { try await client.retry(run: run.id, stage: stage.identifier) } catch {
                session?.errorMessage = "Azure DevOps didn't run \(stage.name) again: \(error.message)"
                return
            }
        case .github:
            let result = await Shell.run(["gh", "run", "rerun", "\(run.id)", "--failed"], in: root)
            if result.status != 0 {
                session?.errorMessage = "gh didn't re-run it: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                return
            }
        }
        failures[run.id] = nil
        refreshNow()
    }

    /// Hands the failure to the agent in charge: in a job of its own when jobs can run here,
    /// else in the main conversation.
    func heal(_ run: PipelineRun) async {
        guard let session else { return }
        let found = await loadFailures(run)
        let brief = PipelineHeal.brief(run, failures: found, github: source == .github)
        if session.jobs.unavailable == nil {
            session.startJob(brief, engine: Preferences.shared.agentEngine, reportsFailure: true)
        } else {
            session.askClaude(brief)
        }
    }

    // MARK: Telling

    private func announce(_ event: PipelineHistory.Event) {
        let run: PipelineRun
        let title: String
        switch event {
        case .started(let started):
            run = started
            title = "\(started.pipeline) started"
        case .finished(let finished):
            run = finished
            title = "\(finished.pipeline) \(finished.status.title.lowercased())"
            if finished.status == .failed { autoHeal(finished) }
        }
        guard Preferences.shared.notifiesOnPipelines, let root else { return }
        let content = UNMutableNotificationContent()
        content.title = (run.environment == .prod ? "Prod: " : "") + title
        content.subtitle = root.lastPathComponent
        content.body = [run.branch, run.reason.isEmpty ? nil : "started by \(run.reason)", run.requestedBy.isEmpty ? nil : run.requestedBy]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        if case .finished(let finished) = event, finished.status == .failed || finished.environment == .prod { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pipeline-\(run.id)", content: content, trigger: nil))
    }

    /// With auto-heal on, a failed non-prod run that looks like a flake runs again once, and
    /// one that doesn't gets a heal job. Production is never touched without you.
    private func autoHeal(_ run: PipelineRun) {
        guard autoHeals, run.environment != .prod, !handled.contains(run.id) else { return }
        handled.insert(run.id)
        Task {
            let found = await loadFailures(run)
            if !found.isEmpty, found.allSatisfy(\.looksTransient), !run.stages.isEmpty || source == .github {
                await retry(run)
            } else {
                await heal(run)
            }
        }
    }

    private static let autoHealKey = "pipelinesAutoHeal"

    private func saveAutoHeal() {
        guard let path = root?.standardizedFileURL.path else { return }
        var saved = Set(UserDefaults.standard.stringArray(forKey: Self.autoHealKey) ?? [])
        if autoHeals { saved.insert(path) } else { saved.remove(path) }
        UserDefaults.standard.set(saved.sorted(), forKey: Self.autoHealKey)
    }
}
