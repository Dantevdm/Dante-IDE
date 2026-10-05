import Foundation

/// The project's markdown documents, grouped for the Docs area: the README and other
/// top-level docs, the `.dante` specs, decisions and runbooks, phase definitions, and
/// anything under `docs/`.
public struct DocLibrary: Equatable, Sendable {
    public struct Doc: Equatable, Sendable, Identifiable, Hashable {
        /// Project-relative path.
        public var path: String
        public var id: String { path }

        public init(path: String) { self.path = path }

        /// The file name without `.md`, with dashes and underscores as spaces.
        public var title: String {
            let name = (path as NSString).lastPathComponent
            let base = (name as NSString).deletingPathExtension
            if base.uppercased() == base { return base }
            let spaced = base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
    }

    public struct Group: Equatable, Sendable, Identifiable {
        public var title: String
        public var docs: [Doc]
        public var id: String { title }
    }

    public var groups: [Group]

    public var all: [Doc] { groups.flatMap(\.docs) }
    public var isEmpty: Bool { groups.isEmpty }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]

    public init(paths: [String]) {
        var buckets: [String: [Doc]] = [:]
        for path in paths where Self.markdownExtensions.contains((path as NSString).pathExtension.lowercased()) {
            buckets[Self.group(for: path), default: []].append(Doc(path: path))
        }
        groups = Self.order.compactMap { title in
            guard let docs = buckets.removeValue(forKey: title), !docs.isEmpty else { return nil }
            return Group(title: title, docs: docs.sorted(by: Self.ordered))
        } + buckets.keys.sorted().map { Group(title: $0, docs: buckets[$0]!.sorted(by: Self.ordered)) }
    }

    static let order = ["Project", "Specs", "Decisions", "Runbooks", "Plan", "Phases", "Docs", "Elsewhere"]

    static func group(for path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 1 { return "Project" }
        if parts[0] == ".dante" {
            switch parts.count > 2 ? parts[1] : "" {
            case "specs": return "Specs"
            case "decisions", "adr", "adrs": return "Decisions"
            case "runbooks": return "Runbooks"
            case "phases": return "Phases"
            default: return "Plan"
            }
        }
        if parts[0].lowercased() == "docs" || parts[0].lowercased() == "documentation" { return "Docs" }
        return "Elsewhere"
    }

    /// README first, then by path. Phases keep lifecycle order.
    static func ordered(_ a: Doc, _ b: Doc) -> Bool {
        let rank = { (doc: Doc) -> Int in
            let name = (doc.path as NSString).lastPathComponent.lowercased()
            if name.hasPrefix("readme") { return 0 }
            if let index = Lifecycle.defaultPhases.firstIndex(where: { $0.lowercased() + ".md" == name }) { return 1 + index }
            return 100
        }
        let (ra, rb) = (rank(a), rank(b))
        return ra != rb ? ra < rb : a.path.localizedStandardCompare(b.path) == .orderedAscending
    }
}
