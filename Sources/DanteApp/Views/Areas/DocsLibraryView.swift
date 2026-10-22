import DanteKit
import QuickLookThumbnailing
import SwiftUI

/// Docs' front page: what changed lately, the diagrams and motion pieces made here, then every
/// doc as a directory: a section per group, a heading per thing the docs belong to, and a row
/// per doc with its first line and age. Groups and headings fold. New starts any kind of doc.
struct DocsLibraryView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let library: DocLibrary
    let addFiles: () -> Void
    let create: (DocCreation) -> Void
    @State private var details: [String: Details] = [:]
    @State private var expanded: Set<String> = []

    struct Details: Sendable {
        var excerpt: String?
        var modified: Date?
    }

    /// Rows a heading shows before "Show all".
    private let rowLimit = 6

    private var folderCount: Int { library.groups.reduce(0) { $0 + $1.sections.count } }

    var body: some View {
        AreaPage(eyebrow: nil, title: "Docs",
                 subtitle: "\(library.all.count) doc\(library.all.count == 1 ? "" : "s") in \(folderCount) folder\(folderCount == 1 ? "" : "s")",
                 maxWidth: 1240) {
            Button { session.writeBrandKit() } label: { Label("Brand kit", systemImage: "paintpalette") }
                .buttonStyle(DanteButtonStyle())
                .help("Open .dante/brand.yaml: colours, fonts, logo, motion and voice for diagrams, decks and videos (written from the project’s own styles the first time)")
            Button(action: addFiles) { Label("Add files…", systemImage: "tray.and.arrow.down") }
                .buttonStyle(DanteButtonStyle())
                .help("Copy PDFs, Word files, slides and images into docs/")
            Button { create(.doc(nil)) } label: { Label("New", systemImage: "plus") }
                .buttonStyle(DanteButtonStyle(primary: true))
        } content: {
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Recently changed")
                    // One row: as many as fit, never a row and a straggler.
                    ViewThatFits(in: .horizontal) {
                        ForEach([4, 3, 2], id: \.self) { count in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(recent.prefix(count)) { doc in recentTile(doc).frame(minWidth: 190, idealWidth: 190, maxWidth: .infinity) }
                            }
                        }
                    }
                }
            }
            MadeInDante(session: session, workspace: workspace,
                        diagrams: library.all.filter { $0.kind == .diagram }, pieces: library.all.filter { $0.kind == .motion })
            ForEach(library.groups.filter { !Self.madeHere.contains($0.title) }) { group in groupSection(group) }
        }
        .task(id: workspace.revision) { await loadDetails() }
    }

    /// Groups shown in the strip above rather than the directory.
    private static let madeHere: Set<String> = ["Motion", "Diagrams"]

    // MARK: Recent

    private var recent: [DocLibrary.Doc] {
        guard library.all.count > 6 else { return [] }
        return library.all
            .filter { $0.kind != .motion && $0.kind != .diagram }
            .compactMap { doc in details[doc.path]?.modified.map { (doc, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map(\.0)
    }

    private func recentTile(_ doc: DocLibrary.Doc) -> some View {
        Tile {
            session.showDoc(doc.path)
        } content: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(for: doc)).font(.dante(size: 11)).foregroundStyle(theme.accent.color)
                    Text(owner(of: doc)).font(.dante(size: 11, weight: .medium)).foregroundStyle(theme.text3.color).lineLimit(1)
                    Spacer(minLength: 4)
                    if let modified = details[doc.path]?.modified {
                        Text(modified.relative).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
                    }
                }
                Text(doc.title).font(.dante(size: 13.5, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                if doc.kind == .image {
                    DocThumbnail(url: workspace.url.appending(path: doc.path), side: 200)
                        .frame(height: 48)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if let excerpt = details[doc.path]?.excerpt {
                    Text(excerpt).font(.dante(size: 12)).foregroundStyle(theme.text2.color).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 74, maxHeight: .infinity, alignment: .topLeading)
        }
        .help(doc.path)
    }

    /// What a doc belongs to: its folder's name past any docs-only folder, else the project.
    private func owner(of doc: DocLibrary.Doc) -> String {
        let parts = (doc.path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        return parts.last { !["documentation", "docs", "doc"].contains($0.lowercased()) } ?? parts.last ?? workspace.name
    }

    // MARK: Directory

    private func groupSection(_ group: DocLibrary.Group) -> some View {
        let open = !session.docsFolded.contains(group.id)
        return VStack(alignment: .leading, spacing: 10) {
            FoldHeader(open: open) { toggle(group.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(for: group.title)).font(.dante(size: 11, weight: .medium)).foregroundStyle(theme.text3.color)
                    Eyebrow(group.title)
                    Text("\(group.docs.count)").font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                    if let root = group.root {
                        Text(root + "/").font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color.opacity(0.7))
                    }
                }
            }
            if open {
                VStack(spacing: 0) {
                    let sections = group.sections
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        if index > 0 { Rectangle().fill(theme.line.color).frame(height: 1) }
                        sectionView(section)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
            }
        }
        .padding(.top, 6)
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if session.docsFolded.contains(id) { session.docsFolded.remove(id) } else { session.docsFolded.insert(id) }
        }
    }

    private func sectionView(_ section: DocLibrary.Section) -> some View {
        let showsAll = expanded.contains(section.id)
        let others = showsAll ? section.others : Array(section.others.prefix(rowLimit))
        // A group's loose docs have no heading, so they can't fold.
        let open = section.folder.isEmpty || !session.docsFolded.contains(section.id)
        return VStack(alignment: .leading, spacing: 2) {
            if !section.folder.isEmpty {
                FoldHeader(open: open) { toggle(section.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: section.images.count == section.docs.count ? "photo.on.rectangle" : "folder")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.accent.color)
                    Text(section.title).font(.dante(size: 13.5, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                    if let context = section.context {
                        Text(context).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    Text("\(section.docs.count)").font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, open ? 4 : 0)
                .help(section.folder)
            }
            if open { sectionRows(section, others: others, showsAll: showsAll) }
        }
        .padding(10)
    }

    @ViewBuilder
    private func sectionRows(_ section: DocLibrary.Section, others: [DocLibrary.Doc], showsAll: Bool) -> some View {
            ForEach(others) { doc in docRow(doc) }
            if section.others.count > rowLimit {
                LinkButton(showsAll ? "Show fewer" : "Show all \(section.others.count)") {
                    withAnimation(.snappy(duration: 0.2)) {
                        if showsAll { expanded.remove(section.id) } else { expanded.insert(section.id) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
            }
            if !section.images.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68, maximum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(showsAll ? section.images : Array(section.images.prefix(12))) { doc in
                        Button { session.showDoc(doc.path) } label: {
                            DocThumbnail(url: workspace.url.appending(path: doc.path), side: 96)
                                .aspectRatio(1, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.line.color))
                        }
                        .buttonStyle(.plain)
                        .help(doc.path)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
    }

    private func docRow(_ doc: DocLibrary.Doc) -> some View {
        Tile(plain: true) {
            session.showDoc(doc.path)
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: Self.symbol(for: doc))
                    .font(.dante(size: 11))
                    .foregroundStyle(theme.text3.color)
                    .frame(width: 14)
                Text(doc.title).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(1)
                    .frame(width: 230, alignment: .leading)
                Text(details[doc.path]?.excerpt ?? "")
                    .font(.dante(size: 12)).foregroundStyle(theme.text3.color).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let modified = details[doc.path]?.modified {
                    Text(modified.relative).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        .frame(minWidth: 70, alignment: .trailing)
                }
            }
        }
        .help(doc.path)
    }

    // MARK: Loading

    /// Each doc's first lines and modification date, read off the main thread.
    private func loadDetails() async {
        let root = workspace.url
        let docs = Array(library.all.prefix(500))
        let found = await Task.detached(priority: .utility) {
            var result: [String: Details] = [:]
            for doc in docs {
                let url = root.appending(path: doc.path)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                var excerpt: String?
                if doc.kind == .markdown, let handle = try? FileHandle(forReadingFrom: url) {
                    let data = (try? handle.read(upToCount: 16_384)) ?? Data()
                    try? handle.close()
                    excerpt = DocExcerpt.of(String(decoding: data, as: UTF8.self))
                }
                result[doc.path] = Details(excerpt: excerpt, modified: modified)
            }
            return result
        }.value
        details = found
    }

    // MARK: Symbols

    static func symbol(for group: String) -> String {
        switch group {
        case "Project": "shippingbox"
        case "Specs": "list.bullet.rectangle"
        case "Decisions": "signpost.right"
        case "Runbooks": "book.closed"
        case "Notes": "map"
        case "Phases": "flag"
        case "Docs": "books.vertical"
        case "Motion": "film.stack"
        case "Diagrams": "point.3.filled.connected.trianglepath.dotted"
        case DocLibrary.aroundTheCode: "chevron.left.forwardslash.chevron.right"
        default: "folder"
        }
    }

    static func symbol(for doc: DocLibrary.Doc) -> String {
        switch doc.kind {
        case .markdown: "doc.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .slides: "rectangle.on.rectangle"
        case .document: "doc"
        case .html: "globe"
        case .motion: "film.stack"
        case .diagram: "point.3.filled.connected.trianglepath.dotted"
        }
    }
}

/// A heading that folds what's under it: a chevron, then the label, the whole row clickable.
private struct FoldHeader<Label: View>: View {
    @Environment(\.theme) private var theme
    let open: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.dante(size: 9, weight: .semibold))
                    .foregroundStyle(theme.text3.color)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12)
                label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A clickable block with a hover background: a raised card, or a plain row.
private struct Tile<Content: View>: View {
    @Environment(\.theme) private var theme
    var plain = false
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(plain ? 6 : 14)
                .background(
                    RoundedRectangle(cornerRadius: plain ? 6 : 10, style: .continuous)
                        .fill(plain ? (hovering ? theme.raised.color : .clear) : (hovering ? theme.raised.color : theme.card.color))
                )
                .overlay {
                    if !plain {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hovering ? theme.line2.color : theme.line.color)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A file's Quick Look thumbnail: images and PDFs as themselves, other files as their icon.
struct DocThumbnail: View {
    @Environment(\.theme) private var theme
    let url: URL
    /// The longest side to render, in points.
    var side: CGFloat = 96
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            theme.raised.color
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.dante(size: 14)).foregroundStyle(theme.text3.color)
            }
        }
        .clipped()
        .task(id: url) { image = await Thumbnails.image(for: url, side: side) }
    }
}

@MainActor
enum Thumbnails {
    private static var cache: [String: NSImage] = [:]

    private struct Rendered: @unchecked Sendable { let image: CGImage? }

    static func image(for url: URL, side: CGFloat) async -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(Int(side))#\(modified)"
        if let cached = cache[key] { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2, representationTypes: .thumbnail)
        let rendered = await withCheckedContinuation { (continuation: CheckedContinuation<Rendered, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: Rendered(image: representation?.cgImage))
            }
        }
        guard let cgImage = rendered.image else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
        if cache.count > 400 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
