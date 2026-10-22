import DanteKit
import QuickLookThumbnailing
import SwiftUI

/// Docs' front page: what changed lately, then each group as a card: its folders, a line
/// about each doc, and images as thumbnails.
struct DocsLibraryView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let library: DocLibrary
    let addFiles: () -> Void
    @State private var details: [String: Details] = [:]
    @State private var expanded: Set<String> = []

    struct Details: Sendable {
        var excerpt: String?
        var modified: Date?
    }

    /// Rows a card shows before "Show all".
    private let rowLimit = 6

    var body: some View {
        AreaPage(eyebrow: nil, title: "Docs", subtitle: nil) {
            Button(action: addFiles) { Label("Add files…", systemImage: "plus") }
                .buttonStyle(DanteButtonStyle())
        } content: {
            MotionStudioCard(session: session, pieces: library.all.filter { $0.kind == .motion })
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Recently changed")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(recent) { doc in recentTile(doc) }
                    }
                }
            }
            CardGrid(minimum: 340) {
                ForEach(library.groups) { group in groupCard(group) }
            }
        }
        .task(id: workspace.revision) { await loadDetails() }
    }

    // MARK: Recent

    private var recent: [DocLibrary.Doc] {
        guard library.all.count > 6 else { return [] }
        return library.all
            .compactMap { doc in details[doc.path]?.modified.map { (doc, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map(\.0)
    }

    private func recentTile(_ doc: DocLibrary.Doc) -> some View {
        Tile {
            session.showDoc(doc.path)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(for: doc)).font(.dante(size: 11)).foregroundStyle(theme.accent.color)
                    Text(folder(of: doc)).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    if let modified = details[doc.path]?.modified {
                        Text(modified.relative).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
                    }
                }
                Text(doc.title).font(.dante(size: 13.5, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                if doc.kind == .image {
                    DocThumbnail(url: workspace.url.appending(path: doc.path), side: 200)
                        .frame(height: 64)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else if let excerpt = details[doc.path]?.excerpt {
                    Text(excerpt).font(.dante(size: 12)).foregroundStyle(theme.text2.color).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        }
    }

    // MARK: Groups

    private func groupCard(_ group: DocLibrary.Group) -> some View {
        let showsAll = expanded.contains(group.id)
        let sections = visibleSections(group, all: showsAll)
        let hidden = group.docs.count - sections.reduce(0) { $0 + $1.docs.count }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: Self.symbol(for: group.title))
                        .font(.dante(size: 12, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.accentTint.color))
                    Text(group.title).font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
                    Spacer(minLength: 8)
                    Text("\(group.docs.count)").font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text3.color)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            if !section.folder.isEmpty {
                                Label(section.title, systemImage: section.images.count == section.docs.count ? "photo.on.rectangle" : "folder")
                                    .font(.dante(size: 11, weight: .medium))
                                    .foregroundStyle(theme.text3.color)
                                    .padding(.bottom, 2)
                            }
                            ForEach(section.others) { doc in docLine(doc) }
                            if !section.images.isEmpty {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68, maximum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                                    ForEach(section.images) { doc in
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
                                .padding(.top, 2)
                            }
                        }
                    }
                }
                if hidden > 0 || showsAll && group.docs.count > rowLimit {
                    LinkButton(showsAll ? "Show fewer" : "Show all \(group.docs.count)") {
                        withAnimation(.snappy(duration: 0.2)) {
                            if showsAll { expanded.remove(group.id) } else { expanded.insert(group.id) }
                        }
                    }
                }
            }
        }
    }

    /// The group's sections cut to about `rowLimit` rows; a grid of images counts as one row.
    private func visibleSections(_ group: DocLibrary.Group, all: Bool) -> [DocLibrary.Section] {
        guard !all else { return group.sections }
        var budget = rowLimit
        var result: [DocLibrary.Section] = []
        for section in group.sections where budget > 0 {
            var cut = section
            let others = Array(section.others.prefix(budget))
            budget -= others.count
            var images: [DocLibrary.Doc] = []
            if budget > 0, !section.images.isEmpty {
                images = Array(section.images.prefix(8))
                budget -= 1
            }
            cut.docs = others + images
            if !cut.docs.isEmpty { result.append(cut) }
        }
        return result
    }

    private func docLine(_ doc: DocLibrary.Doc) -> some View {
        Tile(plain: true) {
            session.showDoc(doc.path)
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.symbol(for: doc))
                    .font(.dante(size: 10.5))
                    .foregroundStyle(theme.text3.color)
                    .frame(width: 13)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(doc.title).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(1)
                        if let folder = library.folder(distinguishing: doc) {
                            Text(folder).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.head)
                        }
                    }
                    if let excerpt = details[doc.path]?.excerpt {
                        Text(excerpt).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .help(doc.path)
    }

    private func folder(of doc: DocLibrary.Doc) -> String {
        let folder = (doc.path as NSString).deletingLastPathComponent
        return folder.isEmpty ? workspace.name : folder
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
        }
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
