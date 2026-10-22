import Foundation

/// How a frontend picks its theme, read from its code: a build variable (`VITE_THEME`), and
/// in development a `?theme=` query that swaps it live without a restart.
public struct ThemeSwap: Equatable, Sendable {
    /// The environment variable a build reads: "VITE_THEME".
    public var buildVariable: String?
    /// The query parameter the running app reads: "theme" for `?theme=<folder>`.
    public var query: String?

    public init(buildVariable: String? = nil, query: String? = nil) {
        self.buildVariable = buildVariable
        self.query = query
    }

    public var isLive: Bool { query != nil }

    nonisolated(unsafe) private static let queryPattern = try! NSRegularExpression(pattern: #"(?:get|has)\(\s*['"](theme|brand|skin)['"]\s*\)|[?&](theme|brand|skin)="#)
    nonisolated(unsafe) private static let variablePattern = try! NSRegularExpression(pattern: #"(?:import\.meta\.env|process\.env)\.([A-Z][A-Z0-9_]*(?:THEME|BRAND|SKIN)[A-Z0-9_]*)"#)

    /// From the frontend's source files' text.
    public static func detect(in texts: [String]) -> ThemeSwap? {
        var swap = ThemeSwap()
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            if swap.query == nil, let match = queryPattern.firstMatch(in: text, range: range) {
                for group in 1...2 {
                    if let found = Range(match.range(at: group), in: text) { swap.query = String(text[found]) }
                }
            }
            if swap.buildVariable == nil, let match = variablePattern.firstMatch(in: text, range: range), let found = Range(match.range(at: 1), in: text) {
                swap.buildVariable = String(text[found])
            }
        }
        return swap.query == nil && swap.buildVariable == nil ? nil : swap
    }

    /// The running app's address with this theme: before any `#`, so hash routers keep it.
    public func url(_ base: URL, theme: String) -> URL? {
        guard let query else { return nil }
        var text = base.absoluteString
        var fragment = ""
        if let hash = text.firstIndex(of: "#") {
            fragment = String(text[hash...])
            text = String(text[..<hash])
        }
        guard var components = URLComponents(string: text) else { return nil }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != query } + [URLQueryItem(name: query, value: theme)]
        return URL(string: (components.string ?? text) + fragment)
    }
}

/// A folder of themes, one folder each: in a project (`frontend/themes`) or the company's
/// standards library.
public struct ThemeSet: Identifiable, Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        /// In the project, at this path from its root.
        case project(String)
        /// The company library chosen in Settings, shared by every project.
        case library
    }

    public var folder: URL
    public var place: Place
    /// The default first, then by name.
    public var themes: [UITheme]
    /// The theme every other one falls back to, field by field.
    public var defaultName: String?
    /// How the app beside it picks one; nil in the library or when the code doesn't say.
    public var swap: ThemeSwap?

    public var id: String { folder.path }

    public init(folder: URL, place: Place, themes: [UITheme], defaultName: String? = nil, swap: ThemeSwap? = nil) {
        self.folder = folder
        self.place = place
        self.defaultName = defaultName
        self.swap = swap
        self.themes = themes.sorted { ($0.name == defaultName ? 0 : 1, $0.name) < ($1.name == defaultName ? 0 : 1, $1.name) }
    }

    public var title: String {
        switch place {
        case .project(let path): path
        case .library: "Company library"
        }
    }

    public var base: UITheme? { themes.first { $0.name == defaultName } }

    /// A theme as the app shows it: with the default's fields where it leaves them out.
    public func resolved(_ theme: UITheme) -> UITheme { theme.over(base) }

    public func problems(_ theme: UITheme) -> [String] {
        theme.problems(folderName: theme.folder?.lastPathComponent) { file in
            guard let folder = theme.folder else { return false }
            return FileManager.default.fileExists(atPath: folder.appending(path: file).path)
        }
    }

    /// Reads a folder of themes; nil when none of its folders holds a theme.
    public static func read(folder: URL, place: Place, swap: ThemeSwap? = nil) -> ThemeSet? {
        let children = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let themes = children.compactMap(UITheme.read(folder:))
        guard !themes.isEmpty else { return nil }
        let readme = ["README.md", "readme.md", "Readme.md"].lazy.compactMap { try? String(contentsOf: folder.appending(path: $0), encoding: .utf8) }.first
        return ThemeSet(folder: folder, place: place, themes: themes, defaultName: defaultName(readme: readme, names: themes.map(\.name)), swap: swap)
    }

    /// The default theme: the one the README calls built in or default, else one named
    /// "default", else the only one.
    public static func defaultName(readme: String?, names: [String]) -> String? {
        if let readme {
            for line in readme.split(separator: "\n") {
                let lower = line.lowercased()
                guard lower.contains("built-in") || lower.contains("built in") || lower.contains("default") else { continue }
                // The first `name` on a line that says so: "`base` is the built-in theme", "| `base` | … | Default. |".
                let ticked = line.split(separator: "`", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
                if let name = ticked.first(where: names.contains) { return name }
            }
        }
        if names.contains("default") { return "default" }
        return names.count == 1 ? names[0] : nil
    }

    /// The folders in a project that hold themes, from its file list: `<set>/<name>/theme.json`.
    /// Build output (dist, build, out) and dependencies are left out.
    public static func folders(in files: [String]) -> [String] {
        let skipped: Set<String> = ["node_modules", "dist", "build", "out", ".next", ".output", "coverage", ".git"]
        var sets: Set<String> = []
        for path in files where path.hasSuffix("/theme.json") {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 3, !parts.contains(where: skipped.contains) else { continue }
            sets.insert(parts.dropLast(2).joined(separator: "/"))
        }
        return sets.sorted()
    }

    /// The source files that say how the app beside a set picks a theme: its code and build
    /// config, from the set's parent folder (the frontend).
    public static func sourceFiles(for set: String, in files: [String], limit: Int = 3000) -> [String] {
        let app = (set as NSString).deletingLastPathComponent
        let prefix = app.isEmpty ? "" : app + "/"
        let extensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "vue", "svelte", "html"]
        return files.lazy
            .filter { $0.hasPrefix(prefix) && !$0.contains("node_modules/") && !$0.contains("/dist/") && !$0.hasPrefix("dist/") }
            .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .prefix(limit)
            .map { $0 }
    }
}

/// The house rules a team builds to: principles and UI standards as markdown, and themes.
/// From the project (`docs/standards/`, `standards/`, `.dante/standards/`, and any folder of
/// themes) and from the company library folder chosen in Settings, which every project shares
/// and which stays outside every repo.
public struct Standards: Equatable, Sendable {
    public struct Doc: Identifiable, Equatable, Sendable {
        public var title: String
        public var url: URL
        /// From the project's root, for a project doc; nil for the library's.
        public var path: String?
        public var id: String { url.path }

        public init(title: String, url: URL, path: String? = nil) {
            self.title = title
            self.url = url
            self.path = path
        }
    }

    public var docs: [Doc]
    public var themeSets: [ThemeSet]
    public var library: URL?

    public init(docs: [Doc] = [], themeSets: [ThemeSet] = [], library: URL? = nil) {
        self.docs = docs
        self.themeSets = themeSets
        self.library = library
    }

    public var isEmpty: Bool { docs.isEmpty && themeSets.isEmpty }

    /// The theme sets inside a frontend's folder ("" for the repo root).
    public func themeSets(within folder: String) -> [ThemeSet] {
        themeSets.filter { set in
            guard case .project(let path) = set.place else { return false }
            return folder.isEmpty || folder == "." || path == folder || path.hasPrefix(folder + "/")
        }
    }
    public var themeCount: Int { themeSets.reduce(0) { $0 + $1.themes.count } }

    public static let projectFolders = ["docs/standards/", "standards/", ".dante/standards/", "documentation/standards/"]

    /// Project docs that are standards, from its file list.
    public static func projectDocs(in files: [String]) -> [String] {
        files.filter { path in
            path.lowercased().hasSuffix(".md") && projectFolders.contains { path.lowercased().hasPrefix($0) }
        }.sorted()
    }

    /// Reads it all; slow parts (files, source text) belong off the main thread.
    public static func load(projectRoot: URL, files: [String], library: URL?) -> Standards {
        var standards = Standards(library: library)
        standards.docs = projectDocs(in: files).map { path in
            let url = projectRoot.appending(path: path)
            return Doc(title: title(of: url), url: url, path: path)
        }
        for set in ThemeSet.folders(in: files) {
            let texts = ThemeSet.sourceFiles(for: set, in: files).compactMap { path -> String? in
                let url = projectRoot.appending(path: path)
                guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 400_000 else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            }
            if let read = ThemeSet.read(folder: projectRoot.appending(path: set), place: .project(set), swap: ThemeSwap.detect(in: texts)) {
                standards.themeSets.append(read)
            }
        }
        if let library {
            standards.docs += libraryDocs(library).map { Doc(title: title(of: $0), url: $0) }
            if let set = ThemeSet.read(folder: library.appending(path: "themes"), place: .library) { standards.themeSets.append(set) }
        }
        return standards
    }

    /// Markdown in the library, outside its themes folder.
    static func libraryDocs(_ library: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: library, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var docs: [URL] = []
        for case let url as URL in walker {
            if url.lastPathComponent == "themes" || url.lastPathComponent == "node_modules" {
                walker.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == "md" { docs.append(url) }
        }
        return docs.sorted { $0.path < $1.path }
    }

    /// The first heading, else the file's name in words.
    public static func title(of url: URL) -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let heading = text.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) {
            return heading.dropFirst(2).trimmingCharacters(in: .whitespaces)
        }
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The theme a project's frontend uses: from its env files' `<variable>=<name>`, else the
    /// set's default.
    public static func current(_ set: ThemeSet, envTexts: [String]) -> String? {
        if let variable = set.swap?.buildVariable {
            for text in envTexts {
                for line in text.split(separator: "\n") where line.hasPrefix(variable + "=") {
                    let value = line.dropFirst(variable.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if set.themes.contains(where: { $0.name == value }) { return value }
                }
            }
        }
        return set.defaultName
    }
}

/// Making and copying themes.
public enum ThemeMaker {
    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Text that reads on a colour: white, unless white is too faint on it.
    public static func foreground(on color: ThemeColor) -> ThemeColor {
        let white = ThemeColor("#ffffff")!
        return color.contrast(with: white) >= 4.5 ? white : ThemeColor("#111827")!
    }

    /// A name for a folder from a customer's name: "Acme Insurance" → "acme-insurance".
    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let words = lowered.split(whereSeparator: { !($0.isLetter && $0.isASCII) && !$0.isNumber })
        return words.joined(separator: "-")
    }

    /// Writes `theme` as a new folder in `set`, with its asset files copied in under the names
    /// it gives them and the font files (and licence) of `fontsFrom` when it uses that font.
    @discardableResult
    public static func write(_ theme: UITheme, into set: URL, assets: [String: URL] = [:], fontsFrom: UITheme? = nil) throws -> URL {
        guard UITheme.isValidName(theme.name) else { throw Failure(message: "A theme’s name is lower case letters, digits and hyphens.") }
        let folder = set.appending(path: theme.name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw Failure(message: "There’s already a theme called \(theme.name) there.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written = theme
        written.folder = folder
        for (key, source) in assets {
            let name = key.replacingOccurrences(of: "logoReversed", with: "logo-reversed").replacingOccurrences(of: "markReversed", with: "mark-reversed")
                .replacingOccurrences(of: "loginArtwork", with: "login-artwork") + "." + source.pathExtension.lowercased()
            try FileManager.default.copyItem(at: source, to: folder.appending(path: name))
            written.assets[key] = name
        }
        if let fontsFrom, let source = fontsFrom.folder, written.fontFamily == fontsFrom.fontFamily {
            written.fontFiles = fontsFrom.fontFiles
            var copied: Set<String> = []
            for file in fontsFrom.fontFiles {
                for path in [file.src, (file.src as NSString).deletingLastPathComponent + "/OFL.txt", (file.src as NSString).deletingLastPathComponent + "/LICENSE.txt"]
                where !copied.contains(path) && FileManager.default.fileExists(atPath: source.appending(path: path).path) {
                    let target = folder.appending(path: path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source.appending(path: path), to: target)
                    copied.insert(path)
                }
            }
        }
        try written.json.write(to: folder.appending(path: "theme.json"), atomically: true, encoding: .utf8)
        return folder
    }

    /// Copies a theme's folder into another set, renamed when `name` is given.
    @discardableResult
    public static func copy(_ theme: UITheme, into set: URL, as name: String? = nil) throws -> URL {
        guard let source = theme.folder else { throw Failure(message: "That theme has no folder to copy.") }
        let newName = name ?? theme.name
        guard UITheme.isValidName(newName) else { throw Failure(message: "A theme’s name is lower case letters, digits and hyphens.") }
        let folder = set.appending(path: newName, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw Failure(message: "There’s already a theme called \(newName) there.") }
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: folder)
        if newName != theme.name, var copied = UITheme.read(folder: folder) {
            copied.name = newName
            try copied.json.write(to: folder.appending(path: "theme.json"), atomically: true, encoding: .utf8)
        }
        return folder
    }
}
