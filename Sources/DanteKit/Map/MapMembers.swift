import Foundation

/// The deepest levels of the map, and the way back from the data: a file opens into its
/// methods (the routes each serves, the tables each queries, the project's classes each
/// uses, the calls between them), and a table opens into the code that reaches it, from the
/// repository or query up through services to the controllers and routes. Pure.
extension SystemMap {
    /// A method, function or type in a file. Lines are 1-based; `end` is the line before the
    /// next declaration.
    struct Member: Equatable, Sendable {
        var name: String
        var line: Int
        var end: Int
        var isType: Bool
        var signature: String
    }

    /// A column from `CREATE TABLE`, with the table it references.
    public struct Column: Equatable, Sendable {
        public var name: String
        public var type: String
        public var references: String?
    }

    static func stem(_ file: String) -> String {
        ((file as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Languages where a class is used by its name rather than by importing its file.
    static func namesTypes(_ file: String) -> Bool {
        ["java", "kt", "cs", "swift", "php", "scala"].contains((file as NSString).pathExtension.lowercased())
    }

    /// Every identifier in the text.
    static func identifiers(_ text: String) -> Set<String> {
        var found: Set<String> = []
        var current = ""
        for scalar in text.unicodeScalars {
            if scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                found.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { found.insert(current) }
        return found
    }

    /// "controller · 4 methods", "12 functions".
    static func fileRole(_ file: String, text: String) -> String {
        let roles: [(marker: String, name: String)] = [
            ("@RestController", "controller"), ("@Controller", "controller"), ("@Service", "service"), ("@Repository", "repository"),
            ("Repository<", "repository"), ("@Entity", "entity"), ("@Configuration", "configuration"), ("@ControllerAdvice", "error handler"),
            ("@Component", "component"),
        ]
        var role = isJVM(file) ? roles.first { has(text, $0.marker) }?.name : nil
        if role == nil, isJVM(file), text.firstMatch(of: /(?m)^\s*(?:public\s+)?(?:sealed\s+)?interface\s+\w/) != nil { role = "interface" }
        if role == nil, isJVM(file), text.firstMatch(of: /(?m)^\s*(?:public\s+)?record\s+\w/) != nil { role = "record" }
        let count = members(of: file, text: text).filter { !$0.isType }.count
        let word = namesTypes(file) ? "method" : "function"
        let size = count > 0 ? "\(count) \(word)\(count == 1 ? "" : "s")" : "\(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines"
        return [role, size].compactMap { $0 }.joined(separator: " · ")
    }

    nonisolated(unsafe) static let javaMethodPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|protected|static|final|abstract|synchronized|default|native)\s+)*(?:<[^>]*>\s+)?([\w.$]+(?:<.*?>)?(?:\[\])*)\s+(\w+)\s*\("#)

    /// The file's declarations, in order. The type a file is named for wraps the rest, so it's
    /// left out when there's more.
    static func members(of file: String, text: String) -> [Member] {
        let lines = text.components(separatedBy: "\n")
        let url = URL(filePath: "/" + file)
        let language = Language(url: url)
        var found: [(name: String, line: Int, isType: Bool)] = []
        for symbol in DeclarationScanner.symbols(in: text, language: language, url: url) where symbol.kind == .type || symbol.kind == .function {
            found.append((symbol.name, symbol.range.start.line + 1, symbol.kind == .type))
        }
        if language == .java {
            let notTypes: Set<String> = ["return", "new", "else", "throw", "case", "package", "import", "yield", "assert"]
            let notNames: Set<String> = ["if", "for", "while", "switch", "catch", "synchronized", "return", "super", "this"]
            for (index, line) in lines.enumerated() where line.contains("(") {
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else { continue }
                let range = NSRange(line.startIndex..., in: line)
                guard let match = javaMethodPattern.firstMatch(in: line, range: range),
                      let typeRange = Range(match.range(at: 1), in: line), let nameRange = Range(match.range(at: 2), in: line),
                      !notTypes.contains(String(line[typeRange])), !notNames.contains(String(line[nameRange])),
                      !line[..<nameRange.lowerBound].contains("=") else { continue }
                found.append((String(line[nameRange]), index + 1, false))
            }
        }
        found.sort { $0.line < $1.line }
        let own = stem(file)
        if found.contains(where: { !$0.isType }) { found.removeAll { $0.isType && $0.name == own } }
        var members: [Member] = []
        for item in found where !members.contains(where: { $0.line == item.line }) {
            let signature = lines[item.line - 1].trimmingCharacters(in: .whitespaces)
            members.append(Member(name: item.name, line: item.line, end: lines.count, isType: item.isType,
                                  signature: signature.count > 140 ? String(signature.prefix(139)) + "…" : signature))
        }
        for index in members.indices {
            var end = index + 1 < members.count ? members[index + 1].line - 1 : lines.count
            // Not the blank lines, annotations and doc comment before the next one.
            func leadsIn(_ line: String) -> Bool {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || trimmed.hasPrefix("@") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("//")
                    || trimmed.hasPrefix("#") || trimmed.hasPrefix("///")
            }
            while end > members[index].line, leadsIn(lines[end - 1]) { end -= 1 }
            members[index].end = end
        }
        return Array(members.prefix(48))
    }

    /// Fields and parameters typed with one of `types`: `private final JobService jobs;`,
    /// `val jobs: JobService`. Name → type.
    static func fieldTypes(in text: String, types: Set<String>) -> [String: String] {
        var found: [String: String] = [:]
        for match in text.matches(of: /([A-Z]\w*)(?:<[^>\n]*>)?\s+(\w+)\s*[;=,)]/) where types.contains(String(match.1)) {
            found[String(match.2)] = String(match.1)
        }
        for match in text.matches(of: /(\w+)\s*:\s*([A-Z]\w*)/) where types.contains(String(match.2)) {
            found[String(match.1)] = String(match.2)
        }
        return found
    }

    /// The project's files a file uses, by the name it knows each by: classes named in the
    /// text (Java, Kotlin, C#, Swift), else imported names (JavaScript, Python).
    static func references(from file: String, text: String, files: [String]) -> [String: String] {
        var found: [String: String] = [:]
        let folder = (file as NSString).deletingLastPathComponent
        if namesTypes(file) {
            let words = identifiers(text)
            let ext = (file as NSString).pathExtension.lowercased()
            let family: Set<String> = ext == "java" || ext == "kt" ? ["java", "kt"] : [ext]
            func shared(_ other: String) -> Int { zip(other, file).prefix { $0 == $1 }.count }
            for other in files where other != file && family.contains((other as NSString).pathExtension.lowercased()) && isCode(other) {
                let name = stem(other)
                guard name.first?.isUppercase == true, name.count >= 3, words.contains(name) else { continue }
                // The same name in two places: the nearer one.
                if let known = found[name], shared(known) >= shared(other) { continue }
                found[name] = other
            }
            return found
        }
        let set = Set(files)
        func resolve(_ path: String) -> String? {
            let base = ArchitectureGraph.normalised(path)
            for candidate in [base] + ["ts", "tsx", "js", "jsx", "mjs", "vue", "svelte", "py"].map({ base + "." + $0 }) + ["index.ts", "index.tsx", "index.js", "__init__.py"].map({ base + "/" + $0 })
            where set.contains(candidate) { return candidate }
            return nil
        }
        switch (file as NSString).pathExtension.lowercased() {
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte":
            for match in text.matches(of: /import\s+(?:type\s+)?([^;]*?)\s+from\s+["'](\.[^"']*)["']/) {
                guard let target = resolve(folder + "/" + match.2) else { continue }
                for name in identifiers(String(match.1)) where !["as", "type", "default"].contains(name) { found[name] = target }
            }
        case "py":
            for match in text.matches(of: /(?m)^\s*from\s+(\.+)([\w.]*)\s+import\s+([^\n#]+)/) {
                var target = folder
                for _ in 1..<max(match.1.count, 1) { target = (target as NSString).deletingLastPathComponent }
                guard let path = resolve(target + "/" + match.2.replacingOccurrences(of: ".", with: "/")) else { continue }
                for name in identifiers(String(match.3)) where name != "as" && name != "import" { found[name] = path }
            }
        default:
            break
        }
        return found
    }

    /// Table names from the repo's SQL.
    static func knownTables(files: [String], read: (String) -> String?) -> [String] {
        var found: [String] = []
        for file in files where (file as NSString).pathExtension.lowercased() == "sql" && !isTest(file) {
            guard let text = read(file), has(text.lowercased(), "create table") else { continue }
            for table in tables(in: text) where !found.contains(table) { found.append(table) }
        }
        return found
    }

    // MARK: A file

    /// The map inside one file: its declarations in the middle, the routes they serve, the
    /// tables they query and the project's classes they use. Nil with fewer than two.
    static func inside(file: String, files: [String], read: (String) -> String?) -> SystemMap? {
        guard let text = read(file) else { return nil }
        let members = members(of: file, text: text)
        guard members.count >= 2 else { return nil }
        let lines = text.components(separatedBy: "\n")
        func body(_ member: Member) -> String { lines[(member.line - 1)..<min(member.end, lines.count)].joined(separator: "\n") }
        var parts: [Part] = []
        var links: [String: Link] = [:]
        func link(_ from: String, _ to: String) {
            guard from != to else { return }
            links["\(from)→\(to)", default: Link(from: from, to: to, weight: 0)].weight += 1
        }
        let ids = members.map { "member:\(file)#\($0.name)@\($0.line)" }

        // Routes, each to the method that handles it.
        var served: [Int: [String]] = [:]
        let found = isJVM(file) ? annotatedRoutes(in: text) : routes(in: text)
        for route in found {
            let index = isJVM(file) ? members.firstIndex { !$0.isType && $0.line >= route.line }
                : members.lastIndex { $0.line <= route.line } ?? members.firstIndex { $0.line >= route.line }
            let label = [route.method, route.path].compactMap { $0 }.joined(separator: " ")
            let id = "route:" + label
            if !parts.contains(where: { $0.id == id }) {
                parts.append(Part(id: id, name: route.path, lane: .api, kind: .routes, detail: route.method ?? "any method",
                                  items: [Item(label, file: file, line: route.line)]))
            }
            if let index {
                link(id, ids[index])
                served[index, default: []].append(label)
            }
        }

        // What each declaration uses: the project's classes, by name or through a field.
        let known = references(from: file, text: text, files: files)
        let fields = fieldTypes(in: text, types: Set(known.keys))
        var used: [String: Int] = [:]
        var uses: [Int: Set<String>] = [:]
        // Tables: the repo's SQL, plus entities this file names (JPA).
        var tables = knownTables(files: files, read: read)
        var entityTables: [String: String] = [:]
        for (name, target) in known where isJVM(target) {
            guard let other = read(target), has(other, "@Entity"), let entity = entity(in: other) else { continue }
            let table = tables.first { $0.lowercased() == entity.table.lowercased() } ?? entity.table
            entityTables[name] = table
            if !tables.contains(table) { tables.append(table) }
        }
        let repositoryTables = entityTables.filter { has(text, "Repository<" + $0.key + ",") || has(text, "Repository<" + $0.key + " ") }.map(\.value)
        let pattern = tables.isEmpty ? nil : queryPattern(tables + Array(entityTables.keys))
        var tableUse: [String: Int] = [:]
        var queries: [Int: Set<String>] = [:]
        for (index, member) in members.enumerated() {
            let source = body(member)
            let words = identifiers(source)
            for (name, target) in known where words.contains(name) { uses[index, default: []].insert(target) }
            for (field, type) in fields where words.contains(field) { if let target = known[type] { uses[index, default: []].insert(target) } }
            for target in uses[index] ?? [] { used[target, default: 0] += 1 }
            for (other, callee) in members.enumerated() where other != index && !callee.isType && callee.name != member.name && source.contains(callee.name + "(") {
                link(ids[index], ids[other])
            }
            if let pattern {
                let lower = source.lowercased()
                for match in pattern.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
                    guard let name = Range(match.range(at: 1), in: lower).map({ String(lower[$0]) }),
                          let table = tables.first(where: { $0.lowercased() == name }) ?? entityTables.first(where: { $0.key.lowercased() == name })?.value else { continue }
                    queries[index, default: []].insert(table)
                }
            }
            if !member.isType { for table in repositoryTables { queries[index, default: []].insert(table) } }
            for table in queries[index] ?? [] { tableUse[table, default: 0] += 1 }
        }

        for (index, member) in members.enumerated() {
            let size = member.end - member.line + 1
            var detail: [String] = []
            if let routes = served[index] { detail.append(routes.count == 1 ? routes[0] : "\(routes.count) routes") }
            if let tables = queries[index], !tables.isEmpty { detail.append(tables.sorted().joined(separator: ", ")) }
            detail.append("\(size) line\(size == 1 ? "" : "s")")
            parts.append(Part(id: ids[index], name: member.isType ? member.name : member.name + "()", lane: .backend,
                              kind: member.isType ? .structure : .function, detail: detail.joined(separator: " · "),
                              items: [Item(member.signature, file: file, line: member.line, end: member.end)]))
        }
        let shownUses = used.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(14).map(\.key)
        for target in shownUses {
            let detail = read(target).map { fileRole(target, text: $0) } ?? ""
            parts.append(Part(id: "code:" + target, name: stem(target), lane: .outside, kind: .structure, detail: detail, path: target))
        }
        for (index, targets) in uses { for target in targets where shownUses.contains(target) { link(ids[index], "code:" + target) } }
        for table in tableUse.keys.sorted() {
            parts.append(Part(id: "table:" + table, name: table, lane: .data, kind: .table, detail: "used by \(tableUse[table]!) here"))
        }
        for (index, tables) in queries { for table in tables { link(ids[index], "table:" + table) } }

        var map = SystemMap(parts: parts, links: links.values.sorted { ($0.from, $0.to) < ($1.from, $1.to) })
        map.laneTitles = [.backend: "Inside \((file as NSString).lastPathComponent)", .outside: "Uses", .api: "Routes"]
        return map
    }

    // MARK: From a table

    /// A table's columns and foreign keys, from the first `CREATE TABLE` for it.
    public static func columns(of table: String, in sql: String) -> [Column] {
        let escaped = NSRegularExpression.escapedPattern(for: table)
        guard let start = try? NSRegularExpression(pattern: #"create\s+table\s+(?:if\s+not\s+exists\s+)?(?:[`"\[]?\w+[`"\]]?\.)?[`"\[]?"# + escaped + #"[`"\]]?\s*\("#, options: .caseInsensitive),
              let match = start.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)),
              let open = Range(match.range, in: sql)?.upperBound else { return [] }
        // The definitions, split at commas outside parentheses.
        var depth = 0
        var definitions: [String] = []
        var current = ""
        // Comments can hold commas and parentheses.
        let body = sql[open...].replacing(/--[^\n]*/, with: "")
        for character in body {
            if character == "(" { depth += 1 }
            if character == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            if character == ",", depth == 0 {
                definitions.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        definitions.append(current)
        var columns: [Column] = []
        let constraints: Set<String> = ["constraint", "primary", "foreign", "unique", "key", "index", "check", "exclude"]
        for definition in definitions {
            let text = definition.split(separator: "\n").map { $0.components(separatedBy: "--")[0] }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = words.first else { continue }
            let reference = text.firstMatch(of: /(?i)references\s+(?:[`"\[]?\w+[`"\]]?\.)?[`"\[]?(\w+)/).map { String($0.1) }
            if constraints.contains(first.lowercased()) {
                // FOREIGN KEY (owner_id) REFERENCES users(id): onto the column it names.
                if let reference, let name = text.firstMatch(of: /(?i)foreign\s+key\s*\(\s*[`"\[]?(\w+)/).map({ String($0.1) }),
                   let index = columns.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                    columns[index].references = reference
                }
                continue
            }
            let name = first.trimmingCharacters(in: CharacterSet(charactersIn: "`\"[]"))
            let rest = text.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
            let type = rest.firstMatch(of: /^\w+(?:\s+(?:varying|precision))?(?:\s*\([^)]*\))?(?:\[\])?/).map { String($0.0).lowercased() } ?? ""
            columns.append(Column(name: name, type: type, references: reference))
        }
        return columns
    }

    /// The code that reaches `table`, followed back from what queries it (SQL naming it, a JPA
    /// repository of its entity) through the classes that call those, to the routes at the top.
    static func trace(table: String, files: [String], read: (String) -> String?) -> SystemMap? {
        let code = files.filter(isCode)
        var texts: [String: String] = [:]
        func text(_ file: String) -> String {
            if let known = texts[file] { return known }
            let value = read(file) ?? ""
            texts[file] = value
            return value
        }
        let lowerTable = table.lowercased()

        // Columns and the tables either side of a foreign key.
        var columns: [Column] = []
        var referencing: [String] = []
        for file in files where (file as NSString).pathExtension.lowercased() == "sql" && !isTest(file) {
            guard let sql = read(file), has(sql.lowercased(), lowerTable) else { continue }
            if columns.isEmpty { columns = Self.columns(of: table, in: sql) }
            for other in tables(in: sql) where other.lowercased() != lowerTable && !referencing.contains(other) {
                if Self.columns(of: other, in: sql).contains(where: { $0.references?.lowercased() == lowerTable }) { referencing.append(other) }
            }
        }

        // What touches it directly.
        var entityFile: String?
        var entityName: String?
        for file in code where isJVM(file) && has(text(file), "@Entity") {
            if let entity = entity(in: text(file)), entity.table.lowercased() == lowerTable {
                entityFile = file
                entityName = entity.name
                break
            }
        }
        var direct: [String] = []
        let pattern = queryPattern([table] + (entityName.map { [$0] } ?? []))
        for file in code where file != entityFile {
            let body = text(file)
            if let entityName, has(body, "Repository<" + entityName + ",") || has(body, "Repository<" + entityName + " ") {
                direct.append(file)
                continue
            }
            let lower = body.lowercased()
            guard has(lower, lowerTable) || entityName.map({ has(lower, $0.lowercased()) }) == true,
                  has(lower, "select") || has(lower, "insert") || has(lower, "update") || has(lower, "delete"), let pattern else { continue }
            let query = lines(of: lower, holding: ["from", "into", "update", "join", "table"], andNext: true)
            if pattern.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) != nil { direct.append(file) }
        }

        // Back through the callers, a few steps, stopping at files that serve routes.
        let family = Set(direct.map { ($0 as NSString).pathExtension.lowercased() })
        let candidates = code.filter { family.contains(($0 as NSString).pathExtension.lowercased()) }
        var usersOf: [String: [String]] = [:]
        if !direct.isEmpty {
            for file in candidates {
                for (_, target) in references(from: file, text: text(file), files: candidates) where target != file {
                    usersOf[target, default: []].append(file)
                }
            }
        }
        func serves(_ file: String) -> Bool { !(isJVM(file) ? annotatedRoutes(in: text(file)) : routes(in: text(file))).isEmpty }
        var chain = direct
        var calls: [(from: String, to: String)] = []
        var frontier = direct.filter { !serves($0) }
        var seen = Set(direct + [entityFile].compactMap { $0 })
        for _ in 0..<4 where !frontier.isEmpty && chain.count < 26 {
            var next: [String] = []
            for callee in frontier {
                for caller in (usersOf[callee] ?? []).sorted() {
                    calls.append((caller, callee))
                    guard !seen.contains(caller), chain.count < 26 else { continue }
                    seen.insert(caller)
                    chain.append(caller)
                    if !serves(caller) { next.append(caller) }
                }
            }
            frontier = next
        }
        guard !chain.isEmpty || entityFile != nil || !columns.isEmpty else { return nil }

        var parts: [Part] = []
        var links: [String: Link] = [:]
        func link(_ from: String, _ to: String) {
            guard from != to else { return }
            links["\(from)→\(to)", default: Link(from: from, to: to, weight: 0)].weight += 1
        }
        let tableID = "table:" + table
        let inChain = Set(chain)
        // Routes whose handler reaches the chain.
        for file in chain where serves(file) {
            let body = text(file)
            let members = members(of: file, text: body)
            let lines = body.components(separatedBy: "\n")
            let callees = Set(calls.filter { $0.from == file }.map(\.to))
            let names = Set(callees.map(stem))
            let fields = fieldTypes(in: body, types: names).filter { names.contains($0.value) }.map(\.key)
            for route in isJVM(file) ? annotatedRoutes(in: body) : routes(in: body) {
                let index = isJVM(file) ? members.firstIndex { !$0.isType && $0.line >= route.line }
                    : members.lastIndex { $0.line <= route.line }
                if let index, !callees.isEmpty, !direct.contains(file) {
                    let words = identifiers(lines[(members[index].line - 1)..<min(members[index].end, lines.count)].joined(separator: "\n"))
                    guard names.contains(where: words.contains) || fields.contains(where: words.contains) else { continue }
                }
                let label = [route.method, route.path].compactMap { $0 }.joined(separator: " ")
                let id = "route:" + label
                if !parts.contains(where: { $0.id == id }) {
                    parts.append(Part(id: id, name: route.path, lane: .api, kind: .routes, detail: route.method ?? "any method",
                                      items: [Item(label, file: file, line: route.line)]))
                }
                link(id, "code:" + file)
            }
        }
        for file in chain {
            parts.append(Part(id: "code:" + file, name: stem(file), lane: .backend, kind: .structure, detail: fileRole(file, text: text(file)), path: file))
        }
        for call in calls where inChain.contains(call.from) && inChain.contains(call.to) { link("code:" + call.from, "code:" + call.to) }
        for file in direct { link("code:" + file, tableID) }
        if let entityFile {
            parts.append(Part(id: "code:" + entityFile, name: stem(entityFile), lane: .backend, kind: .structure, detail: "entity · maps the table", path: entityFile))
            link("code:" + entityFile, tableID)
        }

        let keys = columns.filter { $0.references != nil }.count
        parts.append(Part(id: tableID, name: table, lane: .data, kind: .table,
                          detail: columns.isEmpty ? "table" : "\(columns.count) column\(columns.count == 1 ? "" : "s")" + (keys > 0 ? " · \(keys) foreign key\(keys == 1 ? "" : "s")" : ""),
                          items: columns.map { Item([$0.name, $0.type, $0.references.map { "→ \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")) }))
        for other in Set(columns.compactMap(\.references)).sorted() where other.lowercased() != lowerTable {
            parts.append(Part(id: "table:" + other, name: other, lane: .data, kind: .table, detail: "referenced by \(table)"))
            link(tableID, "table:" + other)
        }
        for other in referencing.sorted() where !parts.contains(where: { $0.id == "table:" + other }) {
            parts.append(Part(id: "table:" + other, name: other, lane: .data, kind: .table, detail: "references \(table)"))
            link("table:" + other, tableID)
        }

        var map = SystemMap(parts: parts, links: links.values.sorted { ($0.from, $0.to) < ($1.from, $1.to) })
        map.laneTitles = [.api: "Routes that reach it", .backend: "Code that uses it", .data: "Data"]
        map.entries = [tableID]
        return map
    }
}
