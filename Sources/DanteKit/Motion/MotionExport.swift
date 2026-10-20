import Foundation

/// A piece as one HTML file that plays in any browser, offline, with nothing beside it: the
/// runtime in browser mode (it plays itself, a deck holds at each stop and the arrow keys move
/// on), the scene's modules and the libraries they import carried inside the page and turned
/// into blob URLs by a small loader (so no server is needed: browsers refuse modules from
/// file://), and its images, fonts and data as data URLs.
///
/// Files are named by key: `piece:<path>` in the piece's folder, `lib:<path>` in the bundled
/// libraries, `project:<path>` in the repo (served as `_dante/project/`), `fonts:<name>`.
public enum MotionExport {
    public struct Result: Equatable, Sendable {
        public var html: String
        /// Modules and files the page names that couldn't be found or carried.
        public var missing: [String]
        /// Set when modules import each other in a circle, which the loader can't carry.
        public var cycle: [String]?
    }

    /// Where an export goes: `renders/<folder name>.html`, beside the videos.
    public static func fileName(for folder: String) -> String {
        "renders/\((folder as NSString).lastPathComponent).html"
    }

    /// The largest file carried inside the page, and the most in all.
    public static let largestFile = 30_000_000, mostInAll = 160_000_000

    /// Builds the page from the scene's HTML (`piece:<scene>`). `runtime` is the runtime script
    /// in browser mode; `read` returns a key's bytes, or nil when it's missing or refused.
    public static func page(scene: String, html: String, runtime: String, fonts: [String] = [], read: @escaping (String) -> Data?) -> Result {
        var builder = Builder(read: read)
        let sceneKey = "piece:" + scene
        var page = html
        // The page's own import map goes: every import is resolved here.
        page = page.replacing(/<script[^>]*type\s*=\s*["']importmap["'][^>]*>[\s\S]*?<\/script>\s*/.ignoresCase(), with: "")

        // Module scripts become entries for the loader, in the order the page has them.
        var entries: [Int] = []
        page = replacingMatches(in: page, of: #"<script\b([^>]*)>([\s\S]*?)</script>"#) { groups in
            let attributes = groups[1], body = groups[2]
            let isModule = attribute("type", in: attributes)?.lowercased() == "module"
            if let src = attribute("src", in: attributes) {
                guard let key = resolve(src, from: sceneKey) else { builder.missing.append(src); return groups[0] }
                if isModule {
                    if let index = builder.module(key) { entries.append(index) } else { builder.missing.append(src) }
                    return ""
                }
                guard let data = builder.read(key), let code = String(data: data, encoding: .utf8) else { builder.missing.append(src); return groups[0] }
                return "<script>\(scriptSafe(builder.inliningAssets(in: code, from: key)))</script>"
            }
            if isModule {
                if let index = builder.module(source: body, key: sceneKey) { entries.append(index) }
                return ""
            }
            return groups[0]
        }
        // Local stylesheets come inside.
        page = replacingMatches(in: page, of: #"<link\b([^>]*)>"#) { groups in
            let attributes = groups[1]
            guard attribute("rel", in: attributes)?.lowercased() == "stylesheet", let href = attribute("href", in: attributes),
                  let key = resolve(href, from: sceneKey) else { return groups[0] }
            guard let data = builder.read(key), let css = String(data: data, encoding: .utf8) else { builder.missing.append(href); return groups[0] }
            return "<style>\(builder.inliningAssets(in: css, from: key))</style>"
        }
        // Images, inline styles and the rest of the page.
        page = builder.inliningAssets(in: page, from: sceneKey)

        var head = "<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        let faces = fonts.compactMap { name -> String? in
            guard let data = builder.read("fonts:" + name) else { return nil }
            let family = name.hasPrefix("GeistMono") ? "Geist Mono" : "Geist"
            let style = name.contains("Italic") ? "italic" : "normal"
            return "@font-face{font-family:\"\(family)\";src:url(data:font/ttf;base64,\(data.base64EncodedString()));font-weight:100 900;font-style:\(style)}"
        }
        if !faces.isEmpty { head += "<style>\(faces.joined(separator: "\n"))</style>\n" }
        head += "<script>\(scriptSafe(runtime))</script>\n"
        page = inserting(head, intoHeadOf: page)

        var cycle: [String]?
        if !entries.isEmpty {
            switch builder.ordered() {
            case .success(let order):
                let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
                let sources = order.map { builder.modules[$0].code(position: position) }
                let json = (try? JSONSerialization.data(withJSONObject: sources)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
                let loader = """
                <script type="application/json" id="dante-modules">\(json.replacingOccurrences(of: "</", with: "<\\/"))</script>
                <script>
                (async () => {
                  const sources = JSON.parse(document.getElementById("dante-modules").textContent), urls = [];
                  for (const source of sources) {
                    const code = source.replace(/__DANTE_MODULE_(\\d+)__/g, (_, i) => urls[Number(i)]);
                    urls.push(URL.createObjectURL(new Blob([code], { type: "text/javascript" })));
                  }
                  for (const entry of \(entries.compactMap { position[$0] })) await import(urls[entry]);
                })().catch((error) => { document.body.insertAdjacentHTML("beforeend", `<pre style="position:fixed;left:16px;bottom:16px;color:#f66;font:13px monospace;white-space:pre-wrap">${String(error && error.stack || error)}</pre>`); });
                </script>
                """
                page = inserting(loader, beforeBodyEndOf: page)
            case .failure(let circle):
                cycle = circle.keys
            }
        }
        var seen: Set<String> = []
        return Result(html: page, missing: builder.missing.filter { seen.insert($0).inserted }, cycle: cycle)
    }

    // MARK: Resolving

    /// A specifier or URL from the file `from`, as a key; nil for the network and anything
    /// that climbs out of where it lives.
    public static func resolve(_ specifier: String, from: String) -> String? {
        let spec = specifier.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty, !spec.hasPrefix("data:"), !spec.hasPrefix("blob:"), !spec.hasPrefix("#"), !spec.contains("://"), !spec.hasPrefix("//") else { return nil }
        let path = spec.split(separator: "?", maxSplits: 1).first.map(String.init)?.split(separator: "#", maxSplits: 1).first.map(String.init) ?? spec
        // Bare specifiers, through the libraries' import map.
        if !path.hasPrefix("/"), !path.hasPrefix("."), let mapped = mapped(path) { return mapped }
        for (prefix, namespace) in [(MotionLibrary.path, "lib:"), (MotionRuntime.projectPath, "project:"), (MotionRuntime.fontsPath, "fonts:")] {
            for candidate in ["/" + prefix, prefix] where path.hasPrefix(candidate) {
                return normalised(String(path.dropFirst(candidate.count))).map { namespace + $0 }
            }
        }
        if path.hasPrefix("/") { return normalised(String(path.dropFirst())).map { "piece:" + $0 } }
        guard let colon = from.firstIndex(of: ":") else { return nil }
        let namespace = String(from[...colon]), file = String(from[from.index(after: colon)...])
        let directory = (file as NSString).deletingLastPathComponent
        return normalised(directory.isEmpty ? path : directory + "/" + path).map { namespace + $0 }
    }

    static func mapped(_ path: String) -> String? {
        let imports = MotionLibrary.all.flatMap(\.imports)
        if let exact = imports.first(where: { $0.specifier == path }) { return "lib:" + exact.path }
        let prefix = imports.filter { $0.specifier.hasSuffix("/") && path.hasPrefix($0.specifier) }.max { $0.specifier.count < $1.specifier.count }
        return prefix.flatMap { normalised($0.path + path.dropFirst($0.specifier.count)) }.map { "lib:" + $0 }
    }

    /// `a/./b/../c` → `a/c`; nil when it climbs out.
    static func normalised(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if parts.isEmpty { return nil } else { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    // MARK: Modules

    /// The import specifiers in a module: static imports, re-exports and dynamic imports with
    /// a literal, each with its range in `code`. Statements in comments are skipped.
    public static func imports(in code: String) -> [(specifier: String, range: NSRange)] {
        let text = code as NSString
        var found: [(String, NSRange)] = []
        for expression in [staticImport, dynamicImport] {
            for match in expression.matches(in: code, range: NSRange(location: 0, length: text.length)) {
                let lineStart = text.lineRange(for: NSRange(location: match.range.location, length: 0)).location
                let before = text.substring(with: NSRange(location: lineStart, length: match.range.location - lineStart)).trimmingCharacters(in: .whitespaces)
                if before.hasPrefix("//") || before.hasPrefix("*") || before.hasPrefix("/*") { continue }
                let range = match.range(at: 1)
                found.append((text.substring(with: range), range))
            }
        }
        return found.sorted { $0.1.location < $1.1.location }
    }

    // `import x from "y"`, `import "y"`, `export * from "y"`, `export { a } from "y"`, at a statement's start.
    static let staticImport = try! NSRegularExpression(pattern: #"(?:^|[;}])[ \t]*(?:import|export)\s*(?:[\w$*{}\s,]+?\s*from\s*)?["']([^"'\n]+)["']"#, options: [.anchorsMatchLines])
    static let dynamicImport = try! NSRegularExpression(pattern: #"\bimport\s*\(\s*["']([^"'\n]+)["']\s*\)"#)

    struct Module {
        var key: String
        var code: String
        /// Where each dependency's specifier sits in `code`, and which module it is.
        var dependencies: [(range: NSRange, module: Int)]

        /// The code with each dependency's specifier swapped for its placeholder.
        func code(position: [Int: Int]) -> String {
            let text = NSMutableString(string: code)
            for dependency in dependencies.sorted(by: { $0.range.location > $1.range.location }) {
                text.replaceCharacters(in: dependency.range, with: "__DANTE_MODULE_\(position[dependency.module] ?? 0)__")
            }
            return text as String
        }
    }

    struct Builder {
        let reader: (String) -> Data?
        var modules: [Module] = []
        var index: [String: Int] = [:]
        var missing: [String] = []
        var carried = 0

        init(read: @escaping (String) -> Data?) { reader = read }

        mutating func read(_ key: String) -> Data? {
            guard let data = reader(key) else { return nil }
            guard data.count <= MotionExport.largestFile, carried + data.count <= MotionExport.mostInAll else {
                missing.append("\(key.split(separator: ":", maxSplits: 1).last ?? "") (too large to carry)")
                return nil
            }
            carried += data.count
            return data
        }

        /// The module at `key`, read and added with everything it imports.
        mutating func module(_ key: String) -> Int? {
            if let existing = index[key] { return existing }
            guard let data = read(key), let code = String(data: data, encoding: .utf8) else { return nil }
            return module(source: code, key: key)
        }

        /// Adds `source` as a module living at `key` (a page's inline module lives at the page).
        mutating func module(source: String, key: String) -> Int? {
            let position = modules.count
            modules.append(Module(key: key, code: "", dependencies: []))
            if !key.hasSuffix(".html") { index[key] = position }
            // Assets first, then imports, so ranges stay true.
            let code = key.hasPrefix("lib:") ? source : inliningAssets(in: source, from: key)
            var dependencies: [(NSRange, Int)] = []
            for (specifier, range) in MotionExport.imports(in: code) {
                guard let target = MotionExport.resolve(specifier, from: key), let dependency = module(target) else {
                    missing.append(specifier)
                    continue
                }
                dependencies.append((range, dependency))
            }
            modules[position] = Module(key: key, code: code, dependencies: dependencies)
            return position
        }

        /// Modules in an order where each comes after what it imports, or the circle found.
        func ordered() -> Swift.Result<[Int], Circle> {
            var order: [Int] = [], state = [Int: Bool]()   // false: visiting, true: done
            var stack: [Int] = []
            func visit(_ node: Int) -> Circle? {
                if state[node] == true { return nil }
                if state[node] == false {
                    let start = stack.firstIndex(of: node) ?? 0
                    return Circle(keys: (stack[start...] + [node]).map { modules[$0].key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "" })
                }
                state[node] = false
                stack.append(node)
                for dependency in modules[node].dependencies {
                    if let circle = visit(dependency.module) { return circle }
                }
                stack.removeLast()
                state[node] = true
                order.append(node)
                return nil
            }
            for node in modules.indices {
                if let circle = visit(node) { return .failure(circle) }
            }
            return .success(order)
        }

        /// Swaps paths to files the scene names (images, fonts, models, data) for data URLs.
        mutating func inliningAssets(in text: String, from key: String) -> String {
            MotionExport.replacingMatches(in: text, of: MotionExport.assetPattern) { groups in
                let path = groups[2].isEmpty ? groups[3] : groups[2]
                let ext = (path.split(separator: "?").first.map(String.init).map { ($0 as NSString).pathExtension.lowercased() }) ?? ""
                guard MotionRuntime.servedExtensions.contains(ext), let target = MotionExport.resolve(path, from: key) else { return groups[0] }
                guard let data = read(target) else {
                    if !path.contains("://") { missing.append(path) }
                    return groups[0]
                }
                let url = "data:\(MotionRuntime.mimeType(for: path));base64,\(data.base64EncodedString())"
                return groups[0].replacingOccurrences(of: path, with: url)
            }
        }
    }

    struct Circle: Error { var keys: [String] }

    // A quoted path or an unquoted url(…) ending in a file extension.
    static let assetPattern = #"(["'`(])(?:([^"'`()\s<>]+\.[A-Za-z0-9]{2,5}(?:\?[^"'`()\s]*)?)(?=["'`])|url\(\s*([^"'()\s]+\.[A-Za-z0-9]{2,5})\s*(?=\)))"#

    // MARK: Text

    /// A string that can sit inside `<script>`.
    static func scriptSafe(_ code: String) -> String {
        code.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
    }

    static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: .caseInsensitive)
        guard let match = pattern.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)) else { return nil }
        for group in 1...3 where match.range(at: group).location != NSNotFound {
            return (attributes as NSString).substring(with: match.range(at: group))
        }
        return nil
    }

    /// Replaces each match of `pattern`; `transform` gets the whole match and its groups ("" for a group that didn't take part).
    static func replacingMatches(in text: String, of pattern: String, _ transform: ([String]) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let source = text as NSString
        let result = NSMutableString()
        var last = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result.append(source.substring(with: NSRange(location: last, length: match.range.location - last)))
            let groups = (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : source.substring(with: match.range(at: $0)) }
            result.append(transform(groups))
            last = match.range.location + match.range.length
        }
        result.append(source.substring(from: last))
        return result as String
    }

    static func inserting(_ html: String, intoHeadOf page: String) -> String {
        for tag in ["<head", "<html"] {
            if let open = page.range(of: tag, options: .caseInsensitive), let close = page.range(of: ">", range: open.upperBound..<page.endIndex) {
                return page.replacingCharacters(in: close.upperBound..<close.upperBound, with: "\n" + html)
            }
        }
        return html + page
    }

    static func inserting(_ html: String, beforeBodyEndOf page: String) -> String {
        guard let close = page.range(of: "</body", options: [.caseInsensitive, .backwards]) else { return page + "\n" + html }
        return page.replacingCharacters(in: close.lowerBound..<close.lowerBound, with: html + "\n")
    }
}
