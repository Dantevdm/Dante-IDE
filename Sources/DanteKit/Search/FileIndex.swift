import Foundation

/// Every file in a project, as paths relative to the root, for quick open.
public enum FileIndex {
    /// Folders skipped when indexing: the explorer's ignored names plus common build output.
    public static let skippedNames: Set<String> = FileTree.ignoredNames.union([
        "build", "dist", "target", "Pods", "coverage", ".gradle", ".idea", ".vscode", "vendor",
    ])

    /// Large monorepos are capped so the palette stays instant.
    public static let limit = 50_000

    /// Walks the project. Hidden files are included, since `.dante/`, `.github/` and dotfiles matter here.
    public static func scan(_ root: URL, fileManager: FileManager = .default) -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var paths: [String] = []
        // The enumerator may spell the root differently (/private/var for /var), so its own
        // spelling is taken from the first item, which always sits directly in the root.
        var prefix: String?
        for case let url as URL in enumerator {
            if prefix == nil { prefix = url.deletingLastPathComponent().path + "/" }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if skippedNames.contains(url.lastPathComponent) {
                // Only for folders: on a file (.DS_Store) it skips the rest of the folder it's in.
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            guard !isDirectory else { continue }
            let path = url.path
            guard let prefix, path.hasPrefix(prefix) else { continue }
            paths.append(String(path.dropFirst(prefix.count)))
            if paths.count >= limit { break }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Fuzzy matching for quick open: the query's characters must appear in order. Matches in
/// the file name, at word starts and in runs score higher.
public enum FuzzyMatch {
    public struct Result: Equatable, Sendable {
        public var score: Int
        /// Offsets of the matched characters in the candidate.
        public var indices: [Int]
    }

    public static func match(_ query: String, in candidate: String) -> Result? {
        match(needle(query), in: candidate)
    }

    private static func needle(_ query: String) -> [Character] {
        Array(query.lowercased().filter { !$0.isWhitespace })
    }

    private static func match(_ needle: [Character], in candidate: String) -> Result? {
        guard !needle.isEmpty else { return Result(score: 0, indices: []) }
        // Most candidates lack the query's letters in order; finding that out on the bytes is
        // much cheaper than the character arrays the scoring needs.
        if let bytes = asciiBytes(needle), !containsInOrder(bytes, candidate) { return nil }
        let haystack = Array(candidate)
        let lowered = haystack.map { Character($0.lowercased()) }
        let nameStart = (haystack.lastIndex(of: "/").map { $0 + 1 }) ?? 0

        // Prefer a match entirely inside the file name; fall back to the whole path.
        if let indices = greedy(needle, in: lowered, original: haystack, from: nameStart) {
            return Result(score: score(indices, haystack, nameStart: nameStart) + 40, indices: indices)
        }
        if let indices = greedy(needle, in: lowered, original: haystack, from: 0) {
            return Result(score: score(indices, haystack, nameStart: nameStart), indices: indices)
        }
        return nil
    }

    /// Ranks candidates, best first, keeping at most `limit`.
    public static func rank(_ query: String, in candidates: [String], limit: Int = 50) -> [(path: String, result: Result)] {
        let needle = needle(query)
        var matches: [(path: String, result: Result)] = []
        for candidate in candidates {
            if let result = match(needle, in: candidate) { matches.append((candidate, result)) }
        }
        matches.sort {
            $0.result.score != $1.result.score ? $0.result.score > $1.result.score : $0.path.count < $1.path.count
        }
        return Array(matches.prefix(limit))
    }

    /// Leftmost match, but each character prefers a word start if one comes before the next
    /// ordinary occurrence would end the match early.
    private static func greedy(_ needle: [Character], in haystack: [Character], original: [Character], from start: Int) -> [Int]? {
        var indices: [Int] = []
        var position = start
        for (n, character) in needle.enumerated() {
            guard let first = haystack[position...].firstIndex(of: character) else { return nil }
            var chosen = first
            // Jump ahead to a word-start occurrence when it's not right after the previous match
            // and the rest of the query still fits after it.
            if let last = indices.last, first != last + 1 {
                let remaining = Array(needle[(n + 1)...])
                if let boundary = haystack[first...].indices.first(where: {
                    haystack[$0] == character && isBoundary($0, original) && fits(remaining, in: haystack, after: $0)
                }) {
                    chosen = boundary
                }
            }
            indices.append(chosen)
            position = chosen + 1
        }
        return indices
    }

    private static func asciiBytes(_ needle: [Character]) -> [UInt8]? {
        let bytes = needle.compactMap(\.asciiValue)
        return bytes.count == needle.count ? bytes : nil
    }

    /// Whether the lowercase ASCII `needle` appears in order in `candidate`, ignoring case.
    private static func containsInOrder(_ needle: [UInt8], _ candidate: String) -> Bool {
        var index = 0
        for byte in candidate.utf8 {
            let lower = byte >= 65 && byte <= 90 ? byte + 32 : byte
            if lower == needle[index] {
                index += 1
                if index == needle.count { return true }
            }
        }
        return false
    }

    private static func fits(_ needle: [Character], in haystack: [Character], after index: Int) -> Bool {
        var position = index + 1
        for character in needle {
            guard position <= haystack.count, let found = haystack[position...].firstIndex(of: character) else { return false }
            position = found + 1
        }
        return true
    }

    private static func isBoundary(_ index: Int, _ text: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1], current = text[index]
        if "/_-. ".contains(previous) { return true }
        return previous.isLowercase && current.isUppercase
    }

    private static func score(_ indices: [Int], _ text: [Character], nameStart: Int) -> Int {
        var score = 0
        for (offset, index) in indices.enumerated() {
            score += 1
            if offset > 0, index == indices[offset - 1] + 1 { score += 6 }
            if isBoundary(index, text) { score += 8 }
            if index >= nameStart { score += 2 }
        }
        if indices.first == nameStart { score += 10 }
        return score - text.count / 10
    }
}
