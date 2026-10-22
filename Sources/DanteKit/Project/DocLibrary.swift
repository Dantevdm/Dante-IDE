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
            case markdown, pdf, image, html
            /// Word, RTF, OpenDocument: previewed as text.
            case document
            /// Slides and spreadsheets, shown by Quick Look.
            case slides
            /// A motion piece's `motion.yaml`: a video, deck or explainer Dante plays and renders.
            case motion
            /// A `.dante-diagram.json` drawn in the Map's style, opened in the diagram editor.
            case diagram
        }

        public init(path: String) { self.path = path }

        public var kind: Kind {
            if MotionPiece.isManifest(path) { return .motion }
            if Diagram.isDiagram(path) { return .diagram }
            let ext = (path as NSString).pathExtension.lowercased()
            if DocLibrary.markdownExtensions.contains(ext) { return .markdown }
            if ext == "pdf" { return .pdf }
            if ["html", "htm"].contains(ext) { return .html }
            if DocLibrary.imageExtensions.contains(ext) { return .image }
            if DocLibrary.slideExtensions.contains(ext) { return .slides }
            return .document
        }

        /// The file name without `.md`, with dashes and underscores as spaces.
        public var title: String {
            if kind == .motion {
                // The piece's folder: "anatomy-of-the-api" reads "Anatomy of the api".
                let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let spaced = folder.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
                return spaced.prefix(1).uppercased() + spaced.dropFirst()
            }
            if kind == .diagram { return Diagram.title(ofPath: path) }
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
        /// The top-level folder a group of docs kept beside the code is named after
        /// ("infrastructure"); nil for the other groups.
        public var root: String?
        public var id: String { root.map { "folder:" + $0 } ?? title }

        public init(title: String, docs: [Doc], root: String? = nil) {
            self.title = title
            self.docs = docs
            self.root = root
        }

        /// The group's docs by folder: its own folder's first, then each subfolder's.
        /// Under `docs/`, `docs/plans/x.md` is in "plans"; elsewhere a doc's folder is its path.
        public var sections: [Section] {
            var order: [String] = []
            var byFolder: [String: [Doc]] = [:]
            for doc in docs {
                let folder = DocLibrary.folder(of: doc.path, in: self)
                if byFolder[folder] == nil { order.append(folder) }
                byFolder[folder, default: []].append(doc)
            }
            return order
                .sorted { a, b in a.isEmpty != b.isEmpty ? a.isEmpty : a.localizedStandardCompare(b) == .orderedAscending }
                .map { Section(group: id, folder: $0, docs: byFolder[$0]!) }
        }
    }

    /// Docs in one folder of a group.
    public struct Section: Equatable, Sendable, Identifiable {
        public var group: String
        /// Relative to the group's folder; empty for the group's own.
        public var folder: String
        public var docs: [Doc]
        public var id: String { "\(group)/\(folder)" }

        /// What the docs belong to: "plans" reads "Plans"; deeper down it's the last folder
        /// that isn't only for docs, so `aws/cloudformation/portal-alb-stack/documentation`
        /// reads "portal-alb-stack".
        public var title: String {
            let parts = owner
            guard let name = parts.name else { return "" }
            guard parts.context == nil, !folder.contains("/"), name.lowercased() == name else { return name }
            let spaced = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }

        /// The folders above `title` ("aws/cloudformation"), or nil.
        public var context: String? { owner.context }

        private var owner: (name: String?, context: String?) {
            var parts = folder.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { return (nil, nil) }
            while parts.count > 1, let last = parts.last, DocLibrary.docFolderNames.contains(last.lowercased()) { parts.removeLast() }
            let name = parts.removeLast()
            return (name, parts.isEmpty ? nil : parts.joined(separator: "/"))
        }

        /// Images, shown as thumbnails rather than rows.
        public var images: [Doc] { docs.filter { $0.kind == .image } }
        public var others: [Doc] { docs.filter { $0.kind != .image } }
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

    /// What Docs shows instead of a document: every group at a glance.
    public static let libraryPath = "#library"
    /// Docs › Standards: principles, UI standards and themes.
    public static let standardsPath = "#standards"

    /// The docs whose title or path has every word of `query`, in their groups.
    public func filtered(_ query: String) -> DocLibrary {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return self }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var copy = self
        copy.groups = groups.compactMap { group in
            let docs = group.docs.filter { doc in
                words.allSatisfy { doc.title.range(of: $0, options: options) != nil || doc.path.range(of: $0, options: options) != nil }
            }
            guard !docs.isEmpty else { return nil }
            var copy = group
            copy.docs = docs
            return copy
        }
        return copy
    }

    /// A doc's folder within its group: see `Group.sections`.
    static func folder(of path: String, in group: Group) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let root: String
        if let top = group.root {
            root = top
        } else {
            switch group.title {
            case "Project", Self.aroundTheCode: return directory
            case "Motion", "Diagrams": return ""
            case "Docs": root = directory.split(separator: "/").first.map(String.init) ?? ""
            case "Notes": root = ".dante"
            default: root = directory.split(separator: "/").prefix(2).joined(separator: "/")
            }
        }
        guard directory.count > root.count, directory.hasPrefix(root + "/") else { return "" }
        return String(directory.dropFirst(root.count + 1))
    }

    /// Folders that only hold docs, named past to say what the docs are about.
    static let docFolderNames: Set<String> = ["documentation", "docs", "doc"]
    /// Docs beside the code, from top-level folders with only one doc each.
    public static let aroundTheCode = "Around the code"

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff"]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "rtf", "odt", "html", "htm"]
    static let slideExtensions: Set<String> = ["key", "pptx", "ppt", "odp", "pages", "numbers", "xlsx", "xls", "ods"]
    /// Where PDFs, images and Word files count as docs. Elsewhere they're app assets.
    /// Documents and slides (not images) at the project root count too.
    static let documentFolders: Set<String> = ["docs", "documentation", ".dante"]
    /// Where files added in Docs go.
    public static let importFolder = "docs"

    public static func isDoc(_ path: String) -> Bool {
        if MotionPiece.isManifest(path) { return path.contains("/") }
        if Diagram.isDiagram(path) { return true }
        // A piece's scene, stills and exports are its own: Docs lists the piece.
        if path.hasPrefix(MotionPiece.folder + "/") || path.contains("/renders/") { return false }
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
        var beside: [String: [Doc]] = [:]
        let all = Set(paths)
        // Another agent's version of a piece is opened from the piece, not listed beside it.
        for path in paths where Self.isDoc(path) && !MotionPiece.isOtherVersion(path, among: all) {
            if let group = Self.group(for: path) {
                buckets[group, default: []].append(Doc(path: path))
            } else {
                beside[String(path.split(separator: "/")[0]), default: []].append(Doc(path: path))
            }
        }
        // A top-level folder with several docs is a group of its own, named after it.
        var around: [Doc] = []
        var folders: [Group] = []
        for (top, docs) in beside {
            if docs.count > 1 {
                folders.append(Group(title: Self.title(ofFolder: top), docs: docs.sorted(by: Self.ordered), root: top))
            } else {
                around += docs
            }
        }
        groups = Self.order.compactMap { title in
            guard let docs = buckets[title], !docs.isEmpty else { return nil }
            return Group(title: title, docs: docs.sorted(by: Self.ordered))
        }
        groups += folders.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if !around.isEmpty { groups.append(Group(title: Self.aroundTheCode, docs: around.sorted(by: Self.ordered))) }
    }

    static let order = ["Project", "Motion", "Diagrams", "Specs", "Decisions", "Runbooks", "Notes", "Phases", "Docs"]

    /// "infrastructure" reads "Infrastructure", "build-tools" "Build tools"; dot folders stay, and
    /// a folder named like one of the groups above reads "notes/".
    static func title(ofFolder folder: String) -> String {
        if order.contains(where: { $0.lowercased() == folder.lowercased() }) || folder == aroundTheCode { return folder + "/" }
        guard !folder.hasPrefix("."), folder.lowercased() == folder else { return folder }
        let spaced = folder.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// The named group a doc belongs to, or nil for a doc kept beside the code.
    static func group(for path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 1 { return "Project" }
        if parts[0] == ".dante" {
            switch parts.count > 2 ? parts[1] : "" {
            case "specs": return "Specs"
            case "decisions", "adr", "adrs": return "Decisions"
            case "runbooks": return "Runbooks"
            case "phases": return "Phases"
            default: return "Notes"
            }
        }
        if MotionPiece.isManifest(path) { return "Motion" }
        if Diagram.isDiagram(path) { return "Diagrams" }
        if parts[0].lowercased() == "docs" || parts[0].lowercased() == "documentation" { return "Docs" }
        return nil
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
