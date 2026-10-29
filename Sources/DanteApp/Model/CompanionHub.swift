import AppKit
import DanteCore
import DanteKit
import DanteOpen
import Foundation

/// The companion server for the whole app (docs/plans/walk-and-work.md, step 4): off until
/// turned on in Settings › Agents, it listens on this Mac's tailnet address, sends paired
/// devices every window's conversations, jobs and waiting approvals (looked at once a second,
/// sent when they change), and carries out what the devices send: messages, answers, new jobs and stops.
@MainActor @Observable
final class CompanionHub {
    static let shared = CompanionHub()

    private(set) var state: CompanionServer.State = .stopped
    private(set) var devices: [CompanionServer.Device] = []
    /// What the QR code carries, while listening.
    private(set) var pairing: CompanionPairing?
    /// Why it can't listen: no Tailscale address.
    private(set) var problem: String?

    @ObservationIgnored private var server: CompanionServer?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var speakingDevices: Set<String> = []
    @ObservationIgnored private var companionActivity: NSObjectProtocol?
    @ObservationIgnored private var serverGeneration = UUID()

    var isOn: Bool { Preferences.shared.companionEnabled }

    func install() {
        if isOn { start() }
    }

    func setOn(_ on: Bool) {
        Preferences.shared.companionEnabled = on
        on ? start() : stop()
    }

    func start() {
        stop()
        guard let host = CompanionAddress.listening() else {
            problem = "No Tailscale address on this Mac. Install Tailscale on the Mac and the phone, sign both in, then try again."
            return
        }
        problem = nil
        let name = Host.current().localizedName ?? "Mac"
        let key = CompanionKey.current()
        pairing = CompanionPairing(host: host, port: Companion.defaultPort, name: name, key: key)
        let server = CompanionServer(host: host, port: Companion.defaultPort, name: name, key: key,
                                     onState: Self.stateHandler(serverGeneration), onDevices: Self.devicesHandler(serverGeneration),
                                     onMessage: Self.messageHandler(serverGeneration))
        self.server = server
        server.setNaturalVoiceAvailable(NaturalSpeaker.shared.isAvailable)
        server.start()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.publish()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        serverGeneration = UUID()
        ticker?.cancel()
        ticker = nil
        server?.stop()
        server = nil
        pairing = nil
        devices = []
        state = .stopped
        updateActivity()
    }

    /// A new key: every paired device has to scan the code again.
    func unpairAll() {
        CompanionKey.renew()
        if server != nil { start() }
    }

    // Closures the server calls on its own queue are made here, outside the main actor.
    private nonisolated static func stateHandler(_ generation: UUID) -> @Sendable (CompanionServer.State) -> Void {
        { state in Task { @MainActor in
            guard CompanionHub.shared.serverGeneration == generation else { return }
            CompanionHub.shared.state = state
        } }
    }

    private nonisolated static func devicesHandler(_ generation: UUID) -> @Sendable ([CompanionServer.Device]) -> Void {
        { devices in Task { @MainActor in
            let hub = CompanionHub.shared
            guard hub.serverGeneration == generation, hub.server != nil else { return }
            let firstDevice = hub.devices.isEmpty && !devices.isEmpty
            hub.devices = devices
            hub.updateActivity()
            if firstDevice { NaturalSpeaker.shared.prewarm() }
        } }
    }

    /// A remote session is user-initiated work even when every Mac window is hidden.
    /// Keep the system and app responsive, but let the display switch off normally.
    private func updateActivity() {
        if !devices.isEmpty, companionActivity == nil {
            companionActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                                      reason: "Serving a connected Dante companion")
        } else if devices.isEmpty, let activity = companionActivity {
            ProcessInfo.processInfo.endActivity(activity)
            companionActivity = nil
        }
    }

    private nonisolated static func messageHandler(_ generation: UUID) -> @Sendable (String, ClientMessage) -> Void {
        { device, message in Task { @MainActor in
            guard CompanionHub.shared.serverGeneration == generation else { return }
            CompanionHub.shared.handle(message, from: device)
        } }
    }

    // MARK: Snapshot

    private func publish() {
        // Also with no device yet, so a device's welcome already carries everything.
        server?.publish(snapshot())
        server?.setNaturalVoiceAvailable(NaturalSpeaker.shared.isAvailable)
    }

    func snapshot() -> CompanionSnapshot {
        let projects = Sessions.all.compactMap { session -> CompanionSnapshot.Project? in
            guard let workspace = session.workspace else { return nil }
            let jobs = session.jobs.open.map { job in
                CompanionSnapshot.Job(job, phase: session.jobs.phase(of: job.id),
                                      lastReply: TranscriptItem.lastReply(in: session.jobs.sessions[job.id]?.items ?? []))
            }
            let working = session.claude?.state == .working
            return CompanionSnapshot.Project(id: CompanionSnapshot.Project.id(for: workspace.url), name: workspace.url.lastPathComponent,
                                             lead: session.agentName, working: working,
                                             lastReply: CompanionSnapshot.Job.trimmed(TranscriptItem.lastReply(in: session.claude?.items ?? [])),
                                             jobs: jobs, approvals: session.inbox.map(CompanionSnapshot.Approval.init),
                                             approvalMode: session.claude.flatMap { CompanionApprovalMode(rawValue: $0.approvalLevel.rawValue) })
        }
        let open = Set(projects.map(\.id))
        let recent = recentProjects().filter { !open.contains($0.id) }.map { CompanionSnapshot.Recent(id: $0.id, name: $0.url.lastPathComponent) }
        let hands = HandsController.shared
        let waitingStep = projects.lazy.flatMap(\.approvals).first(where: \.isHands)
        let atWork: CompanionSnapshot.HandsAtWork? = if let waitingStep {
            .init(agent: hands.agent, step: waitingStep.title)
        } else if hands.visible {
            .init(agent: hands.agent, step: hands.lastStep)
        } else {
            nil
        }
        return CompanionSnapshot(server: pairing?.name ?? "Mac", projects: projects, recent: recent, hands: atWork)
    }

    /// This Mac's recent projects that still exist, with their companion ids.
    private func recentProjects() -> [(id: String, url: URL)] {
        RecentProjects().items
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { (CompanionSnapshot.Project.id(for: $0.url), $0.url) }
    }

    // MARK: Exploring

    /// Files of recent projects that aren't open, scanned once a minute at most.
    @ObservationIgnored private var scanned: [URL: (date: Date, files: [String])] = [:]

    /// A project's folder and files, open or recent, without opening a window.
    private func files(of project: String) async -> (URL, [String])? {
        if let session = session(project), let workspace = session.workspace { return (workspace.url, workspace.files) }
        guard let root = recentProjects().first(where: { $0.id == project })?.url else { return nil }
        if let cached = scanned[root], Date().timeIntervalSince(cached.date) < 60 { return (root, cached.files) }
        let files = await Task.detached { FileIndex.scan(root) }.value
        scanned[root] = (Date(), files)
        return (root, files)
    }

    private func explore(_ project: String, device: String, id: String, _ make: @escaping (URL, [String]) async -> ServerMessage) {
        Task {
            guard let (root, files) = await files(of: project) else {
                server?.reply(to: device, id: id, ok: false, message: "That project isn’t on the Mac any more.")
                return
            }
            server?.deliver(await make(root, files), to: device)
        }
    }

    // MARK: Acting

    private func session(_ project: String) -> Session? {
        Sessions.all.first { $0.workspace.map { CompanionSnapshot.Project.id(for: $0.url) } == project }
    }

    /// Opens a recent project in a window of its own. Nil when asked, else why not.
    private func open(_ project: String) -> String? {
        guard let url = recentProjects().first(where: { $0.id == project })?.url else { return "That project isn’t on the Mac any more." }
        guard let openWindow = Opener.openWindow else { return "Open Dante’s window on the Mac once, then try again." }
        Opener.handle(OpenRequest(items: [.init(path: url.path)], key: JobRequest.localKey()).url, from: nil, openWindow: openWindow)
        return nil
    }

    /// The project's window, opening it first when it's only a recent one; waits up to 15 s
    /// for its conversation.
    private func opened(_ project: String) async -> Session? {
        if let session = session(project), session.claude != nil { return session }
        if session(project) == nil, open(project) != nil { return nil }
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            if let session = session(project), session.claude != nil { return session }
        }
        return nil
    }

    /// Does `work` in the project once it's open, telling the device if it couldn't be opened.
    private func whenOpen(_ project: String, device: String, id: String, _ work: @escaping (Session) -> Void) {
        Task {
            guard let session = await opened(project) else {
                server?.reply(to: device, id: id, ok: false, message: "Couldn’t open that project on the Mac.")
                return
            }
            work(session)
            publish()
        }
    }

    private func handle(_ message: ClientMessage, from device: String) {
        if case .speech(let id, let text) = message {
            // One bounded synthesis per device; the phone queues the rest locally.
            guard let server else { return }
            guard !text.isEmpty, text.count <= SpeechQueue.chunkLimit,
                  speakingDevices.count < CompanionServer.maximumClients,
                  speakingDevices.insert(device).inserted else {
                server.speech(to: device, id: id, audio: nil)
                return
            }
            Task {
                defer { speakingDevices.remove(device) }
                let audio = await NaturalSpeaker.shared.companionAudio(text)
                server.speech(to: device, id: id, audio: audio)
            }
            return
        }
        switch message {
        case .library(let id, let project):
            explore(project, device: device, id: id) { root, files in
                .library(id: id, library: await CompanionRenderer.library(project: project, root: root, files: files))
            }
            return
        case .page(let id, let project, let request):
            explore(project, device: device, id: id) { root, files in
                .page(id: id, page: await CompanionRenderer.page(request, root: root, files: files))
            }
            return
        case .briefing(let id, let fresh):
            Task { [weak self] in
                let briefing = await Briefings.shared.make(fresh: fresh)
                self?.server?.deliver(.briefing(id: id, briefing: briefing), to: device)
            }
            return
        case .place(let id, let project, let kind):
            explore(project, device: device, id: id) { root, _ in
                let input = await CompanionPlaces.gather(project: project, name: root.lastPathComponent, root: root)
                return .place(id: id, place: CompanionPlaces.make(kind, input))
            }
            return
        case .screen(let id, let width):
            // Asked for by the paired device while its screen view is open; never kept.
            Task { [weak self] in
                let image = await Hands.screenJPEG(maxPixels: min(max(width ?? 1600, 400), 2400))
                self?.server?.deliver(.screen(id: id, image: image), to: device)
            }
            return
        case .git(let id, let project, let action):
            Task { [weak self] in
                guard let self else { return }
                guard let session = await opened(project), let root = session.workspace?.url else {
                    server?.reply(to: device, id: id, ok: false, message: "Couldn’t open that project on the Mac.")
                    return
                }
                let git = await Self.git(action, in: session, root: root)
                server?.deliver(.git(id: id, git: git), to: device)
                if action.changes { publish() }
            }
            return
        case .stopAll(let id):
            let stopped = Self.stopEverything()
            server?.reply(to: device, id: id, ok: true, message: stopped == 0 ? "Nothing was running." : "Stopped \(stopped == 1 ? "one conversation" : "\(stopped) conversations").")
            publish()
            return
        case .stopHands(let id):
            HandsController.shared.stop()
            server?.reply(to: device, id: id, ok: true, message: "Hands stopped and turned off.")
            publish()
            return
        case .replyMail(let id, let who, let says):
            Task { [weak self] in
                let said = await MailReplies.draft(MailReply(who: who, says: says))
                self?.server?.reply(to: device, id: id, ok: said.contains("is open in Outlook"), message: said)
            }
            return
        default:
            break
        }
        guard let id = message.id else { return }
        // A message for a recent project that isn't open opens it first.
        switch message {
        case .ask(_, let project, nil, let text, let spoken) where session(project) == nil:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { break }
            if let reason = open(project) { server?.reply(to: device, id: id, ok: false, message: reason); return }
            server?.reply(to: device, id: id, ok: true, message: "Opening it on the Mac.")
            if spoken { NaturalSpeaker.shared.prewarm() }
            whenOpen(project, device: device, id: id) { $0.askClaude(trimmed, instructions: spoken ? SpokenReply.conversationInstructions : nil) }
            return
        case .startJob(_, let project, let brief, let awayMinutes) where session(project) == nil:
            if let reason = open(project) { server?.reply(to: device, id: id, ok: false, message: reason); return }
            server?.reply(to: device, id: id, ok: true, message: "Opening it on the Mac.")
            whenOpen(project, device: device, id: id) { session in
                if session.jobs.unavailable == nil {
                    session.startJob(brief, engine: Preferences.shared.agentEngine, awayMinutes: awayMinutes, reportsFailure: true)
                }
            }
            return
        default:
            break
        }
        let result = act(on: message)
        server?.reply(to: device, id: id, ok: result == nil, message: result ?? "Done.")
        publish()
    }

    /// Does what the device asked through the window's own git model (so the Changes panel on
    /// the Mac follows along) and reads the repository back.
    private static func git(_ action: CompanionGitAction, in session: Session, root: URL) async -> CompanionGit {
        let git = session.git
        await git.load(root)
        if git.branches.isEmpty { await git.loadBranches() }
        func changes(_ paths: [String]) -> [GitStatus.Change] {
            let wanted = Set(paths)
            return git.status?.changes.filter { wanted.contains($0.path) } ?? []
        }
        var diff: CompanionGit.Diff?
        switch action {
        case .status:
            break
        case .diff(let path, let staged):
            let change = git.status?.changes.first { $0.path == path } ?? GitStatus.Change(path: path)
            diff = CompanionGit.diff(await GitRepository.diff(of: change, staged: staged, in: root), path: path, staged: staged)
        case .stage(let paths):
            await git.stage(changes(paths))
        case .unstage(let paths):
            await git.unstage(changes(paths))
        case .discard(let paths):
            await git.discard(changes(paths))
        case .writeMessage:
            await git.writeMessage(tasks: [])
        case .commit(let message, let push):
            git.message = message
            if git.canCommit {
                await git.commit(thenPush: push)
            } else {
                git.error = GitRepository.Failure(message: git.status?.conflicted.isEmpty == false ? "Resolve the conflicts on the Mac first." : "There’s nothing to commit.")
            }
        case .push:
            await git.push()
        case .pull:
            await git.pull()
        case .fetch:
            await git.fetch()
        case .checkout(let name, let isRemote):
            if let branch = git.branches.first(where: { $0.name == name && $0.isRemote == isRemote }) {
                await git.checkout(branch)
            } else {
                git.error = GitRepository.Failure(message: "There’s no branch called \(name).")
            }
        case .createBranch(let name):
            if GitBranch.isValidName(name) {
                await git.createBranch(name)
            } else {
                git.error = GitRepository.Failure(message: "“\(name)” can’t be a branch name.")
            }
        }
        if action.changes { await git.loadBranches() }
        let commits = await CompanionGit.recentCommits(in: root)
        let operation = git.operation.map { $0.kind.rawValue }
        return CompanionGit.make(status: git.status, branches: git.branches, commits: commits, operation: operation,
                                 message: git.message, warning: git.messageWarning, notice: git.notice, failure: git.error, diff: diff)
    }

    /// Every working conversation and job in every window stops; a Hands step under way is
    /// refused at once (the stop flag), and Hands come back on a moment later if they were on.
    static func stopEverything() -> Int {
        let handsOn = Preferences.shared.handsEnabled
        if handsOn { Hands.stop() }
        var stopped = 0
        for session in Sessions.all {
            let conversations = [session.claude].compactMap { $0 } + Array(session.jobs.sessions.values)
            for conversation in conversations where conversation.state == .working {
                conversation.interrupt()
                stopped += 1
            }
        }
        if handsOn {
            Task {
                try? await Task.sleep(for: .seconds(2))
                if Preferences.shared.handsEnabled { Hands.allow() }
            }
        }
        NSSound(named: "Funk")?.play()
        return stopped
    }

    /// Nil when done, else why not.
    private func act(on message: ClientMessage) -> String? {
        switch message {
        case .hello, .speech, .library, .page, .briefing, .replyMail, .screen, .stopHands, .stopAll, .place, .git:
            return nil
        case .openProject(_, let project):
            if let session = session(project) {
                session.window?.makeKeyAndOrderFront(nil)
                return nil
            }
            return open(project)
        case .setApprovals(_, let project, let mode):
            guard let session = session(project), let conversation = session.claude else { return "Open a conversation on the Mac first." }
            guard let level = ApprovalLevel(rawValue: mode.rawValue) else { return "That approval setting isn’t supported." }
            conversation.setApprovalLevel(level, approvingPending: true)
            return nil
        case .ask(_, let project, let job, let text, let spoken):
            guard let session = session(project) else { return "That project isn’t open on the Mac any more." }
            let target = job.flatMap { session.jobs.wake($0) }
            if job != nil, target == nil { return "That job isn’t running." }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Nothing to send." }
            if spoken { NaturalSpeaker.shared.prewarm() }
            session.askClaude(trimmed, instructions: spoken ? SpokenReply.conversationInstructions : nil, in: target)
            return nil
        case .answer(_, let project, let approval, let allow, let note, let answers):
            guard let session = session(project) else { return "That project isn’t open on the Mac any more." }
            guard let item = session.inbox.first(where: { $0.id == approval }), let claude = session.conversation(of: item) else {
                return "That was already answered."
            }
            if !allow {
                let reason = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if reason.isEmpty { claude.decline(item.tool.id) } else { claude.decline(item.tool.id, message: "The user declined this: \(reason)") }
            } else if item.isQuestion {
                claude.answer(item.tool.id, answers: answers ?? [:])
            } else {
                claude.approve(item.tool.id)
            }
            return nil
        case .startJob(_, let project, let brief, let awayMinutes):
            guard let session = session(project) else { return "That project isn’t open on the Mac any more." }
            if let reason = session.jobs.unavailable { return reason }
            session.startJob(brief, engine: Preferences.shared.agentEngine, awayMinutes: awayMinutes, reportsFailure: true)
            return nil
        case .stop(_, let project, let job):
            guard let session = session(project) else { return "That project isn’t open on the Mac any more." }
            guard let claude = job.map({ session.jobs.sessions[$0] }) ?? session.claude else { return "Nothing to stop." }
            claude.interrupt()
            return nil
        }
    }
}
