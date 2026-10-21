import Foundation

/// Opening a frontend's screen from the map: the port its dev server listens on, the path the
/// screen is routed at, and the command that starts it. Pure; `read` returns a file's text.
public enum WebPreview {
    public struct Target: Equatable, Sendable {
        /// The frontend's folder ("" is the repo root).
        public var folder: String
        public var name: String
        public var port: Int
        /// Where the port came from: "vite.config.ts", "package.json", "Vite's default".
        public var portSource: String
        /// "/orders", or "/" when the screen's route wasn't found.
        public var path: String
        public var routeFound: Bool
        /// From the repo root: `cd web && npm run dev`.
        public var command: String
        /// The package manager it runs with: npm, pnpm, yarn or bun.
        public var tool: String = "npm"
        /// From the repo root: `cd web && npm install`.
        public var installCommand: String = "npm install"

        public var url: URL { URL(string: "http://localhost:\(port)" + path) ?? URL(string: "http://localhost:\(port)/")! }
    }

    /// What has to happen before a frontend can start.
    public enum Missing: Equatable, Sendable {
        /// Its package manager isn't installed on this Mac.
        case tool(String)
        /// It has a package.json but no node_modules: nothing has been installed yet.
        case dependencies
    }

    /// Checked before starting; `exists` takes a path from the repo root, `which` a tool's name.
    public static func missing(_ target: Target, exists: (String) -> Bool, which: (String) -> String?) -> Missing? {
        if which(target.tool) == nil { return .tool(target.tool) }
        return needsInstall(folder: target.folder, exists: exists) ? .dependencies : nil
    }

    /// A package.json with no node_modules in its folder or any folder above it, up to the repo
    /// root, where Node would look: a workspace member's packages are often at the root.
    public static func needsInstall(folder: String, exists: (String) -> Bool) -> Bool {
        let prefix = folder.isEmpty ? "" : folder + "/"
        guard exists(prefix + "package.json") else { return false }
        var parts = folder.split(separator: "/").map(String.init)
        while true {
            if exists((parts.isEmpty ? "" : parts.joined(separator: "/") + "/") + "node_modules") { return false }
            if parts.isEmpty { return true }
            parts.removeLast()
        }
    }

    /// A lockfile changed after the packages were last installed, from the repo root.
    public struct Lockfile: Equatable, Sendable {
        public var path: String
        public var modified: Date
        public init(path: String, modified: Date) {
            self.path = path
            self.modified = modified
        }
    }

    static let lockfiles = ["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb"]
    /// What each package manager writes on every install, from the folder holding node_modules:
    /// npm 7+, pnpm, Yarn 1, Yarn 2+ with node_modules, Yarn 2+.
    static let installMarkers = ["node_modules/.package-lock.json", "node_modules/.modules.yaml", "node_modules/.yarn-integrity",
                                 "node_modules/.yarn-state.yml", ".yarn/install-state.gz"]

    /// A lockfile (in the app's folder or beside the node_modules Node finds) written more than a
    /// minute after the last install, as after pulling a branch that changed dependencies: some
    /// packages may be missing or out of date. Nil without an install marker to compare with,
    /// rather than guessing from the folder's own date. `modified` takes a path from the repo root.
    public static func outdated(folder: String, modified: (String) -> Date?) -> Lockfile? {
        func prefix(_ parts: [String]) -> String { parts.isEmpty ? "" : parts.joined(separator: "/") + "/" }
        var parts = folder.split(separator: "/").map(String.init)
        let own = prefix(parts)
        while modified(prefix(parts) + "node_modules") == nil {
            if parts.isEmpty { return nil }
            parts.removeLast()
        }
        let base = prefix(parts)
        guard let installed = installMarkers.lazy.compactMap({ modified(base + $0) }).first else { return nil }
        for place in own == base ? [own] : [own, base] {
            for name in lockfiles {
                if let date = modified(place + name), date.timeIntervalSince(installed) > 60 {
                    return Lockfile(path: place + name, modified: date)
                }
            }
        }
        return nil
    }

    /// Why a dev command stopped, from the shell's exit status.
    public static func stopped(_ code: Int32, tool: String) -> String {
        switch code {
        case 127: "A command it needs wasn’t found. Usually its dependencies aren’t installed (or are out of date), so `\(tool) install` comes first."
        case 126: "A command it needs couldn’t run (permission denied). Installing its dependencies again usually fixes the file modes."
        case 130, 143: "It was stopped."
        default: "It stopped with exit code \(code). The terminal tab shows why; often its dependencies need installing or updating."
        }
    }

    /// The target for a frontend, and for one of its screens (its name and file, as the map
    /// lists them) when given.
    public static func target(folder: String, name: String, screen: (name: String, file: String?)? = nil,
                              files: [String], read: (String) -> String?) -> Target {
        let prefix = folder.isEmpty || folder == "." ? "" : folder + "/"
        let root = prefix.isEmpty ? "" : String(prefix.dropLast())
        let package = read(prefix + "package.json") ?? ""
        let (port, source) = self.port(prefix: prefix, package: package, files: files, read: read)
        var path = "/"
        var found = false
        if let screen, let route = route(of: screen.name, file: screen.file, prefix: prefix, next: package.contains("\"next\""), files: files, read: read) {
            path = route
            found = true
        }
        if let base = base(prefix: prefix, files: files, read: read), base != "/" {
            path = base.hasSuffix("/") ? base + path.dropFirst() : base + path
        }
        let script = scripts(package)["dev"] != nil ? "dev" : scripts(package)["start"] != nil ? "start" : "dev"
        let tool = files.contains(prefix + "pnpm-lock.yaml") ? "pnpm" : files.contains(prefix + "yarn.lock") ? "yarn"
            : files.contains(prefix + "bun.lockb") || files.contains(prefix + "bun.lock") ? "bun" : "npm"
        let run = "\(tool == "pnpm" || tool == "yarn" ? tool : tool + " run") \(script)"
        let cd = root.isEmpty ? "" : "cd \(Shell.quote(root)) && "
        return Target(folder: root, name: name, port: port, portSource: source, path: path, routeFound: found, command: cd + run,
                      tool: tool, installCommand: cd + "\(tool) install")
    }

    // MARK: Port

    static func port(prefix: String, package: String, files: [String], read: (String) -> String?) -> (Int, String) {
        let scripts = scripts(package)
        for key in ["dev", "start", "serve"] {
            guard let script = scripts[key] else { continue }
            if let match = script.firstMatch(of: /(?:--port[= ]|-p\s+|PORT=)(\d{2,5})/), let port = Int(match.1) { return (port, "package.json") }
        }
        for name in ["vite.config.ts", "vite.config.js", "vite.config.mts", "vite.config.mjs", "vue.config.js", "nuxt.config.ts", "astro.config.mjs", "svelte.config.js"] {
            guard files.contains(prefix + name), let text = read(prefix + name) else { continue }
            if let match = text.firstMatch(of: /(?m)^\s*port\s*:\s*(\d{2,5})/), let port = Int(match.1) { return (port, name) }
        }
        if files.contains(prefix + "angular.json"), let text = read(prefix + "angular.json"), let match = text.firstMatch(of: /"port"\s*:\s*(\d{2,5})/), let port = Int(match.1) {
            return (port, "angular.json")
        }
        // A PORT in the env file the dev server reads (only that line is looked at).
        for name in [".env.development.local", ".env.local", ".env.development", ".env"] {
            guard files.contains(prefix + name), let text = read(prefix + name) else { continue }
            if let match = text.firstMatch(of: /(?m)^\s*PORT\s*=\s*["']?(\d{2,5})/), let port = Int(match.1) { return (port, name) }
        }
        let has = { (dependency: String) in package.contains("\"\(dependency)\"") }
        if has("vite") || has("@sveltejs/kit") { return (5173, "Vite's default") }
        if has("@angular/core") { return (4200, "Angular's default") }
        if has("astro") { return (4321, "Astro's default") }
        if has("@vue/cli-service") { return (8080, "Vue CLI's default") }
        if has("next") { return (3000, "Next.js's default") }
        if has("nuxt") { return (3000, "Nuxt's default") }
        return (3000, "the usual default")
    }

    /// A package.json's scripts, name → command.
    static func scripts(_ package: String) -> [String: String] {
        guard let object = JSONValue(line: package.replacingOccurrences(of: "\n", with: " "))?["scripts"]?.object else { return [:] }
        return object.compactMapValues(\.string)
    }

    /// Vite's `base: '/app/'`.
    static func base(prefix: String, files: [String], read: (String) -> String?) -> String? {
        for name in ["vite.config.ts", "vite.config.js", "vite.config.mts", "vite.config.mjs"] where files.contains(prefix + name) {
            if let text = read(prefix + name), let match = text.firstMatch(of: /(?m)^\s*base\s*:\s*["'`](\/[^"'`]*)["'`]/) { return String(match.1) }
        }
        return nil
    }

    // MARK: Route

    /// The path a screen is at: from Next's or SvelteKit's folders, else from the router entry
    /// that renders its component (`<Route path="/orders" element={<OrdersPage />}>`,
    /// `{ path: '/orders', component: OrdersPage }`). Dynamic segments end the path, since
    /// there's no id to fill in. A hash router gets `/#/`.
    static func route(of screen: String, file: String?, prefix: String, next: Bool, files: [String], read: (String) -> String?) -> String? {
        if let file {
            let relative = String(file.dropFirst(prefix.count))
            let parts = relative.split(separator: "/").map(String.init)
            let stem = ((parts.last ?? "") as NSString).deletingPathExtension
            if let index = parts.firstIndex(where: { $0 == "app" || $0 == "pages" || $0 == "routes" }), index <= 1,
               stem == "page" || stem == "+page" || (parts[index] == "pages" && next) {
                var segments = Array(parts[(index + 1)..<(parts.count - 1)])
                if parts[index] == "pages", stem != "index" { segments.append(stem) }
                // Route groups "(shop)" don't show in the URL.
                segments = segments.filter { !($0.hasPrefix("(") && $0.hasSuffix(")")) }
                if let dynamic = segments.firstIndex(where: { $0.hasPrefix("[") || $0.hasPrefix(":") }) { segments = Array(segments[..<dynamic]) }
                return "/" + segments.joined(separator: "/")
            }
        }
        // The component is named for its file: OrdersPage.tsx renders <OrdersPage>.
        let component = file.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? screen
        guard component.first?.isLetter == true else { return nil }
        let code = files.filter { $0.hasPrefix(prefix) && ["ts", "tsx", "js", "jsx", "vue", "mjs"].contains(($0 as NSString).pathExtension) && !$0.contains("node_modules/") }
        for candidate in code {
            guard let text = read(candidate), SystemMap.has(text, component), SystemMap.has(text, "path") else { continue }
            let hash = SystemMap.has(text, "createHashRouter") || SystemMap.has(text, "HashRouter") || SystemMap.has(text, "createWebHashHistory")
            for occurrence in text.ranges(of: component) {
                // Used as an element or component, not where it's imported.
                let before = occurrence.lowerBound > text.startIndex ? text[text.index(before: occurrence.lowerBound)] : " "
                let lineStart = text[..<occurrence.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                let line = text[lineStart..<occurrence.lowerBound]
                if line.contains("import") { continue }
                guard before == "<" || line.contains("component") || line.contains("element") || line.contains("Component") || line.contains("path") else { continue }
                // The nearest path before it, within the same route entry.
                let windowStart = text.index(occurrence.lowerBound, offsetBy: -min(320, text.distance(from: text.startIndex, to: occurrence.lowerBound)))
                let window = String(text[windowStart..<occurrence.lowerBound])
                guard let match = window.matches(of: /path\s*[:=]\s*\{?\s*["'`]([^"'`]*)["'`]/).last else {
                    if window.range(of: #"\bindex\b"#, options: .regularExpression) != nil { return hash ? "/#/" : "/" }
                    continue
                }
                var path = String(match.1)
                if let dynamic = path.range(of: "/:") ?? path.range(of: "/*") { path = String(path[..<dynamic.lowerBound]) }
                if path.hasPrefix(":") || path == "*" { continue }
                if !path.hasPrefix("/") { path = "/" + path }
                return hash ? "/#" + path : path
            }
        }
        return nil
    }
}
