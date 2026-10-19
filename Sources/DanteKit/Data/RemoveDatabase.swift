import Foundation

/// Undoing the new-database wizard: what deleting a database Dante created changes, worked
/// out from the files as they are now so nothing else in them is touched.
public struct DatabaseRemoval: Equatable, Sendable {
    public struct FileEdit: Equatable, Sendable {
        /// Relative to the project.
        public var path: String
        /// The new text; nil moves the file to the Trash (nothing else was left in it).
        public var text: String?
        /// What changes, for the confirmation: "the db service", "DATABASE_URL"…
        public var changes: [String]
    }

    public var edits: [FileEdit]
    /// The compose service, for stopping its container, and its named volume when no other
    /// service mounts it, for deleting the data.
    public var service: String?
    public var volume: String?
    /// SQLite: the database file, deleted with its data.
    public var file: String?

    public var isEmpty: Bool { edits.isEmpty && service == nil && file == nil }

    /// `files` reads a project file by relative path; `composePath` is the compose file the
    /// project uses, if any.
    public static func plan(for connection: DatabaseConnection, composePath: String?, read: (String) -> String?) -> DatabaseRemoval {
        var edits: [FileEdit] = []
        var service: String?
        var volume: String?
        var remainingCompose = ""
        if connection.engine != .sqlite, let composePath, let text = read(composePath) {
            let name = connection.service ?? connection.name
            let removed = ComposeEditing.removing(service: name, from: text)
            if removed.found {
                service = name
                volume = removed.volume
                remainingCompose = removed.text ?? ""
                var changes = ["the \(name) service"]
                if let gone = removed.volume { changes.append("the \(gone) volume") }
                edits.append(FileEdit(path: composePath, text: removed.text, changes: removed.text == nil ? ["the whole file (nothing else is in it)"] : changes))
            } else {
                remainingCompose = text
            }
        }

        // The keys the wizard wrote: the URL pointing at this database, and the password
        // key once nothing left in compose reads it.
        let env = read(".env")
        let urlKeys = EnvFile.parse(env ?? "").filter { points($0.value, at: connection) }.map(\.key)
        let example = read(".env.example")
        let exampleURLKeys = EnvFile.parse(example ?? "").filter { points($0.value, at: connection) || urlKeys.contains($0.key) }.map(\.key)
        var keys = Set(urlKeys + exampleURLKeys)
        if connection.engine != .sqlite {
            for key in ["POSTGRES_PASSWORD", "MYSQL_PASSWORD"] where !remainingCompose.contains("${\(key)") && !remainingCompose.contains("$\(key)") {
                // Only when this database's URL was there too, so another tool's password stays.
                if !keys.isEmpty || service != nil, (connection.engine == .postgres) == (key == "POSTGRES_PASSWORD") { keys.insert(key) }
            }
        }
        for (path, text) in [(".env", env), (".env.example", example)] {
            guard let text else { continue }
            let present = EnvFile.parse(text).map(\.key).filter(keys.contains)
            guard !present.isEmpty else { continue }
            // An env file left with nothing in it (the wizard made it) goes too.
            let left = EnvFile.removing(Set(present), from: text)
            edits.append(FileEdit(path: path, text: left.isEmpty ? nil : left,
                                  changes: left.isEmpty ? ["the whole file (nothing else is in it)"] : Array(Set(present)).sorted()))
        }
        let file = connection.engine == .sqlite ? connection.file : nil
        return DatabaseRemoval(edits: edits, service: service, volume: service == nil ? nil : volume, file: file)
    }

    /// Whether an env value is this database's URL (or, for SQLite, its file).
    static func points(_ value: String, at connection: DatabaseConnection) -> Bool {
        if connection.engine == .sqlite, let file = connection.file {
            let bare = file.hasPrefix("./") ? String(file.dropFirst(2)) : file
            return value.hasSuffix(bare) && (value.hasPrefix("file:") || value.hasPrefix("sqlite:") || value == bare || value == "./" + bare)
        }
        guard let port = connection.port, !connection.database.isEmpty else { return false }
        let scheme = connection.engine == .mysql ? "mysql" : "postgres"
        guard value.hasPrefix(scheme) else { return false }
        return ["@localhost:\(port)/\(connection.database)", "@127.0.0.1:\(port)/\(connection.database)"].contains { value.contains($0) }
            && (value.hasSuffix(connection.database) || value.contains("/\(connection.database)?"))
    }
}

extension ComposeEditing {
    /// Takes a service out of a compose file, and its named volume when no other service
    /// mounts it; everything else stays as written. `text` is nil when nothing is left.
    public static func removing(service: String, from text: String) -> (text: String?, volume: String?, found: Bool) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard let servicesLine = lines.firstIndex(where: { $0.hasPrefix("services:") }),
              let unit = indent(of: lines) else { return (text, nil, false) }
        let header = unit + service + ":"
        guard let start = lines.indices.first(where: { $0 > servicesLine && lines[$0].trimmingTrailingComment() == header }) else {
            return (text, nil, false)
        }
        var end = start + 1
        while end < lines.count {
            let line = lines[end]
            if !line.trimmingCharacters(in: .whitespaces).isEmpty, leading(line) <= unit.count { break }
            end += 1
        }
        // Blank lines at the block's end belong to what follows.
        while end - 1 > start, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        let block = lines[start..<end]
        let mounted = block.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return nil }
            let source = trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).split(separator: ":").first.map(String.init)
            guard let source, !source.contains("/"), !source.hasPrefix("."), !source.hasPrefix("~"), !source.hasPrefix("$") else { return nil }
            return source
        }
        lines.removeSubrange(start..<end)
        if start > 0, start - 1 < lines.count, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty,
           start == lines.count || lines[start].trimmingCharacters(in: .whitespaces).isEmpty || leading(lines[start]) == 0 {
            lines.remove(at: start - 1)
        }

        var removedVolume: String?
        for volume in mounted {
            let stillUsed = lines.contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("- \(volume):") || trimmed.hasPrefix("- \"\(volume):") || trimmed == "source: \(volume)"
            }
            guard !stillUsed, let top = lines.firstIndex(where: { $0.hasPrefix("volumes:") }) else { continue }
            var entry: Int?
            var index = top + 1
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty || leading(lines[index]) > 0 {
                let trimmed = lines[index].trimmingTrailingComment().trimmingCharacters(in: .whitespaces)
                if leading(lines[index]) == unit.count, trimmed == "\(volume):" || trimmed.hasPrefix("\(volume): ") { entry = index }
                index += 1
            }
            guard let entry else { continue }
            var stop = entry + 1
            while stop < lines.count, !lines[stop].trimmingCharacters(in: .whitespaces).isEmpty, leading(lines[stop]) > unit.count { stop += 1 }
            lines.removeSubrange(entry..<stop)
            removedVolume = volume
            // An empty `volumes:` goes too.
            let rest = lines[(top + 1)...].prefix { $0.trimmingCharacters(in: .whitespaces).isEmpty || leading($0) > 0 }
            if rest.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                lines.remove(at: top)
                if top > 0, top - 1 < lines.count, lines[top - 1].trimmingCharacters(in: .whitespaces).isEmpty { lines.remove(at: top - 1) }
            }
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }

        // Nothing left but an empty `services:` (and the version or name lines): the file goes.
        let services = lines.firstIndex { $0.hasPrefix("services:") }
        let hasService = services.map { at in lines[(at + 1)...].prefix { $0.isEmpty || leading($0) > 0 || $0.hasPrefix("#") }
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") } } ?? false
        let otherKeys = lines.contains { line in
            leading(line) == 0 && !line.isEmpty && !line.hasPrefix("#")
                && !["services:", "version:", "name:"].contains { line.hasPrefix($0) }
        }
        if !hasService && !otherKeys { return (nil, removedVolume, true) }
        return (lines.joined(separator: "\n") + "\n", removedVolume, true)
    }

    static func leading(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
}

extension EnvFile {
    /// Takes keys out of an env file, with the comment Dante wrote above them when nothing
    /// it describes is left.
    public static func removing(_ keys: Set<String>, from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        func key(of line: String) -> String? {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("export ") { trimmed.removeFirst(7) }
            guard let equals = trimmed.firstIndex(of: "=") else { return nil }
            return trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        }
        var kept: [String] = []
        for line in lines where !(key(of: line).map(keys.contains) ?? false) { kept.append(line) }
        // A Dante comment followed by nothing (or a blank line) has lost its keys.
        var index = 0
        while index < kept.count {
            let line = kept[index].trimmingCharacters(in: .whitespaces)
            let next = index + 1 < kept.count ? kept[index + 1].trimmingCharacters(in: .whitespaces) : ""
            if line.hasPrefix("#"), line.contains("for local development"), next.isEmpty || next.hasPrefix("#") {
                kept.remove(at: index)
                continue
            }
            index += 1
        }
        // No runs of blank lines, and none at the end.
        var tidy: [String] = []
        for line in kept where !(line.trimmingCharacters(in: .whitespaces).isEmpty && (tidy.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)) {
            tidy.append(line)
        }
        while tidy.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { tidy.removeLast() }
        return tidy.isEmpty ? "" : tidy.joined(separator: "\n") + "\n"
    }
}

private extension String {
    /// The line without a trailing `# comment` or trailing spaces.
    func trimmingTrailingComment() -> String {
        var line = self
        if let hash = line.range(of: " #") { line = String(line[..<hash.lowerBound]) }
        while line.last == " " || line.last == "\t" { line.removeLast() }
        return line
    }
}
