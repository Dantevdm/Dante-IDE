import Foundation

/// How a line differs from the last commit, for the marks in the editor gutter.
public enum LineChange: Equatable, Sendable {
    case added, modified
    /// Lines were removed just above this one (or below it, on the last line).
    case deleted
}

public enum GitGutter {
    /// Zero-based line numbers in `current` and how each changed from `base`.
    public static func changes(base: String, current: String) -> [Int: LineChange] {
        var result: [Int: LineChange] = [:]
        var removed = 0
        var added: [Int] = []
        var nextLine = 0
        func flush() {
            defer { removed = 0; added = [] }
            guard removed > 0 || !added.isEmpty else { return }
            for (index, line) in added.enumerated() {
                result[line] = index < removed ? .modified : .added
            }
            if added.isEmpty {
                result[nextLine] = result[nextLine] ?? .deleted
            }
        }
        for line in LineDiff.unfolded(old: base, new: current) {
            switch line.kind {
            case .removed:
                removed += 1
            case .added:
                if let number = line.newNumber { added.append(number - 1) }
            case .context:
                // The first unchanged line after a change is where a pure deletion shows.
                nextLine = (line.newNumber ?? 1) - 1
                flush()
            case .gap:
                break
            }
        }
        // A deletion at the very end marks the last line.
        nextLine = max(LineDiff.lineCount(current) - 1, 0)
        flush()
        return result
    }

    /// The file as of HEAD, or nil when it isn't tracked (or the folder isn't a repository).
    public static func headText(of url: URL, in root: URL) async -> String? {
        let path = ProposedChange.relativePath(of: url, in: root)
        guard !path.hasPrefix("/") else { return nil }
        let output = await Shell.run(["git", "show", "HEAD:./\(path)"], in: root, trimming: false)
        return output.succeeded ? output.stdout : nil
    }
}
