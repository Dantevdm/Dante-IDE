import AppKit
import DanteKit
import Foundation

/// Remote projects: a mirror kept in step with the host while the window has it open.
extension Session {
    /// Starts syncing when the folder mirrors a remote project; otherwise stops any earlier sync.
    func attachRemote(for url: URL) {
        detachRemote()
        guard let project = RemoteRegistry.known(mirror: url) else { return }
        let sync = RemoteSync(project: project)
        RemoteRegistry.register(project) { [weak sync] in
            Task { @MainActor in sync?.request(after: .milliseconds(600)) }
        }
        remoteSync = sync
        sync.startPolling { NSApp.isActive ? .seconds(4) : .seconds(30) }
        Task {
            if let problem = await SSH.connect(host: project.host) { errorMessage = problem }
            await sync.sync()
            await sync.pullTranscripts()
            await findLanguageServers(on: project)
            if ComposeFile.find(in: project.mirrorURL) != nil, case .success(let containers) = await ContainerState.load(projectRoot: project.mirrorURL) {
                await forwardPorts(of: containers)
            }
        }
    }

    /// Asks the host which language servers it has; those run there from now on, with the
    /// project's toolchain and dependencies, and any already running here move across.
    private func findLanguageServers(on project: RemoteProject) async {
        let command = SSH.remoteCommand(["sh", "-c", LanguageServer.hostProbeScript()], in: project.path)
        let output = await Shell.run([SSH.program] + SSH.arguments(host: project.host, command: command), in: FileManager.default.homeDirectoryForCurrentUser)
        guard output.succeeded, remoteSync?.project == project else { return }
        RemoteRegistry.setHostServers(LanguageServer.hostCommands(fromProbe: output.stdout), for: project)
        let moved = languages?.moveToHost() ?? []
        guard !moved.isEmpty, let workspace else { return }
        for document in workspace.documents where LanguageServer.for(document.language).map({ moved.contains($0.name) }) == true {
            languages?.opened(document)
        }
    }

    /// Running services' published ports, forwarded from the host to this Mac.
    func forwardPorts(of containers: [ContainerState]) async {
        guard let remoteSync else { return }
        let ports = containers.filter { $0.state == "running" }.flatMap(\.ports).compactMap { Int($0.drop { $0 == ":" }) }
        await remoteSync.forward(Set(ports))
    }

    /// After each Claude turn: its transcript is on the host.
    func pullRemoteTranscripts() {
        guard let remoteSync else { return }
        Task { await remoteSync.pullTranscripts() }
    }

    func detachRemote() {
        guard let sync = remoteSync else { return }
        sync.stop()
        RemoteRegistry.unregister(mirror: sync.project.mirror)
        remoteSync = nil
    }

    /// Syncs now, from the title bar.
    func syncRemoteNow() {
        guard let remoteSync else { return }
        Task { await remoteSync.sync() }
    }
}

/// Open Remote…: checks the host, copies the project into a new mirror and opens it.
@MainActor @Observable
final class RemoteOpening {
    enum Step: Equatable {
        case idle
        case connecting
        case copying
        case failed(String)
    }

    var step: Step = .idle
    var isBusy: Bool { step == .connecting || step == .copying }

    func open(host: String, path: String, in session: Session) async {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !path.isEmpty else { return }
        if !path.hasPrefix("/") && !path.hasPrefix("~") { path = "~/" + path }
        step = .connecting
        if let problem = await SSH.connect(host: host) { step = .failed(problem); return }
        // `~` means the home folder there, which only the host knows.
        if path.hasPrefix("~") {
            let output = await Shell.run([SSH.program] + SSH.arguments(host: host, command: "printf %s \"$HOME\""), in: FileManager.default.homeDirectoryForCurrentUser)
            guard output.succeeded, output.stdout.hasPrefix("/") else { step = .failed(RemoteSync.explain(output, host: host)); return }
            path = output.stdout + path.dropFirst()
        }
        if let problem = await RemoteSync.check(host: host, path: path) { step = .failed(problem); return }

        let mirror = RemoteProject.mirrorFolder(host: host, path: path, in: RemoteProject.mirrorsBase)
        let project = RemoteProject(host: host, path: path, mirror: mirror.path)
        step = .copying
        do {
            try await RemoteSync(project: project).pullAll()
        } catch {
            step = .failed(error.localizedDescription)
            return
        }
        RemoteRegistry.remember(project)
        step = .idle
        session.showsOpenRemote = false
        session.open(folder: mirror)
    }
}
