import AppKit
import DanteKit
import DanteOpen
import SwiftUI

/// Opens what the `dante` command (or Finder, or a drop on the Dock icon) asks for: each
/// folder in the window that already has it, else in a window still on the launch screen,
/// else in a new window.
@MainActor
enum Opener {
    /// Targets waiting for a window that `openWindow` has been asked for; `RootView` takes
    /// the first one when it appears.
    private static var pending: [OpenTarget] = []

    static func takePending() -> OpenTarget? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Jobs from `dante job`, waiting for their project's window, by folder.
    private static var pendingJobs: [String: [JobRequest]] = [:]

    static func takeJobs(for folder: String) -> [JobRequest] {
        pendingJobs.removeValue(forKey: resolved(folder)) ?? []
    }

    /// SwiftUI's window opener, kept from the first window so a session can open a project
    /// in a window of its own (`Session.openProject`).
    static var openWindow: OpenWindowAction?

    static func handle(_ url: URL, from receiver: Session?, openWindow: OpenWindowAction) {
        // A job opens its project like `dante <folder>` would; the window starts it.
        if var job = JobRequest(url: url) {
            // Without this Mac's key, the link came from a web page or another app: the
            // person confirms it, and it never goes ahead without asking.
            if !job.isTrusted(by: JobRequest.localKey()) {
                guard confirm(job) else { return }
                job.awayMinutes = nil
            }
            pendingJobs[resolved(job.folder), default: []].append(job)
            // Trusted or confirmed just now: the folder opens without asking again.
            return handle(OpenRequest(items: [.init(path: job.folder)], key: JobRequest.localKey()).url, from: receiver, openWindow: openWindow)
        }
        guard var request = OpenRequest(url: url) else { return }
        for index in request.items.indices {
            request.items[index].path = resolved(request.items[index].path)
        }
        let sessions = Sessions.all
        func folder(of session: Session) -> String? { session.workspace.map { resolved($0.url.path) } }
        // A link from a web page or another app opens only projects you've had open, unless you say so.
        if !request.isTrusted(by: JobRequest.localKey(create: false)) {
            let known = Set(sessions.compactMap(folder) + RecentProjects().items.map { resolved($0.path) })
            let unknown = request.items.map(\.path).filter { path in
                !known.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            if !unknown.isEmpty, !confirmOpening(unknown) { return }
        }
        let targets = OpenTarget.plan(
            request,
            openFolders: sessions.compactMap(folder),
            isDirectory: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            projectRoot: { OpenTarget.projectRoot(of: $0) }
        )
        // Windows on the launch screen, the one that received the request first.
        var empty = sessions.filter { $0.workspace == nil }
        if let index = empty.firstIndex(where: { $0 === receiver }) { empty.insert(empty.remove(at: index), at: 0) }

        var shown: Session?
        for target in targets {
            let reuse = !(request.newWindow && target.named)
            if reuse, let existing = sessions.first(where: { folder(of: $0) == target.folder }) {
                existing.apply(target)
                shown = existing
            } else if !empty.isEmpty {
                let session = empty.removeFirst()
                session.apply(target)
                shown = session
            } else {
                pending.append(target)
                openWindow(id: "workspace")
            }
        }
        // Launch Services brings Dante forward for `dante`; this picks the window.
        shown?.window?.makeKeyAndOrderFront(nil)
    }

    private static func confirmOpening(_ paths: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = paths.count == 1 ? "Open \((paths[0] as NSString).lastPathComponent)?" : "Open \(paths.count) items?"
        alert.informativeText = "A link asked Dante to open:\n\n" + paths.prefix(5).joined(separator: "\n")
            + "\n\nIt didn’t come from the dante command, and Dante hasn’t had this project open before. Opening files starts their language servers, and some run the project’s build scripts, so open it only if you trust it."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func confirm(_ job: JobRequest) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Start a job in \((job.folder as NSString).lastPathComponent)?"
        alert.informativeText = "A link asked Dante to hand this to an agent:\n\n“\(job.brief.prefix(600))”\n\nIt didn’t come from the dante command, so check you expected it. The job works on its own branch and asks before each step."
        alert.addButton(withTitle: "Start Job")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Symlinks resolved, so /tmp and /private/tmp are the same folder.
    private static func resolved(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

extension Session {
    /// Opens the target's folder unless it's already the one open, then its files.
    func apply(_ target: OpenTarget) {
        let folder = URL(filePath: target.folder)
        if workspace.map({ $0.url.resolvingSymlinksInPath().path }) != folder.resolvingSymlinksInPath().path {
            open(folder: folder)
        }
        for file in target.files {
            let url = URL(filePath: file.path)
            if let line = file.line { open(file: url, line: line) } else { open(file: url) }
        }
        for job in Opener.takeJobs(for: target.folder) {
            var type: JobType?
            if let kind = job.kind {
                guard let found = jobs.type(kind) else {
                    errorMessage = "There’s no job type called \(kind) in this project. Types are in .dante/jobs/; built in: \(JobType.builtIn.map(\.id).joined(separator: ", "))."
                    continue
                }
                type = found
            }
            // Only the dante command (which carries this Mac's key) may send a job off alone.
            let trusted = job.isTrusted(by: JobRequest.localKey(create: false))
            let engine = (job.agent ?? type?.agent).flatMap(AgentEngine.init(rawValue:)) ?? Preferences.shared.agentEngine
            var brief = job.brief
            if type?.input == .task, let workspace,
               let task = workspace.tasks.tasks.first(where: { $0.id.caseInsensitiveCompare(job.brief.trimmingCharacters(in: .whitespaces)) == .orderedSame }) {
                brief = JobType.subject(for: task, in: workspace.url)
            }
            startJob(brief, engine: engine, awayMinutes: trusted ? job.awayMinutes ?? type?.awayMinutes : nil, type: type, reportsFailure: true)
        }
    }
}

/// Hands the hosting NSWindow to `found` once the view is in one.
struct WindowReader: NSViewRepresentable {
    var found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { found(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
