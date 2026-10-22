import DanteEditor
import DanteKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The Docs outline: the library, then each group with its folders folded away, and a filter.
/// Images sit in a thumbnail grid rather than a list of file names.
struct DocsSidebar: View {
    @Environment(\.theme) private var theme
    let session: Session
    let library: DocLibrary
    let root: URL
    /// Nil while the library shows.
    let selected: DocLibrary.Doc?
    let addFiles: () -> Void
    @State private var query = ""
    @FocusState private var filterFocused: Bool
    /// Groups and folders opened or closed by hand, as "id\t1" lines.
    @AppStorage("docsFolding") private var folding = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                    TextField("Filter", text: $query)
                        .textFieldStyle(.plain)
                        .font(.dante(size: 12.5))
                        .focused($filterFocused)
                        .onSubmit { if let first = library.filtered(query).all.first { session.showDoc(first.path) } }
                        .onExitCommand { query = "" }
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filterFocused ? theme.accentLine.color : theme.line.color))
                Button(action: addFiles) {
                    Image(systemName: "plus")
                        .font(.dante(size: 12, weight: .medium))
                        .foregroundStyle(theme.text2.color)
                        .frame(width: 28, height: 28)
                        .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add PDFs, images or documents to docs/. You can also drop them on Docs.")
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if query.isEmpty {
                        SidebarRow(title: "Library", symbol: "square.grid.2x2", count: library.all.count, isSelected: selected == nil) {
                            session.showDoc(DocLibrary.libraryPath)
                        }
                        ForEach(library.groups) { group in
                            groupView(group)
                        }
                    } else {
                        let found = library.filtered(query)
                        if found.isEmpty {
                            Text("No matches").font(.dante(size: 12)).foregroundStyle(theme.text3.color).padding(.horizontal, 12)
                        }
                        ForEach(found.groups) { group in
                            VStack(alignment: .leading, spacing: 1) {
                                Eyebrow(group.title).padding(.horizontal, 12).padding(.bottom, 4)
                                ForEach(group.docs) { doc in
                                    DocRow(doc: doc, folder: (doc.path as NSString).deletingLastPathComponent.nonEmpty, isSelected: doc == selected) { session.showDoc(doc.path) }
                .docMenu(doc, session: session)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 20)
            }
        }
        .background(theme.panel.color)
    }

    private func groupView(_ group: DocLibrary.Group) -> some View {
        let key = "g:\(group.id)"
        let open = isOpen(key, default: true)
        return VStack(alignment: .leading, spacing: 1) {
            FoldHeader(open: open, count: group.docs.count) { toggle(key, open) } label: {
                Eyebrow(group.title)
            }
            if open {
                ForEach(group.sections) { section in
                    if section.folder.isEmpty {
                        contents(of: section)
                    } else {
                        sectionView(section)
                    }
                }
            }
        }
    }

    private func sectionView(_ section: DocLibrary.Section) -> some View {
        let key = "s:\(section.id)"
        let holdsSelection = selected.map(section.docs.contains) ?? false
        let open = holdsSelection || isOpen(key, default: false)
        return VStack(alignment: .leading, spacing: 1) {
            FoldHeader(open: open, count: section.docs.count) { toggle(key, open) } label: {
                HStack(spacing: 5) {
                    Image(systemName: section.images.count == section.docs.count ? "photo.on.rectangle" : "folder")
                        .font(.dante(size: 10.5))
                        .foregroundStyle(theme.text3.color)
                    Text(section.title)
                        .font(.dante(size: 12.5))
                        .foregroundStyle(theme.text2.color)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if open {
                contents(of: section).padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    private func contents(of section: DocLibrary.Section) -> some View {
        ForEach(section.others) { doc in
            // Under its folder's heading a doc only needs its folder when the heading has two of that name.
            let repeated = section.others.contains { $0 != doc && $0.title == doc.title }
            DocRow(doc: doc, folder: repeated ? library.folder(distinguishing: doc) : nil, isSelected: doc == selected) { session.showDoc(doc.path) }
                .docMenu(doc, session: session)
        }
        if !section.images.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 54, maximum: 72), spacing: 6)], spacing: 6) {
                ForEach(section.images) { doc in
                    Button { session.showDoc(doc.path) } label: {
                        DocThumbnail(url: root.appending(path: doc.path), side: 72)
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(doc == selected ? theme.accent.color : theme.line.color, lineWidth: doc == selected ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(doc.path)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: Folding

    private var folds: [String: Bool] {
        Dictionary(folding.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            return parts.count == 2 ? (String(parts[0]), parts[1] == "1") : nil
        }, uniquingKeysWith: { _, last in last })
    }

    private func isOpen(_ key: String, default open: Bool) -> Bool { folds[key] ?? open }

    private func toggle(_ key: String, _ open: Bool) {
        var folds = folds
        folds[key] = !open
        withAnimation(.snappy(duration: 0.2)) {
            folding = folds.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value ? 1 : 0)" }.joined(separator: "\n")
        }
    }
}

/// A group's or folder's heading: a chevron, the name and a count; a click folds it.
private struct FoldHeader<Label: View>: View {
    @Environment(\.theme) private var theme
    let open: Bool
    let count: Int
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.dante(size: 8.5, weight: .bold))
                    .foregroundStyle(theme.text3.color)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
                label
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.dante(size: 11, design: .monospaced))
                    .foregroundStyle(theme.text3.color)
                    .opacity(hovering || !open ? 1 : 0.6)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A row that isn't a doc, such as the library.
private struct SidebarRow: View {
    @Environment(\.theme) private var theme
    let title: String
    let symbol: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.dante(size: 11)).foregroundStyle(isSelected ? theme.accent.color : theme.text3.color).frame(width: 14)
                Text(title)
                    .font(.dante(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? theme.text.color : theme.text2.color)
                Spacer()
                Text("\(count)").font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? theme.accentTint.color : (hovering ? theme.raised.color : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DocRow: View {
    @Environment(\.theme) private var theme
    let doc: DocLibrary.Doc
    /// The folder, when another doc in the group has the same title.
    var folder: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if doc.kind != .markdown {
                    Image(systemName: symbol).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).frame(width: 13)
                }
                Text(doc.title)
                    .font(.dante(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? theme.text.color : theme.text2.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let folder {
                    Text(folder)
                        .font(.dante(size: 11.5))
                        .foregroundStyle(theme.text3.color)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? theme.accentTint.color : (hovering ? theme.raised.color : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(doc.path)
    }

    private var symbol: String {
        switch doc.kind {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .slides: "rectangle.on.rectangle"
        case .motion: "film.stack"
        case .diagram: "point.3.filled.connected.trianglepath.dotted"
        default: "doc.text"
        }
    }
}
