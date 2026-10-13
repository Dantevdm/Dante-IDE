import Foundation

/// The `dante` command inside Dante.app (Contents/Resources/bin/dante) and how to put it on
/// the PATH. Like the other tools, Dante shows the command and never runs it.
public enum CommandLineTool {
    public static let name = "dante"

    /// The command inside this copy of Dante, when it's an app bundle with one.
    public static func bundled(in app: URL = Bundle.main.bundleURL) -> URL? {
        let url = app.appending(path: "Contents/Resources/bin/\(name)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public enum State: Equatable, Sendable {
        case notInstalled
        /// On the PATH and pointing at this copy of Dante.
        case installed(String)
        /// On the PATH but pointing somewhere else (another copy of Dante, or something else
        /// called `dante`).
        case elsewhere(String)
    }

    /// `found` is what `which dante` printed and `resolved` where its symlinks lead.
    public static func state(found: String?, resolved: String?, bundled: String) -> State {
        guard let found else { return .notInstalled }
        return resolved == bundled ? .installed(found) : .elsewhere(found)
    }

    /// Folders worth linking into, in order: Homebrew's, then /usr/local/bin, then the
    /// home folder's own bin folders.
    static func candidates(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/bin"]
    }

    /// A command that links `source` into the first candidate folder that's on the PATH and
    /// writable; otherwise into /usr/local/bin with sudo.
    public static func installCommand(source: String, path: String, home: String, isWritable: (String) -> Bool) -> String {
        let onPath = Set(path.split(separator: ":").map { String($0).hasSuffix("/") ? String($0.dropLast()) : String($0) })
        let link = { (folder: String) in "ln -sf \(Shell.quote(source)) \(Shell.quote(folder + "/" + name))" }
        if let folder = candidates(home: home).first(where: { onPath.contains($0) && isWritable($0) }) {
            return link(folder)
        }
        return "sudo mkdir -p /usr/local/bin && sudo " + link("/usr/local/bin")
    }
}
