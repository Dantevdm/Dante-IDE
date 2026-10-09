import Foundation

/// The project's markdown documents, grouped for the Docs area: the README and other
/// top-level docs, the `.dante` specs, decisions and runbooks, phase definitions, and
/// anything under `docs/`.
public struct DocLibrary: Equatable, Sendable {
    public struct Doc: Equatable, Sendable, Identifiable, Hashable {
        /// Project-relative path.
        public var path: String
        public var id: String { path }

        public enum Kind: Equatable, Sendable {
            case markdown, pdf, image
            /// Word, RTF, OpenDocument: previewed as text.
            case document
            /// Slides and spreadsheets, shown by Quick Look.
            case slides
        }

        public init(path: String) { self.path = path }

        public var kind: Kind {
            let ext = (path as NSString).pathExtension.lowercased()
            if DocLibrary.markdownExtensions.contains(ext) { return .markdown }
            if ext == "pdf" { return .pdf }
            if DocLibrary.imageExtensions.contains(ext) { return .image }
            if DocLibrary.slideExtensions.contains(ext) { return .slides }
            return .document
        }

        /// The file name without `.md`, with dashes and underscores as spaces.
        public var title: String {
            let name = (path as NSString).lastPathComponent
            let base = kind == .markdown ? (name as NSString).deletingPathExtension : name
            if base.uppercased() == base || kind != .markdown { return base }
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

    /// The doc Docs opens on: `path` if it's here, else the README, else the first.
    public func doc(preferring path: String?) -> Doc? {
        if let path, let doc = all.first(where: { $0.path == path }) { return doc }
        return all.first { $0.path.lowercased() == "readme.md" } ?? all.first
    }

    /// The doc's folder when another doc in its group has the same title, so three
    /// READMEs read "README  frontend", "README  api"… Nil when the title is unique.
    public func folder(distinguishing doc: Doc) -> String? {
        guard let group = groups.first(where: { $0.docs.contains(doc) }),
              group.docs.contains(where: { $0 != doc && $0.title == doc.title }) else { return nil }
        let folder = (doc.path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "root" : folder
    }
    public var isEmpty: Bool { groups.isEmpty }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff"]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "rtf", "odt"]
    static let slideExtensions: Set<String> = ["key", "pptx", "ppt", "odp", "pages", "numbers", "xlsx", "xls", "ods"]
    /// Where PDFs, images and Word files count as docs. Elsewhere they're app assets.
    /// Documents and slides (not images) at the project root count too.
    static let documentFolders: Set<String> = ["docs", "documentation", ".dante"]
    /// Where files added in Docs go.
    public static let importFolder = "docs"

    public static func isDoc(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return true }
        let document = documentExtensions.contains(ext) || slideExtensions.contains(ext)
        guard imageExtensions.contains(ext) || document else { return false }
        guard path.contains("/"), let top = path.split(separator: "/").first else { return document }
        return documentFolders.contains(top.lowercased())
    }

    /// Where a file added in Docs lands: `docs/<name>`, numbered if that's taken.
    public static func importPath(for name: String, existing: Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = "\(importFolder)/\(name)"
        var number = 2
        while existing.contains(candidate) {
            candidate = "\(importFolder)/\(base) \(number)" + (ext.isEmpty ? "" : ".\(ext)")
            number += 1
        }
        return candidate
    }

    public init(paths: [String]) {
        var buckets: [String: [Doc]] = [:]
        for path in paths where Self.isDoc(path) {
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
        // Markdown before the files it describes.
        if (a.kind == .markdown) != (b.kind == .markdown) { return a.kind == .markdown }
        let (ra, rb) = (rank(a), rank(b))
        return ra != rb ? ra < rb : a.path.localizedStandardCompare(b.path) == .orderedAscending
    }
}
