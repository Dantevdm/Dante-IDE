import DanteEditor
import DanteKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct DocsSidebar: View {
    @Environment(\.theme) private var theme
    let session: Session
    let library: DocLibrary
    let selected: DocLibrary.Doc?
    let markdown: MarkdownDocument?
    let addFiles: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button(action: addFiles) {
                    Label("Add files…", systemImage: "plus")
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.text2.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy PDFs, images or documents into docs/. You can also drop them on Docs.")
                ForEach(library.groups) { group in
                    VStack(alignment: .leading, spacing: 1) {
                        Eyebrow(group.title).padding(.horizontal, 12).padding(.bottom, 5)
                        ForEach(group.docs) { doc in
                            DocRow(doc: doc, folder: library.folder(distinguishing: doc), isSelected: doc == selected) { session.showDoc(doc.path) }
                        }
                    }
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 8)
        }
        .background(theme.panel.color)
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
        default: "doc.text"
        }
    }
}
