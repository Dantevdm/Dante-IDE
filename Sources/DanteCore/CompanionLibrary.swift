import Foundation

/// Exploring a project from the iPhone or iPad without copying it there. The Mac lists the
/// project's docs, pictures and diagrams (`CompanionLibrary`), and renders the one the device
/// opens at the device's width (`CompanionPage`): markdown as blocks with its diagrams drawn as
/// pictures, images scaled down, a PDF a page at a time, diagrams and the system map as
/// pictures. Every page carries a hash of what it was made from; the device sends back the hash
/// it already holds and gets `unchanged` instead of the bytes again.
public struct CompanionLibrary: Codable, Equatable, Sendable {
    public var project: String
    public var sections: [Section]

    public init(project: String, sections: [Section]) {
        self.project = project
        self.sections = sections
    }

    public struct Section: Codable, Equatable, Sendable, Identifiable {
        public var title: String
        public var entries: [Entry]
        public var id: String { title }

        public init(title: String, entries: [Entry]) {
            self.title = title
            self.entries = entries
        }
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable, Hashable {
        /// Project-relative, or one of the `CompanionPage.Special` paths.
        public var path: String
        public var title: String
        public var kind: CompanionPage.Kind
        /// The folder, the first line, or what a special page shows.
        public var detail: String?
        public var id: String { path }

        public init(path: String, title: String, kind: CompanionPage.Kind, detail: String? = nil) {
            self.path = path
            self.title = title
            self.kind = kind
            self.detail = detail
        }
    }

    public var entries: [Entry] { sections.flatMap(\.entries) }
    public var isEmpty: Bool { sections.allSatisfy(\.entries.isEmpty) }
}

/// What the device asks to see.
public struct CompanionPageRequest: Codable, Equatable, Sendable, Hashable {
    public var path: String
    /// A PDF's page (from 0), or which of a markdown file's figures (`CompanionPage.Figure.index`).
    public var page: Int?
    /// The width it will be shown at, in points, and the screen's scale: pictures are drawn
    /// for exactly that many pixels.
    public var width: Int
    public var scale: Double
    public var dark: Bool
    /// The hash of the copy the device already has.
    public var known: String?

    public init(path: String, page: Int? = nil, width: Int, scale: Double, dark: Bool, known: String? = nil) {
        self.path = path
        self.page = page
        self.width = width
        self.scale = scale
        self.dark = dark
        self.known = known
    }

    /// The device's cache key: the same page at the same size and look.
    public var cacheKey: String {
        "\(path)|\(page.map(String.init) ?? "-")|\(width)|\(Int(scale * 10))|\(dark ? "d" : "l")"
    }

    /// Pictures are made for at most this many pixels across, however wide the screen.
    public static let maximumPixels = 2732

    public var pixelWidth: Int { min(Self.maximumPixels, max(200, Int(Double(width) * scale))) }
}

/// One rendered page.
public struct CompanionPage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case markdown, image, pdf, diagram, text
    }

    /// Pages that aren't files.
    public enum Special {
        /// The system map, drawn from the code.
        public static let system = "dante:system"
        /// The infrastructure and pipelines.
        public static let infrastructure = "dante:infrastructure"
    }

    public var path: String
    public var title: String
    public var kind: Kind
    public var hash: String
    /// The device's copy is current: no body follows.
    public var unchanged: Bool
    /// Markdown, read into blocks on the Mac.
    public var blocks: [Block]?
    /// A Word, RTF or plain text document as text.
    public var text: String?
    /// A JPEG or PNG for images, PDF pages, diagrams and figures.
    public var image: Data?
    /// The picture's size in pixels.
    public var imageWidth: Int?
    public var imageHeight: Int?
    /// A PDF's page count, and which page this is.
    public var pages: Int?
    public var page: Int?
    /// Why there's nothing to show.
    public var problem: String?

    public init(path: String, title: String, kind: Kind, hash: String, unchanged: Bool = false, blocks: [Block]? = nil, text: String? = nil,
                image: Data? = nil, imageWidth: Int? = nil, imageHeight: Int? = nil, pages: Int? = nil, page: Int? = nil, problem: String? = nil) {
        self.path = path
        self.title = title
        self.kind = kind
        self.hash = hash
        self.unchanged = unchanged
        self.blocks = blocks
        self.text = text
        self.image = image
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.pages = pages
        self.page = page
        self.problem = problem
    }

    /// A markdown block. Inline markdown (bold, links, `code`) stays in the text.
    public enum Block: Codable, Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case item(text: String, depth: Int, marker: String)
        case quote(String)
        case code(String, language: String?)
        case table(header: [String], rows: [[String]])
        case rule
        /// A diagram or picture, fetched on its own as the reader scrolls to it.
        case figure(Figure)
    }

    public struct Figure: Codable, Equatable, Sendable, Hashable {
        /// For a ```mermaid block: its index among the file's figures, asked for as `page`.
        public var index: Int?
        /// For a picture: its project-relative path, asked for as a page of its own.
        public var path: String?
        public var caption: String
        /// width ÷ height when known, so the reader can hold the space before it arrives.
        public var aspect: Double?

        public init(index: Int? = nil, path: String? = nil, caption: String, aspect: Double? = nil) {
            self.index = index
            self.path = path
            self.caption = caption
            self.aspect = aspect
        }
    }

    /// Text pages are cut here; nobody reads more than this on a phone.
    public static let textLimit = 200_000
}
