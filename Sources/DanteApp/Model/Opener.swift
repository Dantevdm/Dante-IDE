import AppKit
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

    static func handle(_ url: URL, from receiver: Session, openWindow: OpenWindowAction) {
        guard var request = OpenRequest(url: url) else { return }
        for index in request.items.indices {
            request.items[index].path = resolved(request.items[index].path)
        }
        let sessions = Sessions.all
        func folder(of session: Session) -> String? { session.workspace.map { resolved($0.url.path) } }
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
