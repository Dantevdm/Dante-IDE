import Foundation

/// Ktor's routing DSL: `routing { route("/api") { get("/orders") { … } } }`, with route
/// functions (`fun Route.orderRoutes() { … }`) written in other files and called inside a
/// `route` block, which puts their routes under its prefix.
extension SystemMap {
    /// Whether a Kotlin file may hold Ktor routes.
    static func isKtor(_ file: String, _ body: String) -> Bool {
        (file.hasSuffix(".kt") || file.hasSuffix(".kts")) && (has(body, "io.ktor") || has(body, "fun Route.") || has(body, "routing {"))
    }

    /// The Ktor routes of every Kotlin file, by file, with route functions placed under the
    /// prefixes they're called from. Files with none are left out.
    static func ktorRoutes(files: [String], text: (String) -> String) -> [String: [Route]] {
        let kotlin = files.filter { isKtor($0, text($0)) }
        guard !kotlin.isEmpty else { return [:] }
        var functions = Set<String>()
        for file in kotlin {
            let body = text(file)
            let ns = body as NSString
            for match in routeFunction.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                functions.insert(ns.substring(with: match.range(at: 1)))
            }
        }
        // Where each route function is called from, settled over a few passes, since route
        // functions call each other.
        var mounts: [String: Set<String>] = [:]
        var results: [String: KtorScan] = [:]
        for _ in 0..<4 {
            var next: [String: Set<String>] = [:]
            for file in kotlin {
                let scan = ktorScan(text(file), functions: functions, mounts: mounts)
                results[file] = scan
                for (name, prefixes) in scan.calls { next[name, default: []].formUnion(prefixes) }
            }
            if next == mounts { break }
            mounts = next
        }
        return results.compactMapValues { $0.routes.isEmpty ? nil : $0.routes }
    }

    private static let routeFunction = try! NSRegularExpression(pattern: #"fun\s+Route\.(\w+)\s*\("#)
    private static let verbs: Set<String> = ["get", "post", "put", "patch", "delete", "head", "options"]

    struct KtorScan {
        var routes: [Route] = []
        /// Route functions called, with the prefixes they were called under.
        var calls: [String: Set<String>] = [:]
    }

    /// One file's routes. `mounts` gives the prefixes each route function is called under
    /// (a function nobody calls is read as if mounted at the root).
    static func ktorScan(_ text: String, functions: Set<String> = [], mounts: [String: Set<String>] = [:]) -> KtorScan {
        let chars = Array(text.utf16)
        let count = chars.count
        var lineStarts = [0]
        for (index, char) in chars.enumerated() where char == 10 { lineStarts.append(index + 1) }
        func line(_ offset: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low + 1
        }
        func isWord(_ c: UInt16) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        func skipSpace(_ i: Int) -> Int {
            var i = i
            while i < count, [32, 9, 10, 13].contains(chars[i]) { i += 1 }
            return i
        }
        /// A plain string literal at `i`: its text and the index after it.
        func string(at i: Int) -> (String, Int)? {
            guard i < count, chars[i] == 34 else { return nil }
            var j = i + 1
            while j < count, chars[j] != 34 {
                if chars[j] == 92 { j += 1 }
                if chars[j] == 10 { return nil }
                j += 1
            }
            guard j < count else { return nil }
            return (String(utf16CodeUnits: Array(chars[(i + 1)..<j]), count: j - i - 1), j + 1)
        }

        var scan = KtorScan()
        // Each open brace's prefixes; the bottom one is the file's top level.
        var stack: [Set<String>] = [[""]]
        // The prefixes the next `{` opens with: after `route("/x")` or a route function's head.
        var pending: Set<String>?
        var i = 0
        while i < count {
            let c = chars[i]
            // Comments, strings and characters.
            if c == 47, i + 1 < count, chars[i + 1] == 47 {
                while i < count, chars[i] != 10 { i += 1 }
                continue
            }
            if c == 47, i + 1 < count, chars[i + 1] == 42 {
                i += 2
                while i + 1 < count, !(chars[i] == 42 && chars[i + 1] == 47) { i += 1 }
                i += 2
                continue
            }
            if c == 34 {
                if i + 2 < count, chars[i + 1] == 34, chars[i + 2] == 34 {
                    i += 3
                    while i + 2 < count, !(chars[i] == 34 && chars[i + 1] == 34 && chars[i + 2] == 34) { i += 1 }
                    i += 3
                } else {
                    i += 1
                    while i < count, chars[i] != 34, chars[i] != 10 {
                        if chars[i] == 92 { i += 1 }
                        i += 1
                    }
                    i += 1
                }
                continue
            }
            if c == 39 {
                i += 1
                while i < count, chars[i] != 39, chars[i] != 10 {
                    if chars[i] == 92 { i += 1 }
                    i += 1
                }
                i += 1
                continue
            }
            if c == 123 {
                stack.append(pending ?? stack.last!)
                pending = nil
                i += 1
                continue
            }
            if c == 125 {
                if stack.count > 1 { stack.removeLast() }
                i += 1
                continue
            }
            // A word not after a dot or another word.
            guard isWord(c), i == 0 || (!isWord(chars[i - 1]) && chars[i - 1] != 46) else {
                i += 1
                continue
            }
            var end = i
            while end < count, isWord(chars[end]) { end += 1 }
            let word = String(utf16CodeUnits: Array(chars[i..<end]), count: end - i)
            let current = stack.last!
            let after = skipSpace(end)
            if word == "fun" {
                // `fun Route.name(` opens with the prefixes it's called under.
                let rest = String(utf16CodeUnits: Array(chars[after..<min(count, after + 120)]), count: min(count, after + 120) - after)
                if rest.hasPrefix("Route."), let name = rest.dropFirst(6).split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).first {
                    pending = mounts[String(name)] ?? [""]
                }
            } else if word == "route", after < count, chars[after] == 40, let (path, next) = string(at: skipSpace(after + 1)) {
                pending = Set(current.map { join($0, path) })
                i = next
                continue
            } else if verbs.contains(word) {
                var path: String?
                var opens = false
                if after < count, chars[after] == 123 {
                    path = ""
                    opens = true
                } else if after < count, chars[after] == 40, let (text, next) = string(at: skipSpace(after + 1)) {
                    let close = skipSpace(next)
                    if close < count, chars[close] == 41, skipSpace(close + 1) < count, chars[skipSpace(close + 1)] == 123 {
                        path = text
                        opens = true
                    }
                }
                if opens, let path {
                    let at = line(i)
                    for prefix in current.sorted() {
                        let full = join(prefix, path)
                        scan.routes.append(Route(method: word.uppercased(), path: full, line: at))
                    }
                }
            } else if functions.contains(word), after < count, chars[after] == 40 {
                scan.calls[word, default: []].formUnion(current)
            }
            i = end
        }
        return scan
    }
}
