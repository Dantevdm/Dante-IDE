import AppKit
import DanteKit
import Observation

/// Opening a web app's screen from the Map: find how it runs, say so and start it when it
/// isn't up (installing its dependencies first when they're missing, once asked), wait for its
/// port, then open the page in the default browser. Every step shows, and a command that stops
/// says why at once instead of waiting out the port.
@MainActor
@Observable
final class WebLaunch {
    enum Step: Equatable {
        case finding, needsStart, starting, waiting, opening, opened
        /// It has a package.json but nothing installed: install, then start, once asked.
        case needsInstall
        case failed(String)
    }

    let name: String
    let screen: String?
    /// Open it with this theme: the query parameter the app reads and the theme's name.
    var theme: (query: String, name: String)?
    var target: WebPreview.Target?
    /// The page it opens: the target's, with the theme when there is one.
    var pageURL: URL? {
        guard let target else { return nil }
        return theme.flatMap { ThemeSwap(query: $0.query).url(target.url, theme: $0.name) } ?? target.url
    }
    var step: Step = .finding
    /// It was already running, so nothing was started.
    var wasRunning = false
    var waited = 0
    /// Its dependencies are being installed before it starts.
    var installing = false
    /// The failure can be fixed by installing its dependencies.
    var canInstall = false
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
    func openInBrowser(folder: String, name: String, screen: (name: String, file: String?)?, theme: (query: String, name: String)? = nil) {
        guard let workspace else { return }
        webLaunch?.task?.cancel()
        let launch = WebLaunch(name: name, screen: screen?.name)
        launch.theme = theme
        webLaunch = launch
        guard RemoteRegistry.project(containing: workspace.url) == nil else {
            launch.step = .failed("Opening pages isn’t available for remote projects yet: their dev servers run on the host.")
            return
        }
        let files = workspace.files
        let root = workspace.url
        launch.task = Task {
            let target = await Task.detached(priority: .userInitiated) {
                let target = WebPreview.target(folder: folder, name: name, screen: screen, files: files) { path in
                    let url = root.appending(path: path)
                    guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 1_000_000 else { return nil }
                    return try? String(contentsOf: url, encoding: .utf8)
                }
                // The project's own way of running it comes first: its compose service.
                return ComposeFile.load(projectRoot: root).flatMap { WebPreview.throughCompose(target, compose: $0) } ?? target
            }.value
            guard !Task.isCancelled else { return }
            launch.target = target
            if await Self.isListening(target.port) {
                launch.wasRunning = true
                await open(launch)
                return
            }
            let missing = await Task.detached(priority: .userInitiated) {
                WebPreview.missing(target, exists: { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }, which: Shell.which)
            }.value
            switch missing {
            case .tool(let tool):
                launch.step = .failed("\(tool) isn’t installed on this Mac, so \(name) can’t start. Settings › Tools has the command to install Node.js and its package managers.")
            case .dependencies:
                launch.step = .needsInstall
            case nil:
                launch.step = .needsStart
            }
        }
    }

    /// After the person agrees: start it in a terminal tab (installing its dependencies first
    /// when `installing`) and open the page once it listens. The shell writes the command's exit
    /// status to a file when it stops, so a failure shows at once.
    func startAndOpen(installing: Bool = false) {
        guard let launch = webLaunch, let target = launch.target else { return }
        guard launch.step == .needsStart || launch.step == .needsInstall || launch.canInstall else { return }
        launch.step = .starting
        launch.installing = installing
        launch.canInstall = false
        launch.waited = 0
        let status = "/tmp/dante-run-" + UUID().uuidString.prefix(8).lowercased()
        let shell = (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").hasSuffix("fish") ? "$status" : "$?"
        runInNewTerminal(Self.launchCommand(target, installing: installing) + "; echo \(shell) > \(status)", title: target.name)
        let started = Date()
        if let service = target.service {
            serviceKeeper.youStarted([service], all: [])
        }
        // A first install or image build can take minutes; a dev server alone shouldn't.
        let limit = installing || target.service != nil ? 900 : 150
        launch.task = Task {
            defer { try? FileManager.default.removeItem(atPath: status) }
            try? await Task.sleep(for: .milliseconds(600))
            launch.step = .waiting
            while !Task.isCancelled {
                if await Self.isListening(target.port) { break }
                // `docker compose up -d` finishes once the container starts; then the port is awaited.
                if let text = try? String(contentsOfFile: status, encoding: .utf8), let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   !(code == 0 && target.service != nil) {
                    launch.canInstall = target.service == nil && code != 130 && code != 143 && FileManager.default.fileExists(atPath: workspace?.url.appending(path: target.folder).appending(path: "package.json").path ?? "")
                    launch.step = .failed(WebPreview.stopped(code, tool: target.tool))
                    return
                }
                launch.waited = Int(Date().timeIntervalSince(started))
                if launch.waited >= limit {
                    launch.step = .failed("Port \(target.port) didn’t open within \(launch.waited) seconds. The terminal tab shows what happened; it may listen on another port.")
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

    /// `cd web && pnpm install && pnpm dev`, or the start command alone.
    static func launchCommand(_ target: WebPreview.Target, installing: Bool) -> String {
        guard installing else { return target.command }
        let cd = target.folder.isEmpty ? "" : "cd \(Shell.quote(target.folder)) && "
        let run = target.command.hasPrefix(cd) ? String(target.command.dropFirst(cd.count)) : target.command
        return cd + "\(target.tool) install && " + run
    }

    func cancelWebLaunch() {
        webLaunch?.task?.cancel()
        webLaunch = nil
    }

    private func open(_ launch: WebLaunch) async {
        guard let target = launch.target else { return }
        launch.step = .opening
        try? await Task.sleep(for: .milliseconds(350))
        NSWorkspace.shared.open(launch.pageURL ?? target.url)
        launch.step = .opened
    }

    static func isListening(_ port: Int) async -> Bool {
        await ListeningPort.load().contains { $0.port == port }
    }
}
