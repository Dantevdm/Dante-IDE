import Foundation

/// A file with git's conflict markers, split into the text both sides agree on and the
/// hunks where they differ. Each hunk can be resolved by choosing a side, both, the base,
/// or text of your own; unresolved hunks keep their markers.
public struct MergeConflict: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case common(String)
        case conflict(Hunk)
    }

    public struct Hunk: Equatable, Sendable, Identifiable {
        /// The hunk's position among the file's hunks.
        public var id: Int
        /// 1-based line of the `<<<<<<<` marker.
        public var line: Int
        public var ours: String
        /// From diff3-style markers (`|||||||`), or filled in by `fillingBases(from:)`.
        public var base: String?
        public var theirs: String
        public var oursLabel: String
        public var baseLabel: String?
        public var theirsLabel: String
        /// The base came from the file's own markers, so writing the markers back keeps it.
        var baseInMarkers = false
    }

    public enum Choice: Equatable, Sendable {
        case ours, theirs
        /// Ours then theirs.
        case both
        case theirsThenOurs
        case base
        case custom(String)
    }

    public var segments: [Segment]

    public var hunks: [Hunk] {
        segments.compactMap { if case .conflict(let hunk) = $0 { hunk } else { nil } }
    }

    /// The conflicts in `text`, or nil when it has none. A hunk cut off by the end of the
    /// file stays as ordinary text.
    public static func parse(_ text: String) -> MergeConflict? {
        enum Part { case ours, base, theirs }
        var segments: [Segment] = []
        var common = ""
        var hunk: Hunk?
        var raw = ""
        var part = Part.ours
        var lineNumber = 0
        var count = 0

        for line in lines(of: text) {
            lineNumber += 1
            let bare = line.trimmingCharacters(in: .newlines)
            if hunk == nil {
                if let label = marker("<", in: bare) {
                    if !common.isEmpty { segments.append(.common(common)); common = "" }
                    hunk = Hunk(id: count, line: lineNumber, ours: "", base: nil, theirs: "", oursLabel: label, baseLabel: nil, theirsLabel: "")
                    raw = line
                    part = .ours
                } else {
                    common += line
                }
                continue
            }
            raw += line
            if part == .ours, let label = marker("|", in: bare) {
                hunk?.base = ""
                hunk?.baseLabel = label
                hunk?.baseInMarkers = true
                part = .base
            } else if part != .theirs, marker("=", in: bare) != nil {
                part = .theirs
            } else if part == .theirs, let label = marker(">", in: bare) {
                hunk?.theirsLabel = label
                segments.append(.conflict(hunk!))
                hunk = nil
                count += 1
            } else {
                switch part {
                case .ours: hunk?.ours += line
                case .base: hunk?.base? += line
                case .theirs: hunk?.theirs += line
                }
            }
        }
        if hunk != nil { common += raw }
        if !common.isEmpty { segments.append(.common(common)) }
        guard count > 0 else { return nil }
        return MergeConflict(segments: segments)
    }

    /// The label after a 7-character marker (`<<<<<<< HEAD` → "HEAD"), or nil when the
    /// line isn't one.
    static func marker(_ character: Character, in line: String) -> String? {
        let prefix = String(repeating: character, count: 7)
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(7)
        if rest.isEmpty { return "" }
        guard rest.first == " " else { return nil }
        // "=======" never carries a label.
        return character == "=" ? nil : String(rest.dropFirst())
    }

    /// Lines with their line breaks kept.
    static func lines(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "\n" || character == "\r\n" { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Bases for hunks that have none, taken from the same conflict written with diff3
    /// markers (`git merge-file --diff3` on the index stages); hunks match by their sides.
    public func fillingBases(from diff3: MergeConflict) -> MergeConflict {
        var copy = self
        let withBase = diff3.hunks
        copy.segments = segments.map { segment in
            guard case .conflict(var hunk) = segment, hunk.base == nil,
                  let match = withBase.first(where: { $0.ours == hunk.ours && $0.theirs == hunk.theirs && $0.base != nil }) else { return segment }
            hunk.base = match.base
            return .conflict(hunk)
        }
        return copy
    }

    /// The file with each chosen hunk replaced; the rest keep their markers.
    public func resolved(_ choices: [Int: Choice]) -> String {
        segments.map { segment in
            switch segment {
            case .common(let text): text
            case .conflict(let hunk): choices[hunk.id].map { Self.text(for: $0, in: hunk) } ?? Self.markers(for: hunk)
            }
        }.joined()
    }

    public static func text(for choice: Choice, in hunk: Hunk) -> String {
        switch choice {
        case .ours: hunk.ours
        case .theirs: hunk.theirs
        case .both: joined(hunk.ours, hunk.theirs)
        case .theirsThenOurs: joined(hunk.theirs, hunk.ours)
        case .base: hunk.base ?? ""
        case .custom(let text): text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        }
    }

    private static func joined(_ first: String, _ second: String) -> String {
        first.isEmpty || first.hasSuffix("\n") ? first + second : first + "\n" + second
    }

    static func markers(for hunk: Hunk) -> String {
        func label(_ text: String) -> String { text.isEmpty ? "" : " " + text }
        var text = "<<<<<<<\(label(hunk.oursLabel))\n" + hunk.ours
        if hunk.baseInMarkers, let base = hunk.base { text += "|||||||\(label(hunk.baseLabel ?? ""))\n" + base }
        return text + "=======\n" + hunk.theirs + ">>>>>>>\(label(hunk.theirsLabel))\n"
    }

    /// Whether `text` still has a complete conflict in it.
    public static func hasMarkers(_ text: String) -> Bool {
        parse(text) != nil
    }
}

/// A merge, rebase, cherry-pick or revert that stopped on conflicts, read from the files
/// git keeps in its folder while one is in progress.
public struct MergeOperation: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case merge, rebase, cherryPick = "cherry-pick", revert
    }

    public var kind: Kind
    /// What's coming in: the merged branch, the branch being rebased, the commit picked.
    public var subject: String?
    /// "3 of 7" for a rebase.
    public var step: (Int, Int)?

    public static func == (lhs: MergeOperation, rhs: MergeOperation) -> Bool {
        lhs.kind == rhs.kind && lhs.subject == rhs.subject && lhs.step?.0 == rhs.step?.0 && lhs.step?.1 == rhs.step?.1
    }

    /// `read` returns a file's contents inside the git folder (`MERGE_HEAD`,
    /// `rebase-merge/head-name`), or nil when it isn't there.
    public static func detect(read: (String) -> String?) -> MergeOperation? {
        func value(_ path: String) -> String? {
            read(path)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for folder in ["rebase-merge", "rebase-apply"] {
            guard let head = value("\(folder)/head-name") ?? (read("\(folder)/next") != nil ? "" : nil) else { continue }
            let branch = head.hasPrefix("refs/heads/") ? String(head.dropFirst(11)) : (head.isEmpty || head == "detached HEAD" ? nil : head)
            let number = Int(value("\(folder)/msgnum") ?? value("\(folder)/next") ?? "")
            let total = Int(value("\(folder)/end") ?? value("\(folder)/last") ?? "")
            let step = number.flatMap { n in total.map { (n, $0) } }
            return MergeOperation(kind: .rebase, subject: branch, step: step)
        }
        if read("MERGE_HEAD") != nil {
            return MergeOperation(kind: .merge, subject: mergedName(value("MERGE_MSG")), step: nil)
        }
        if read("CHERRY_PICK_HEAD") != nil {
            return MergeOperation(kind: .cherryPick, subject: value("CHERRY_PICK_HEAD").map { String($0.prefix(8)) }, step: nil)
        }
        if read("REVERT_HEAD") != nil {
            return MergeOperation(kind: .revert, subject: value("REVERT_HEAD").map { String($0.prefix(8)) }, step: nil)
        }
        return nil
    }

    /// "Merge branch 'feature' into main" → "feature".
    static func mergedName(_ message: String?) -> String? {
        guard let first = message?.split(separator: "\n").first else { return nil }
        let parts = first.split(separator: "'")
        return parts.count >= 2 ? String(parts[1]) : nil
    }

    public var title: String {
        switch kind {
        case .merge: subject.map { "Merging \($0)" } ?? "Merging"
        case .rebase: (subject.map { "Rebasing \($0)" } ?? "Rebasing") + (step.map { " · commit \($0.0) of \($0.1)" } ?? "")
        case .cherryPick: subject.map { "Cherry-picking \($0)" } ?? "Cherry-picking"
        case .revert: subject.map { "Reverting \($0)" } ?? "Reverting"
        }
    }

    /// What each side of a conflict is. In a rebase "ours" is the branch being rebased
    /// onto and "theirs" is your commit being replayed, the reverse of a merge.
    public var sides: (ours: String, theirs: String) {
        switch kind {
        case .rebase: ("Upstream", "Your commit")
        case .merge: ("Yours", subject ?? "Theirs")
        case .cherryPick: ("Yours", "Picked commit")
        case .revert: ("Yours", "Reverted")
        }
    }

    public var continueArguments: [String] { [kind.rawValue, "--continue"] }
    public var abortArguments: [String] { [kind.rawValue, "--abort"] }
}
