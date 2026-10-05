import Foundation

/// Text search across the project's files (the workspace's file index, so ignored
/// folders are already left out).
public enum ProjectSearch {
    public struct Query: Equatable, Sendable {
        public var text: String
        public var caseSensitive = false
        public var wholeWord = false
        public var isRegex = false

        public init(text: String, caseSensitive: Bool = false, wholeWord: Bool = false, isRegex: Bool = false) {
            self.text = text
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
            self.isRegex = isRegex
        }

        /// Nil for an empty query or a regex that doesn't compile.
        public var expression: NSRegularExpression? {
            guard !text.isEmpty else { return nil }
            var pattern = isRegex ? text : NSRegularExpression.escapedPattern(for: text)
            if wholeWord { pattern = "\\b(?:\(pattern))\\b" }
            return try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [.anchorsMatchLines] : [.caseInsensitive, .anchorsMatchLines])
        }
    }

    public struct Match: Identifiable, Hashable, Sendable {
        /// Zero-based line, and UTF-16 column and length within it.
        public var line: Int
        public var column: Int
        public var length: Int
        /// The line, trimmed and shortened, with where the match sits in it.
        public var preview: String
        public var previewRange: NSRange
        public var id: String { "\(line):\(column)" }
    }

    public struct FileMatches: Identifiable, Sendable {
        public var path: String
        public var matches: [Match]
        public var id: String { path }
    }

    public struct Result: Sendable {
        public var files: [FileMatches] = []
        public var matchCount = 0
        /// Stopped at `limit` matches.
        public var truncated = false
        public init() {}
    }

    public static let limit = 5_000
    static let maxFileBytes = 2 * 1_048_576

    public static func run(_ query: Query, root: URL, paths: [String]) async -> Result {
        guard let expression = query.expression else { return Result() }
        return await Task.detached(priority: .userInitiated) {
            var result = Result()
            for path in paths {
                if Task.isCancelled { break }
                guard let text = readText(root.appending(path: path)) else { continue }
                let matches = Self.matches(in: text, expression: expression, limit: limit - result.matchCount)
                guard !matches.isEmpty else { continue }
                result.files.append(FileMatches(path: path, matches: matches))
                result.matchCount += matches.count
                if result.matchCount >= limit {
                    result.truncated = true
                    break
                }
            }
            return result
        }.value
    }

    /// Text files only: skips large files and anything with a NUL byte near the start.
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= maxFileBytes,
              !data.prefix(8_000).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func matches(in text: String, expression: NSRegularExpression, limit: Int = .max) -> [Match] {
        let ns = text as NSString
        var matches: [Match] = []
        var line = 0
        var lineStart = 0
        var scanned = 0
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { found, _, stop in
            guard let found, found.range.length > 0 else { return }
            // Advance the line count up to this match.
            while scanned < found.range.location {
                if ns.character(at: scanned) == 0x0A {
                    line += 1
                    lineStart = scanned + 1
                }
                scanned += 1
            }
            let lineRange = ns.lineRange(for: NSRange(location: found.range.location, length: 0))
            var lineText = ns.substring(with: lineRange) as NSString
            lineText = lineText.trimmingCharacters(in: .newlines) as NSString
            let column = found.range.location - lineStart
            let length = min(found.range.length, lineText.length - column)
            let (preview, previewRange) = Self.preview(lineText, column: column, length: max(length, 0))
            matches.append(Match(line: line, column: column, length: found.range.length, preview: preview, previewRange: previewRange))
            if matches.count >= limit { stop.pointee = true }
        }
        return matches
    }

    /// Leading indentation dropped, and long lines cut to show the match.
    static func preview(_ line: NSString, column: Int, length: Int) -> (String, NSRange) {
        var start = 0
        while start < column, let scalar = Unicode.Scalar(line.character(at: start)), CharacterSet.whitespaces.contains(scalar) {
            start += 1
        }
        // Little before the match: the sidebar is narrow and the match should stay in view.
        let context = 16
        var prefix = ""
        if column - start > context {
            start = column - context
            prefix = "…"
        }
        let end = min(line.length, max(column + length + 120, start + 160))
        let suffix = end < line.length ? "…" : ""
        let body = line.substring(with: NSRange(location: start, length: end - start))
        let range = NSRange(location: (prefix as NSString).length + column - start, length: min(length, end - column))
        return (prefix + body + suffix, range)
    }
}
