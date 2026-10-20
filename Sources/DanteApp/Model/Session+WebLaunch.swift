import AppKit
import DanteKit
import Observation

/// Opening a web app's screen from the Map: find how it runs, say so and start it when it
/// isn't up, wait for its port, then open the page in the default browser. Every step shows.
@MainActor
@Observable
final class WebLaunch {
    enum Step: Equatable {
        case finding, needsStart, starting, waiting, opening, opened
        case failed(String)
    }

    let name: String
    let screen: String?
    var target: WebPreview.Target?
    var step: Step = .finding
    /// It was already running, so nothing was started.
    var wasRunning = false
    var waited = 0
    @ObservationIgnored var task: Task<Void, Never>?

    init(name: String, screen: String?) {
        self.name = name
        self.screen = screen
    }

    var isDone: Bool {
        if case .failed = step { return true }
        return step == .opened
    }
}

extension Session {
    /// Opens a frontend (or one of its screens) in the browser, starting nothing until asked.
    func openInBrowser(folder: String, name: String, screen: (name: String, file: String?)?) {
        guard let workspace else { return }
        webLaunch?.task?.cancel()
        let launch = WebLaunch(name: name, screen: screen?.name)
        webLaunch = launch
        guard RemoteRegistry.project(containing: workspace.url) == nil else {
            launch.step = .failed("Opening pages isn’t available for remote projects yet: their dev servers run on the host.")
            return
        }
        let files = workspace.files
        let root = workspace.url
        launch.task = Task {
            let target = await Task.detached(priority: .userInitiated) {
                WebPreview.target(folder: folder, name: name, screen: screen, files: files) { path in
                    let url = root.appending(path: path)
                    guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 1_000_000 else { return nil }
                    return try? String(contentsOf: url, encoding: .utf8)
                }
            }.value
            guard !Task.isCancelled else { return }
            launch.target = target
            if await Self.isListening(target.port) {
                launch.wasRunning = true
                await open(launch)
            } else {
                launch.step = .needsStart
            }
        }
    }

    /// After the person agrees: start it in a terminal tab and open the page once it listens.
    func startAndOpen() {
        guard let launch = webLaunch, let target = launch.target, launch.step == .needsStart else { return }
        launch.step = .starting
        runInNewTerminal(target.command, title: target.name)
        let started = Date()
        launch.task = Task {
            try? await Task.sleep(for: .milliseconds(600))
            launch.step = .waiting
            while !Task.isCancelled {
                if await Self.isListening(target.port) { break }
                launch.waited = Int(Date().timeIntervalSince(started))
                if launch.waited >= 150 {
                    launch.step = .failed("Port \(target.port) didn’t open within \(launch.waited) seconds. The terminal tab shows what happened; it may need installing first, or it listens on another port.")
                    return
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
            guard !Task.isCancelled else { return }
            // The first page build takes a moment after the port opens.
            try? await Task.sleep(for: .milliseconds(700))
            await open(launch)
        }
    }

    func cancelWebLaunch() {
        webLaunch?.task?.cancel()
        webLaunch = nil
    }

    private func open(_ launch: WebLaunch) async {
        guard let target = launch.target else { return }
        launch.step = .opening
        try? await Task.sleep(for: .milliseconds(350))
        NSWorkspace.shared.open(target.url)
        launch.step = .opened
    }

    static func isListening(_ port: Int) async -> Bool {
        await ListeningPort.load().contains { $0.port == port }
    }
}
