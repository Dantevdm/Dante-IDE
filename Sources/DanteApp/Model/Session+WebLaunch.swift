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
        /// It has a package.json but nothing installed, or its lockfile changed since the last
        /// install (`lockfile`): install, then start, once asked.
        case needsInstall
        case failed(String)
    }

    let name: String
    let screen: String?
    var target: WebPreview.Target?
    var step: Step = .finding
    /// It was already running, so nothing was started.
    var wasRunning = false
    var waited = 0
    /// Its dependencies are being installed before it starts.
    var installing = false
    /// The failure can be fixed by installing its dependencies.
    var canInstall = false
    /// Installed, but this lockfile changed since.
    var lockfile: WebPreview.Lockfile?
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
                return
            }
            let (missing, lockfile) = await Task.detached(priority: .userInitiated) { () -> (WebPreview.Missing?, WebPreview.Lockfile?) in
                let missing = WebPreview.missing(target, exists: { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }, which: Shell.which)
                guard missing == nil else { return (missing, nil) }
                return (nil, WebPreview.outdated(folder: target.folder) { path in
                    (try? root.appending(path: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                })
            }.value
            switch missing {
            case .tool(let tool):
                launch.step = .failed("\(tool) isn’t installed on this Mac, so \(name) can’t start. Settings › Tools has the command to install Node.js and its package managers.")
            case .dependencies:
                launch.step = .needsInstall
            case nil:
                if let lockfile, !Self.isAccepted(lockfile, in: root) {
                    launch.lockfile = lockfile
                    launch.step = .needsInstall
                } else {
                    launch.step = .needsStart
                }
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
        // Started anyway: don't ask again until the lockfile changes once more.
        if let lockfile = launch.lockfile, !installing, let root = workspace?.url { Self.accept(lockfile, in: root) }
        launch.canInstall = false
        launch.waited = 0
        let status = "/tmp/dante-run-" + UUID().uuidString.prefix(8).lowercased()
        let shell = (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").hasSuffix("fish") ? "$status" : "$?"
        runInNewTerminal(Self.launchCommand(target, installing: installing) + "; echo \(shell) > \(status)", title: target.name)
        let started = Date()
        // A first install can take minutes; a start alone shouldn't.
        let limit = installing ? 900 : 150
        launch.task = Task {
            defer { try? FileManager.default.removeItem(atPath: status) }
            try? await Task.sleep(for: .milliseconds(600))
            launch.step = .waiting
            while !Task.isCancelled {
                if await Self.isListening(target.port) { break }
                if let text = try? String(contentsOfFile: status, encoding: .utf8), let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    launch.canInstall = code != 130 && code != 143 && FileManager.default.fileExists(atPath: workspace?.url.appending(path: target.folder).appending(path: "package.json").path ?? "")
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
            if installing, let lockfile = launch.lockfile, let root = workspace?.url { Self.accept(lockfile, in: root) }
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

    private static let acceptedLockfilesKey = "webLaunch.acceptedLockfiles"

    /// Lockfiles installed from, or started anyway with, per Mac: a package manager that finds
    /// nothing to do may leave its install marker as it was, and Dante shouldn't keep asking.
    static func isAccepted(_ lockfile: WebPreview.Lockfile, in root: URL) -> Bool {
        let saved = UserDefaults.standard.dictionary(forKey: acceptedLockfilesKey) as? [String: Double] ?? [:]
        return (saved[root.appending(path: lockfile.path).path] ?? 0) >= lockfile.modified.timeIntervalSince1970 - 1
    }

    static func accept(_ lockfile: WebPreview.Lockfile, in root: URL) {
        var saved = UserDefaults.standard.dictionary(forKey: acceptedLockfilesKey) as? [String: Double] ?? [:]
        saved[root.appending(path: lockfile.path).path] = lockfile.modified.timeIntervalSince1970
        UserDefaults.standard.set(saved, forKey: acceptedLockfilesKey)
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
