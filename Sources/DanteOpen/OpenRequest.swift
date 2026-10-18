import Foundation

/// Folders and files to open in Dante, sent by the `dante` command as a `dante://open` URL.
/// Lives in its own module, with nothing but Foundation, so the command stays small.
public struct OpenRequest: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// An absolute path.
        public var path: String
        /// A 1-based line to show, from `file:line`.
        public var line: Int?

        public init(path: String, line: Int? = nil) {
            self.path = path
            self.line = line
        }
    }

    public var items: [Item]
    /// Open the folders in new windows even when one has them open already.
    public var newWindow: Bool

    public init(items: [Item], newWindow: Bool = false) {
        self.items = items
        self.newWindow = newWindow
    }

    public static let scheme = "dante"

    /// `dante://open?path=/a&path=/b/c.go&line=42&new=1`: a `line` belongs to the path before it.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "open"
        var query: [URLQueryItem] = []
        for item in items {
            query.append(URLQueryItem(name: "path", value: item.path))
            if let line = item.line { query.append(URLQueryItem(name: "line", value: String(line))) }
        }
        if newWindow { query.append(URLQueryItem(name: "new", value: "1")) }
        components.queryItems = query
        return components.url!
    }

    /// Reads a `dante://open` URL, or a file URL (Finder's Open With, a drop on the Dock icon).
    public init?(url: URL) {
        if url.isFileURL {
            self.init(items: [Item(path: url.standardizedFileURL.path)])
            return
        }
        guard url.scheme == Self.scheme, url.host == "open",
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var items: [Item] = []
        var newWindow = false
        for entry in query {
            switch entry.name {
            case "path":
                if let value = entry.value, value.hasPrefix("/") { items.append(Item(path: value)) }
            case "line":
                if let value = entry.value, let line = Int(value), line > 0, !items.isEmpty { items[items.count - 1].line = line }
            case "new":
                newWindow = entry.value == "1"
            default:
                break
            }
        }
        guard !items.isEmpty else { return nil }
        self.init(items: items, newWindow: newWindow)
    }

    public enum Command: Equatable, Sendable {
        case open(OpenRequest)
        case help
        case version
    }

    public struct ArgumentError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// Reads the `dante` command's arguments. Paths are relative to `directory`; with none,
    /// it opens `directory`. `file:42` (and `file:42:7`) shows a line when `file` exists and
    /// the whole argument doesn't. Missing paths are refused rather than created.
    public static func parse(arguments: [String], in directory: String, exists: (String) -> Bool) throws -> Command {
        var items: [Item] = []
        var newWindow = false
        var onlyPaths = false
        for argument in arguments {
            if !onlyPaths, argument.hasPrefix("-"), argument != "-" {
                switch argument {
                case "--": onlyPaths = true
                case "-n", "--new-window": newWindow = true
                case "-h", "--help": return .help
                case "-v", "--version": return .version
                default: throw ArgumentError(description: "Unknown option \(argument). Try dante --help.")
                }
                continue
            }
            let path = absolute(argument, in: directory)
            if exists(path) {
                items.append(Item(path: path))
            } else if let (file, line) = splitLine(path), exists(file) {
                items.append(Item(path: file, line: line))
            } else {
                throw ArgumentError(description: "\(argument): no such file or folder")
            }
        }
        if items.isEmpty { items = [Item(path: absolute(".", in: directory))] }
        return .open(OpenRequest(items: items, newWindow: newWindow))
    }

    static func absolute(_ path: String, in directory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let joined = expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
        return URL(filePath: joined).standardizedFileURL.path
    }

    /// `/a/b.go:42` or `/a/b.go:42:7` → (`/a/b.go`, 42).
    static func splitLine(_ path: String) -> (String, Int)? {
        var parts = path.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        if parts.count >= 3, Int(parts[parts.count - 1]) != nil, Int(parts[parts.count - 2]) != nil { parts.removeLast() }
        guard let line = Int(parts[parts.count - 1]), line > 0 else { return nil }
        return (parts.dropLast().joined(separator: ":"), line)
    }

    public static let usage = """
        Usage: dante [options] [folder] [file[:line] …]
               dante job <what to do> [--in folder] [--away minutes]

        Opens folders and files in Dante. With no paths, opens the current folder.
        A file opens in the window that has its project open, or with the project
        it belongs to (the nearest folder holding .git or .dante).

          -n, --new-window   open folders in new windows
          -h, --help         show this help
          -v, --version      show Dante's version
        """
}

/// Where each part of an `OpenRequest` goes: one window per folder, with the files to open
/// in it.
public struct OpenTarget: Equatable, Sendable {
    public var folder: String
    public var files: [OpenRequest.Item]
    /// The folder came from the request itself rather than from a file in it.
    public var named: Bool

    public init(folder: String, files: [OpenRequest.Item] = [], named: Bool = true) {
        self.folder = folder
        self.files = files
        self.named = named
    }

    /// Folders keep their order; each file goes to a requested folder that holds it, else
    /// to an open project that holds it, else to the project it belongs to (`projectRoot`).
    /// The deepest folder wins when several hold it.
    public static func plan(
        _ request: OpenRequest,
        openFolders: [String],
        isDirectory: (String) -> Bool,
        projectRoot: (String) -> String
    ) -> [OpenTarget] {
        var targets: [OpenTarget] = []
        for item in request.items where isDirectory(item.path) && !targets.contains(where: { $0.folder == item.path }) {
            targets.append(OpenTarget(folder: item.path))
        }
        for item in request.items where !isDirectory(item.path) {
            let folder = deepest(holding: item.path, among: targets.map(\.folder))
                ?? deepest(holding: item.path, among: openFolders)
                ?? projectRoot(item.path)
            if let index = targets.firstIndex(where: { $0.folder == folder }) {
                targets[index].files.append(item)
            } else {
                targets.append(OpenTarget(folder: folder, files: [item], named: false))
            }
        }
        return targets
    }

    static func deepest(holding path: String, among folders: [String]) -> String? {
        folders.filter { contains($0, path) }.max { $0.count < $1.count }
    }

    public static func contains(_ folder: String, _ path: String) -> Bool {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix)
    }

    /// The nearest folder above `file` with `.git` or `.dante` in it, stopping short of the
    /// home folder and `/`; otherwise the file's own folder.
    public static func projectRoot(of file: String, home: String = NSHomeDirectory(), exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let parent = (file as NSString).deletingLastPathComponent
        var folder = parent
        while folder != "/", folder != home, !folder.isEmpty {
            if exists(folder + "/.git") || exists(folder + "/.dante") { return folder }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return parent
    }
}
