import Foundation
import Yams

/// "Eyes on it": people marking that they've read and understood a file, as it is now.
///
/// Marks live in the repo, in `.dante/reviews.jsonl`, one JSON object per line, so they travel
/// with every push and pull to any host (GitHub, Bitbucket, Azure DevOps, a bare server) and
/// show up in pull requests like any other change. Each line stands alone and
/// `.gitattributes` gives the file `merge=union`, so two people marking on two branches
/// merge without a conflict. (Git notes would need their own refspec on every clone and none
/// of the hosts show them.)
///
/// A mark records the file's blob hash when it was read, so it goes stale the moment the file
/// changes: the coverage shows what's been looked at in its current form, not once upon a time.
public enum CodeReview {
    public static let file = ".dante/reviews.jsonl"
    public static let attribute = "\(file) merge=union"

    public enum Verdict: String, Codable, Sendable, CaseIterable {
        /// Read and understood; nothing to raise.
        case reviewed
        /// Read, with something to raise (the note says what).
        case concern
        /// Takes back the reviewer's earlier mark on the file.
        case cleared
    }

    public struct Mark: Codable, Equatable, Sendable {
        public var path: String
        public var blob: String
        public var by: String
        public var at: Date
        public var verdict: Verdict
        public var note: String?

        public init(path: String, blob: String, by: String, at: Date, verdict: Verdict = .reviewed, note: String? = nil) {
            self.path = path
            self.blob = blob
            self.by = by
            self.at = at
            self.verdict = verdict
            self.note = note
        }
    }

    /// Someone asking someone else to look at files: a path is a file, a folder (its files)
    /// or "" for every code file.
    public struct Request: Codable, Equatable, Sendable, Identifiable {
        public var paths: [String]
        public var reviewer: String
        public var by: String
        public var at: Date
        public var note: String?
        public var id: String { reviewer + "|" + by + "|" + ISO8601DateFormatter().string(from: at) }

        public init(paths: [String], reviewer: String, by: String, at: Date, note: String? = nil) {
            self.paths = paths
            self.reviewer = reviewer
            self.by = by
            self.at = at
            self.note = note
        }

        public func covers(_ path: String) -> Bool {
            paths.contains { $0.isEmpty || $0 == path || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
    }

    // MARK: The file (pure)

    public struct Log: Equatable, Sendable {
        public var marks: [Mark] = []
        public var requests: [Request] = []

        public init(marks: [Mark] = [], requests: [Request] = []) {
            self.marks = marks
            self.requests = requests
        }
    }

    private struct Line: Codable {
        var type: String
        var path: String?
        var paths: [String]?
        var blob: String?
        var by: String?
        var reviewer: String?
        var at: Date?
        var verdict: Verdict?
        var note: String?
    }

    /// Reads the file leniently: lines that don't parse are skipped, and order comes from the
    /// times, since a union merge puts one side's lines after the other's.
    public static func parse(_ text: String) -> Log {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var log = Log()
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let data = raw.data(using: .utf8), let line = try? decoder.decode(Line.self, from: data),
                  let by = line.by?.nonEmptyTrimmed, let at = line.at else { continue }
            switch line.type {
            case "mark":
                guard let path = line.path, let blob = line.blob else { continue }
                log.marks.append(Mark(path: path, blob: blob, by: by, at: at, verdict: line.verdict ?? .reviewed, note: line.note))
            case "request":
                guard let reviewer = line.reviewer?.nonEmptyTrimmed else { continue }
                log.requests.append(Request(paths: line.paths ?? line.path.map { [$0] } ?? [""], reviewer: reviewer, by: by, at: at, note: line.note))
            default: continue
            }
        }
        log.marks.sort { $0.at < $1.at }
        log.requests.sort { $0.at < $1.at }
        return log
    }

    public static func line(_ mark: Mark) -> String {
        encode(Line(type: "mark", path: mark.path, blob: mark.blob, by: mark.by, at: mark.at, verdict: mark.verdict, note: mark.note?.nonEmptyTrimmed))
    }

    public static func line(_ request: Request) -> String {
        encode(Line(type: "request", paths: request.paths, by: request.by, reviewer: request.reviewer, at: request.at, note: request.note?.nonEmptyTrimmed))
    }

    private static func encode(_ line: Line) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(line)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Policy

    /// `review:` in `.dante/project.yaml`: how many people each file needs, and which files count.
    public struct Policy: Equatable, Sendable {
        public var required: Int
        public var include: [String]
        public var exclude: [String]

        public init(required: Int = 1, include: [String] = [], exclude: [String] = []) {
            self.required = max(1, required)
            self.include = include
            self.exclude = exclude
        }

        public static func parse(projectYAML yaml: String) -> Policy {
            guard let root = (try? SafeYAML.load(yaml)) as? [String: Any],
                  let review = root["review"] as? [String: Any] else { return Policy() }
            let list: (String) -> [String] = { key in
                (review[key] as? [String]) ?? (review[key] as? String).map { [$0] } ?? []
            }
            let required = (review["required"] as? Int) ?? (review["reviewers"] as? Int) ?? Int(review["required"] as? String ?? "") ?? 1
            return Policy(required: required, include: list("include"), exclude: list("exclude"))
        }

        public static func load(projectRoot: URL) -> Policy {
            (try? String(contentsOf: projectRoot.appending(path: ".dante/project.yaml"), encoding: .utf8)).map(parse) ?? Policy()
        }

        /// A file people should read: code by its extension or name, not generated, vendored
        /// or minified; `include` adds files and `exclude` takes them away (globs).
        public func counts(_ path: String) -> Bool {
            let matches: (String) -> Bool = { pattern in
                fnmatch(pattern, path, 0) == 0 || fnmatch(pattern, (path as NSString).lastPathComponent, 0) == 0
                    || path.hasPrefix(pattern.hasSuffix("/") ? pattern : pattern + "/")
            }
            if exclude.contains(where: matches) { return false }
            if include.contains(where: matches) { return true }
            return CodeReview.isCode(path)
        }
    }

    static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "c", "cc", "cpp", "cxx", "h", "hpp", "go", "rs", "py", "rb", "php", "java", "kt", "kts", "scala",
        "groovy", "cs", "fs", "vb", "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte", "dart", "ex", "exs", "erl", "clj",
        "lua", "r", "jl", "sql", "sh", "bash", "zsh", "ps1", "tf", "bicep", "html", "css", "scss", "less", "proto", "graphql",
    ]
    static let codeNames: Set<String> = ["Dockerfile", "Makefile", "Jenkinsfile", "Containerfile"]
    static let skippedFolders = ["node_modules/", "vendor/", "third_party/", "Pods/", ".build/", "dist/", "build/", "target/", "generated/", "__generated__/"]

    public static func isCode(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.contains(".generated.") || name.hasSuffix(".pb.go")
            || name.hasSuffix(".d.ts") { return false }
        if skippedFolders.contains(where: { path.hasPrefix($0) || path.contains("/" + $0) }) { return false }
        return codeNames.contains(name) || name.hasPrefix("Dockerfile.")
            || codeExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    // MARK: Coverage (pure)

    public enum State: String, Sendable, CaseIterable {
        /// Nobody has read this version, and nobody read an earlier one either.
        case notReviewed
        /// Read before, but it has changed since.
        case changed
        /// Read as it is, by fewer people than the project asks for.
        case partly
        /// Read as it is by enough people.
        case reviewed
        /// Someone raised something about this version.
        case concern
    }

    public struct FileReview: Equatable, Sendable, Identifiable {
        public var path: String
        public var blob: String
        /// The latest mark per person on this version.
        public var current: [Mark]
        /// People whose latest mark is on an earlier version.
        public var stale: [Mark]
        /// People asked to look at it who haven't read this version.
        public var askedOf: [String]
        public var state: State
        public var id: String { path }

        public var folder: String {
            let folder = (path as NSString).deletingLastPathComponent
            return folder.isEmpty ? "." : folder
        }

        public func reviewed(by person: String) -> Bool {
            current.contains { $0.by.caseInsensitiveCompare(person) == .orderedSame }
        }
    }

    public struct Coverage: Equatable, Sendable {
        public var files: [FileReview]
        public var required: Int
        public var requests: [Request]

        public func count(_ state: State) -> Int { files.filter { $0.state == state }.count }
        public var reviewed: Int { count(.reviewed) }
        /// Files with at least one person's eyes on their current version.
        public var looked: Int { files.filter { !$0.current.isEmpty }.count }
        public var fraction: Double { files.isEmpty ? 0 : Double(reviewed) / Double(files.count) }

        /// Files a person has been asked to look at and hasn't yet.
        public func askedOf(_ person: String) -> [FileReview] {
            files.filter { $0.askedOf.contains { $0.caseInsensitiveCompare(person) == .orderedSame } }
        }

        /// Requests still waiting on someone.
        public var openRequests: [Request] {
            requests.filter { request in
                files.contains { $0.askedOf.contains(request.reviewer) && request.covers($0.path) }
            }
        }

        public struct Person: Equatable, Sendable, Identifiable {
            public var name: String
            public var current: Int
            public var concerns: Int
            public var last: Date
            public var id: String { name }
        }

        /// Everyone who has marked files, most current marks first.
        public var people: [Person] {
            var byName: [String: Person] = [:]
            for file in files {
                for mark in file.current {
                    var person = byName[mark.by] ?? Person(name: mark.by, current: 0, concerns: 0, last: mark.at)
                    person.current += 1
                    if mark.verdict == .concern { person.concerns += 1 }
                    person.last = max(person.last, mark.at)
                    byName[mark.by] = person
                }
            }
            return byName.values.sorted { ($0.current, $1.name) > ($1.current, $0.name) }
        }

        public struct Folder: Equatable, Sendable, Identifiable {
            public var path: String
            public var files: [FileReview]
            public var id: String { path }
            public var reviewed: Int { files.filter { $0.state == .reviewed }.count }
            public var looked: Int { files.filter { !$0.current.isEmpty }.count }
        }

        /// Files grouped by folder, folders in path order.
        public func folders(_ files: [FileReview]? = nil) -> [Folder] {
            Dictionary(grouping: files ?? self.files, by: \.folder)
                .map { Folder(path: $0.key, files: $0.value.sorted { $0.path < $1.path }) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    /// What everyone has read: `blobs` maps each file that counts to its current blob hash.
    public static func coverage(blobs: [String: String], log: Log, required: Int = 1) -> Coverage {
        // The latest line per person and file decides.
        var latest: [String: [String: Mark]] = [:]
        for mark in log.marks where blobs[mark.path] != nil {
            latest[mark.path, default: [:]][mark.by] = mark
        }
        let files = blobs.keys.sorted().map { path -> FileReview in
            let blob = blobs[path]!
            let marks = (latest[path] ?? [:]).values.filter { $0.verdict != .cleared }.sorted { $0.at < $1.at }
            let current = marks.filter { $0.blob == blob }
            let stale = marks.filter { $0.blob != blob }
            let readers = Set(current.map { $0.by.lowercased() })
            var asked: [String] = []
            for request in log.requests where request.covers(path) && !readers.contains(request.reviewer.lowercased())
                && !asked.contains(where: { $0.caseInsensitiveCompare(request.reviewer) == .orderedSame }) {
                // A request made before someone's mark on an earlier version still stands for this one.
                asked.append(request.reviewer)
            }
            let state: State = if current.contains(where: { $0.verdict == .concern }) {
                .concern
            } else if current.count >= required {
                .reviewed
            } else if !current.isEmpty {
                .partly
            } else if !stale.isEmpty {
                .changed
            } else {
                .notReviewed
            }
            return FileReview(path: path, blob: blob, current: current, stale: stale, askedOf: asked, state: state)
        }
        return Coverage(files: files, required: max(1, required), requests: log.requests)
    }

    /// `git ls-files -s -z`: path → blob of what's staged (stage 0 only, so conflicts drop out).
    public static func blobs(fromLsFiles output: String) -> [String: String] {
        var blobs: [String: String] = [:]
        for entry in output.split(separator: "\0") {
            // "100644 <blob> 0\t<path>"
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let fields = entry[..<tab].split(separator: " ")
            guard fields.count == 3, fields[2] == "0" else { continue }
            blobs[String(entry[entry.index(after: tab)...])] = String(fields[1])
        }
        return blobs
    }

    /// Initials for a reviewer's badge: "Ana Smith" → "AS", "sam" → "S".
    public static func initials(_ name: String) -> String {
        let words = name.split { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

// MARK: Reading and writing in a repository

extension CodeReview {
    /// The current blob of every file that counts: the index's, with files edited in the
    /// working tree hashed as they are now (so a mark is on what the reviewer read).
    public static func currentBlobs(in root: URL, policy: Policy) async -> [String: String] {
        let listed = await Shell.run(["git", "ls-files", "-s", "-z"], in: root, trimming: false)
        guard listed.succeeded else { return [:] }
        var blobs = blobs(fromLsFiles: listed.stdout).filter { policy.counts($0.key) }
        let status = await GitRepository.status(in: root)
        let edited = (status?.changes ?? []).filter { $0.unstaged != nil && !$0.isUntracked && blobs[$0.path] != nil }.map(\.path)
        for (path, blob) in await hash(edited, in: root) { blobs[path] = blob }
        return blobs
    }

    /// `git hash-object` for paths as they are on disk.
    public static func hash(_ paths: [String], in root: URL) async -> [String: String] {
        var result: [String: String] = [:]
        var start = 0
        while start < paths.count {
            let chunk = Array(paths[start..<min(paths.count, start + 200)])
            start += 200
            let output = await Shell.run(["git", "hash-object", "--"] + chunk, in: root)
            let hashes = output.stdout.split(separator: "\n").map(String.init)
            guard output.succeeded, hashes.count == chunk.count else { continue }
            for (path, hash) in zip(chunk, hashes) { result[path] = hash }
        }
        return result
    }

    /// Who's reviewing: git's user.name for this repository.
    public static func reviewer(in root: URL) async -> String? {
        await Shell.run(["git", "config", "user.name"], in: root).stdout.nonEmptyTrimmed
    }

    /// People who might review: commit authors and anyone who has marked or been asked.
    public static func people(in root: URL, log: Log) async -> [String] {
        let authors = await Shell.run(["git", "shortlog", "-sn", "--no-merges", "-n", "HEAD"], in: root, timeout: .seconds(10))
        var names = authors.stdout.split(separator: "\n").compactMap { line in
            line.split(separator: "\t", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        names += log.marks.map(\.by) + log.requests.map(\.reviewer)
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public static func load(in root: URL) -> Log {
        parse((try? String(contentsOf: root.appending(path: file), encoding: .utf8)) ?? "")
    }

    /// Adds lines to the file (creating it and the union-merge attribute the first time).
    public static func append(_ lines: [String], in root: URL) throws {
        let url = root.appending(path: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.filter { !$0.isEmpty }.map { $0 + "\n" }.joined()
        if let handle = try? FileHandle(forUpdating: url) {
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            // A file whose last line lacks its newline gets one first.
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data("\n".utf8) { try handle.write(contentsOf: Data("\n".utf8)) }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try ensureUnionMerge(in: root)
    }

    /// `.gitattributes` with the reviews file merged by union, added once.
    public static func ensureUnionMerge(in root: URL) throws {
        let url = root.appending(path: ".gitattributes")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !existing.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix(file) }) else { return }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + "# Dante's review marks: each line stands alone, so both sides of a merge keep theirs.\n" + attribute + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
