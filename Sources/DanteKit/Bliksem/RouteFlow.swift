import Foundation

/// What a route does, as a picture: its handler, the project's functions it calls (and theirs,
/// three deep), and what each touches (SQL, a transaction, a PDF or spreadsheet, a call out).
/// Read from the code with patterns, like the Map; pure.
public struct RouteFlow: Equatable, Sendable {
    public struct Step: Equatable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var file: String
        public var line: Int
        /// The block's last line.
        public var end: Int
        public var depth: Int
        /// What it does besides calling: "SQL on calculations", "renders a PDF".
        public var effects: [String]
        public var parent: Int?
    }

    public var steps: [Step]

    public static let maxDepth = 3
    public static let maxChildren = 5
    public static let maxSteps = 24

    /// The flow from the handler at `file:line`.
    public static func build(file: String, line: Int, title: String, files: [String], read: (String) -> String?) -> RouteFlow? {
        guard let text = read(file), let body = block(in: text, line: line, python: file.hasSuffix(".py")) else { return nil }
        let family = languageFamily(file)
        // Declarations of functions in the same language, by name.
        var declared: [String: (file: String, line: Int)] = [:]
        for candidate in files where languageFamily(candidate) == family && !SystemMap.isTest(candidate) {
            guard let source = read(candidate) else { continue }
            for symbol in DeclarationScanner.symbols(in: source, language: Language(url: URL(fileURLWithPath: candidate)), url: URL(fileURLWithPath: candidate))
            where symbol.kind == .function || symbol.kind == .method {
                if declared[symbol.name] == nil { declared[symbol.name] = (candidate, symbol.range.start.line + 1) }
            }
        }
        var steps = [Step(id: 0, name: title, file: file, line: line, end: line + body.filter { $0 == "\n" }.count, depth: 0, effects: effects(in: body), parent: nil)]
        var visited: Set<String> = [file + ":\(line)"]
        var queue: [(Int, String)] = [(0, body)]
        while !queue.isEmpty, steps.count < maxSteps {
            let (parent, code) = queue.removeFirst()
            let depth = steps[parent].depth + 1
            guard depth <= maxDepth else { continue }
            var children = 0
            for name in calls(in: code) where children < maxChildren && steps.count < maxSteps {
                guard let place = declared[name], visited.insert(place.file + ":\(place.line)").inserted,
                      let source = read(place.file), let inner = block(in: source, line: place.line, python: place.file.hasSuffix(".py")) else { continue }
                let step = Step(id: steps.count, name: name, file: place.file, line: place.line,
                                end: place.line + inner.filter { $0 == "\n" }.count, depth: depth, effects: effects(in: inner), parent: parent)
                steps.append(step)
                queue.append((step.id, inner))
                children += 1
            }
        }
        return RouteFlow(steps: steps)
    }

    static func languageFamily(_ file: String) -> String {
        switch (file as NSString).pathExtension.lowercased() {
        case "kt", "kts", "java": "jvm"
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": "js"
        case let other: other
        }
    }

    /// The code from `line` (1-based) to the end of the block it opens: braces matched outside
    /// strings and comments, or for Python the lines indented under the `def`.
    public static func block(in text: String, line: Int, python: Bool = false, limit: Int = 400) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return nil }
        let start = line - 1
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        if python || first.hasPrefix("def ") || first.hasPrefix("async def ") {
            // Python: from the def to the first line indented no deeper than it.
            guard let def = lines[start...].prefix(8).firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("def ") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("async def ") }) else { return nil }
            let indent = lines[def].prefix { $0 == " " || $0 == "\t" }.count
            var end = def + 1
            while end < lines.count, end - def < limit {
                let row = lines[end]
                if !row.trimmingCharacters(in: .whitespaces).isEmpty, row.prefix(while: { $0 == " " || $0 == "\t" }).count <= indent { break }
                end += 1
            }
            return lines[start..<end].joined(separator: "\n")
        }
        let rest = lines[start..<min(lines.count, start + limit)].joined(separator: "\n")
        var depth = 0
        var opened = false
        var index = rest.startIndex
        var inString: Character?
        while index < rest.endIndex {
            let char = rest[index]
            if let quote = inString {
                if char == "\\" { index = rest.index(after: index) } else if char == quote { inString = nil }
            } else if char == "\"" || char == "'" || char == "`" {
                inString = char
            } else if char == "/", rest[rest.index(after: index)...].hasPrefix("/") {
                index = rest[index...].firstIndex(of: "\n") ?? rest.endIndex
                continue
            } else if char == "{" {
                depth += 1
                opened = true
            } else if char == "}" {
                depth -= 1
                if opened, depth == 0 { return String(rest[...index]) }
            } else if char == "\n", !opened, rest[..<index].filter({ $0 == "\n" }).count >= 6 {
                return nil
            }
            if index < rest.endIndex { index = rest.index(after: index) }
        }
        return opened ? rest : nil
    }

    private static let call = try! NSRegularExpression(pattern: #"\b([A-Za-z_]\w*)\s*(?:<[^<>()]*>)?\s*\("#)
    static let notCalls: Set<String> = ["if", "for", "while", "switch", "when", "catch", "return", "fun", "def", "func", "function", "print", "println",
                                         "listOf", "mapOf", "setOf", "require", "check", "let", "also", "apply", "run", "with", "get", "post", "put",
                                         "patch", "delete", "route", "respond", "respondText", "receive", "len", "str", "int", "dict", "list", "super", "this"]

    /// Names called in the code, in order, each once.
    static func calls(in code: String) -> [String] {
        let ns = code as NSString
        var seen = Set<String>()
        var names: [String] = []
        for match in call.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            guard !notCalls.contains(name), name.first?.isLowercase == true || name.contains("_"), seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }

    private static let sql = try! NSRegularExpression(pattern: #"(?i)\b(?:from|into|update|join)\s+"?([a-z_][\w.]*)"#)
    private static let effectWords: [(String, [String])] = [
        ("database transaction", ["transaction {", "transaction(", "@Transactional", "BEGIN", "session.commit", "db.Begin"]),
        ("renders a PDF", ["PDDocument", "PdfWriter", "PDPage", "reportlab", "pdfkit", "jsPDF", ".pdf("]),
        ("writes a spreadsheet", ["Workbook", "XSSF", "openpyxl", "xlsxwriter", "exceljs", "Worksheet"]),
        ("calls out over HTTP", ["HttpClient", "httpClient", "fetch(", "axios", "requests.", "http.Get", "http.Post", "RestTemplate", "WebClient"]),
        ("encrypts or hashes", ["Cipher", "MessageDigest", "bcrypt", "argon2", "SecretKey", "hashlib", "crypto."]),
        ("waits", ["Thread.sleep", "delay(", "time.sleep", "setTimeout("]),
        ("reads or writes files", ["File(", "Files.", "open(", "fs.", "os.ReadFile", "os.WriteFile"]),
    ]

    static func effects(in code: String) -> [String] {
        var found: [String] = []
        let ns = code as NSString
        if code.range(of: #"(?i)\b(select|insert|update|delete)\b[^"\n]*\b(from|into|set)\b"#, options: .regularExpression) != nil {
            var tables: [String] = []
            for match in sql.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                if !tables.contains(name), !["the", "a", "an", "it", "this", "select"].contains(name.lowercased()) { tables.append(name) }
            }
            found.append(tables.isEmpty ? "runs SQL" : "SQL on " + tables.prefix(3).joined(separator: ", "))
        }
        for (label, words) in effectWords where words.contains(where: code.contains) { found.append(label) }
        return found
    }

    /// The share of busy samples in each step: frames from its file and named like it (or, for
    /// the handler, any frame from its file).
    public func heat(_ profile: Profile) -> [Int: Double] {
        let (busy, _) = profile.methods()
        guard busy > 0 else { return [:] }
        var counts: [Int: Int] = [:]
        for stack in profile.stacks where stack.contains(where: profile.isOwn) {
            for step in steps {
                let stem = ((step.file as NSString).lastPathComponent as NSString).deletingPathExtension
                let hit = stack.contains { frame in Self.frame(frame, isIn: step, stem: stem) }
                if hit { counts[step.id, default: 0] += 1 }
            }
        }
        return counts.mapValues { Double($0) / Double(busy) }
    }

    /// Stacks that ran this route's handler.
    public func isRoute(_ stack: [StackFrame]) -> Bool {
        guard let handler = steps.first else { return false }
        let stem = ((handler.file as NSString).lastPathComponent as NSString).deletingPathExtension
        return stack.contains { Self.frame($0, isIn: handler, stem: stem) }
    }

    /// A frame runs a step's code: from its file, and inside its lines when the dump gives a
    /// line, else named like it.
    static func frame(_ frame: StackFrame, isIn step: Step, stem: String) -> Bool {
        let fromFile = frame.file.map { ($0 as NSString).deletingPathExtension == stem } ?? (frame.simpleType == stem || frame.simpleType == stem + "Kt")
        guard fromFile else { return false }
        if let line = frame.line { return line >= step.line && line <= step.end }
        return step.depth == 0 || frame.method == step.name || frame.method.hasPrefix(step.name + "$")
    }
}
