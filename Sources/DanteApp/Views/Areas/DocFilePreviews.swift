import DanteEditor
import DanteKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// An image in a doc: a project file relative to the doc, or a web address.
struct DocImage: View {
    @Environment(\.theme) private var theme
    let alt: String
    let source: String
    let base: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let remote = URL(string: source), remote.scheme?.hasPrefix("http") == true {
                AsyncImage(url: remote) { image in
                    image.resizable().scaledToFit().frame(maxWidth: 700, alignment: .leading)
                } placeholder: {
                    placeholder("Loading \(remote.host() ?? "image")…")
                }
            } else if let image = NSImage(contentsOf: base.appending(path: source.removingPercentEncoding ?? source).standardizedFileURL) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: min(image.size.width, 700), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                placeholder("Missing image: \(source)")
            }
            if !alt.isEmpty {
                Text(alt).font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder(_ text: String) -> some View {
        Label(text, systemImage: "photo")
            .font(.dante(size: 12))
            .foregroundStyle(theme.text3.color)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line2.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

/// A PDF, image or Word file in Docs, shown as itself.
struct FilePreview: View {
    @Environment(\.theme) private var theme
    let url: URL
    let kind: DocLibrary.Doc.Kind
    @State private var text: String?

    var body: some View {
        Group {
            switch kind {
            case .pdf:
                PDFPreview(url: url)
            case .image:
                if let image = NSImage(contentsOf: url) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: min(image.size.width, 1100))
                            .padding(32)
                    }
                    .background(DotGrid(color: theme.line2.color, spacing: 16))
                } else {
                    EmptyState(symbol: "questionmark.square.dashed", title: "Can’t show this image", message: url.lastPathComponent) {
                        Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(DanteButtonStyle())
                    }
                        .padding(28)
                }
            case .document, .markdown:
                ScrollView {
                    Text(text ?? "Reading…")
                        .font(.dante(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(theme.text.color)
                        .textSelection(.enabled)
                        .padding(.horizontal, 44)
                        .padding(.vertical, 40)
                        .frame(maxWidth: 780, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .task(id: url) {
                    let output = await Shell.run(["textutil", "-convert", "txt", "-stdout", url.path], in: url.deletingLastPathComponent(), trimming: false)
                    text = output.status == 0 ? output.stdout : "macOS can’t convert this file to text. Open it, or ask Claude to read it."
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
