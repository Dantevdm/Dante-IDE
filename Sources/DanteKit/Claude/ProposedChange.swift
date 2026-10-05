import Foundation

/// One row of a line diff.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, added, removed, gap }

    public var kind: Kind
    public var text: String
    /// 1-based line number in the old file (context and removed lines).
    public var oldNumber: Int?
    /// 1-based line number in the new file (context and added lines).
    public var newNumber: Int?
}

public enum LineDiff {
    /// A line diff of two texts, keeping `context` unchanged lines around each change and
    /// folding longer unchanged runs into a single `.gap` row.
    public static func lines(old: String, new: String, context: Int = 3) -> [DiffLine] {
        fold(unfolded(old: old, new: new), context: context)
    }

    /// Every line of both texts, unchanged ones included.
    static func unfolded(old: String, new: String) -> [DiffLine] {
        let a = split(old), b = split(new)
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var all: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                all.append(DiffLine(kind: .removed, text: a[i], oldNumber: i + 1))
                i += 1
            } else if j < b.count, inserted.contains(j) {
                all.append(DiffLine(kind: .added, text: b[j], newNumber: j + 1))
                j += 1
            } else {
                if i < a.count, j < b.count {
                    all.append(DiffLine(kind: .context, text: a[i], oldNumber: i + 1, newNumber: j + 1))
                }
                i += 1
                j += 1
            }
        }
        return all
    }

    static func lineCount(_ text: String) -> Int { split(text).count }

    private static func split(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func fold(_ lines: [DiffLine], context: Int) -> [DiffLine] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            keep.formUnion(max(0, index - context)...min(lines.count - 1, index + context))
        }
        var result: [DiffLine] = []
        var skipped = false
        for index in lines.indices {
            if keep.contains(index) {
                if skipped, !result.isEmpty { result.append(DiffLine(kind: .gap, text: "")) }
                skipped = false
                result.append(lines[index])
            } else {
                skipped = true
            }
        }
        return result
    }
}

/// A file change Claude has proposed through Edit, MultiEdit or Write, as a diff to review.
public struct ProposedChange: Equatable, Sendable {
    public var url: URL
    public var displayPath: String
    public var isNewFile: Bool
    public var lines: [DiffLine]
    /// False when an edit's `old_string` isn't in the file as it is now, so the edit would fail.
    public var applies: Bool

    public var added: Int { lines.count { $0.kind == .added } }
    public var removed: Int { lines.count { $0.kind == .removed } }

    public static let toolNames: Set<String> = ["Edit", "MultiEdit", "Write"]

    /// Builds the diff for a tool call, reading the current file from disk.
    public static func make(toolName: String, input: JSONValue, root: URL) -> ProposedChange? {
        guard toolNames.contains(toolName), let path = input["file_path"]?.string else { return nil }
        let url = URL(filePath: path, relativeTo: root).standardizedFileURL
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let old = existing ?? ""

        var new = old
        var applies = true
        switch toolName {
        case "Write":
            new = input["content"]?.string ?? ""
        case "Edit":
            applies = apply(edit: input, to: &new)
        case "MultiEdit":
            for edit in input["edits"]?.array ?? [] where !apply(edit: edit, to: &new) {
                applies = false
            }
        default:
            return nil
        }

        return ProposedChange(
            url: url,
            displayPath: relativePath(of: url, in: root),
            isNewFile: existing == nil,
            lines: LineDiff.lines(old: old, new: new),
            applies: applies
        )
    }

    private static func apply(edit: JSONValue, to text: inout String) -> Bool {
        let target = edit["old_string"]?.string ?? ""
        let replacement = edit["new_string"]?.string ?? ""
        if target.isEmpty {
            // An empty old_string creates the file's content.
            guard text.isEmpty else { return false }
            text = replacement
            return true
        }
        guard let range = text.range(of: target) else { return false }
        if edit["replace_all"]?.bool == true {
            text = text.replacingOccurrences(of: target, with: replacement)
        } else {
            text.replaceSubrange(range, with: replacement)
        }
        return true
    }

    public static func relativePath(of url: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
