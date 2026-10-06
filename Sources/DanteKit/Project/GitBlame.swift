import Foundation

/// Who last changed each line of a file, from `git blame --porcelain`.
public struct GitBlame: Equatable, Sendable {
    public struct Commit: Equatable, Sendable {
        public var hash: String
        public var author: String
        public var date: Date
        public var summary: String

        public init(hash: String, author: String, date: Date, summary: String) {
            self.hash = hash
            self.author = author
            self.date = date
            self.summary = summary
        }

        /// Lines changed in the working copy carry git's all-zero hash.
        public var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
        public var shortHash: String { String(hash.prefix(7)) }
    }

    /// One entry per line of the file, zero-based; nil where git gave nothing.
    public var lines: [Commit?]

    public init(lines: [Commit?]) {
        self.lines = lines
    }

    /// The commit behind a one-based line number.
    public func commit(atLine line: Int) -> Commit? {
        lines.indices.contains(line - 1) ? lines[line - 1] : nil
    }

    /// Blames `file` as `text` reads now, so unsaved edits show as not committed yet
    /// rather than shifting every line below them. Nil outside a repository or for
    /// files git doesn't track.
    public static func load(file: URL, text: String, root: URL) async -> GitBlame? {
        let path = file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
            ? String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)) : file.path
        let contents = FileManager.default.temporaryDirectory.appending(path: "dante-blame-\(UUID().uuidString)")
        guard (try? text.write(to: contents, atomically: true, encoding: .utf8)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: contents) }
        let output = await Shell.run(["git", "blame", "--porcelain", "--contents", contents.path, "--", path], in: root, trimming: false)
        guard output.succeeded else { return nil }
        return parse(output.stdout)
    }

    /// Reads porcelain output: a header line per hunk (`<hash> <orig> <final> [<count>]`),
    /// the commit's fields the first time it appears, then the line itself after a tab.
    public static func parse(_ porcelain: String) -> GitBlame {
        var commits: [String: Commit] = [:]
        var lines: [Int: String] = [:]
        var current: String?
        var finalLine = 0
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("\t") { continue }
            let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            if key.count == 40, key.allSatisfy(\.isHexDigit) {
                let numbers = value.split(separator: " ")
                guard numbers.count >= 2, let final = Int(numbers[1]) else { continue }
                let hash = String(key)
                current = hash
                finalLine = final
                lines[finalLine] = hash
                if commits[hash] == nil { commits[hash] = Commit(hash: hash, author: "", date: .distantPast, summary: "") }
                continue
            }
            guard let hash = current else { continue }
            switch key {
            case "author": commits[hash]?.author = value
            case "author-time": commits[hash]?.date = Date(timeIntervalSince1970: TimeInterval(value) ?? 0)
            case "summary": commits[hash]?.summary = value
            default: break
            }
        }
        let count = lines.keys.max() ?? 0
        return GitBlame(lines: (0..<count).map { index in lines[index + 1].flatMap { commits[$0] } })
    }
}
