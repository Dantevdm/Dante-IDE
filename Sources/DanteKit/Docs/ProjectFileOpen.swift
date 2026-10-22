import Foundation

/// A file the agent asks Dante to open, confined to its project, including symlink targets.
public enum ProjectFileOpen {
    public struct Failure: LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public static func resolve(_ path: String, root: URL, rules: ClaudeRules) throws -> URL {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("://"), !path.contains("\0") else {
            throw Failure(message: "Choose a project file path, not a URL.")
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        // A root URL need not end in a slash. Relative URL resolution would then
        // treat its last component as a file and open from the parent folder.
        let lexical = (path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path)).standardizedFileURL
        let url = lexical.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/") else {
            throw Failure(message: "The file must be inside this project.")
        }
        let relative = String(url.path.dropFirst(base.path.count + 1))
        let original = ProposedChange.relativePath(of: lexical, in: root)
        guard !rules.never.contains(where: { ClaudeRules.path(relative, matches: $0) || ClaudeRules.path(original, matches: $0) }) else {
            throw Failure(message: "The project's rules don't allow opening this file.")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
            throw Failure(message: "No file at \(path).")
        }
        return url
    }

    public static func isHTML(_ url: URL) -> Bool { ["html", "htm"].contains(url.pathExtension.lowercased()) }

    /// Static preview assets only: no source, environment files or credentials.
    public static let assetExtensions: Set<String> = ["html", "htm", "css", "js", "mjs", "json", "svg", "png", "jpg", "jpeg", "gif", "webp", "ico", "woff", "woff2", "ttf", "otf", "mp3", "wav", "mp4", "webm"]
    public static let contentPolicy = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; media-src 'self' data:; connect-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'none'"

    public static func asset(_ path: String, root: URL, rules: ClaudeRules) throws -> URL {
        let url = try resolve(path, root: root, rules: rules)
        let parts = ProposedChange.relativePath(of: url, in: root).split(separator: "/")
        guard assetExtensions.contains(url.pathExtension.lowercased()), !parts.contains(where: { $0.hasPrefix(".") }) else {
            throw Failure(message: "This file isn't a preview asset.")
        }
        return url
    }
}
