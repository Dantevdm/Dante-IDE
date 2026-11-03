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
    /// From an HTML `<img width=…>`, in points; otherwise the image's own size, up to 700.
    var width: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let remote = URL(string: source), remote.scheme?.hasPrefix("http") == true {
                AsyncImage(url: remote) { image in
                    image.resizable().scaledToFit().frame(maxWidth: CGFloat(width ?? 700), alignment: .leading)
                } placeholder: {
                    placeholder("Loading \(remote.host() ?? "image")…")
                }
            } else if let image = NSImage(contentsOf: base.appending(path: source.removingPercentEncoding ?? source).standardizedFileURL) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: width.map { CGFloat($0) } ?? min(image.size.width, 700), alignment: .leading)
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

/// A PDF, image, Word file, slides or spreadsheet in Docs, shown as itself.
struct FilePreview: View {
    @Environment(\.theme) private var theme
    let url: URL
    let kind: DocLibrary.Doc.Kind
    var projectRoot: URL? = nil
    var rules = ClaudeRules()
    @State private var text: String?

    var body: some View {
        Group {
            switch kind {
            case .html:
                HTMLDocumentPreview(url: url, root: projectRoot ?? url.deletingLastPathComponent(), rules: rules)
                    .id(url)
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
            case .slides:
                QuickLookPreview(url: url)
            case .document, .markdown, .motion, .diagram:
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

/// A PDF in Docs: pages on the panel colour with gaps and shadows, at a readable width
/// rather than stretched across a wide pane, with the page count, zoom and find above.
struct PDFPreview: View {
    @Environment(\.theme) private var theme
    let url: URL
    @State private var pdf = PDFState()
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(pdf.pageCount == 0 ? "No pages" : "Page \(pdf.page) of \(pdf.pageCount)")
                    .font(.dante(size: 12).monospacedDigit())
                    .foregroundStyle(theme.text2.color)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                    TextField("Find in PDF", text: $query)
                        .textFieldStyle(.plain)
                        .font(.dante(size: 12))
                        .frame(width: 150)
                        .onSubmit { pdf.find(query) }
                    if let found = pdf.found {
                        Text(found).font(.dante(size: 11).monospacedDigit()).foregroundStyle(theme.text3.color)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.card.color))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color))
                IconButton(symbol: "minus.magnifyingglass", label: "Zoom out", size: 12) { pdf.zoom(by: 1 / 1.2) }
                Button { pdf.fit() } label: {
                    Text(pdf.fitting ? "Fit" : "\(Int((pdf.scale * 100).rounded()))%")
                        .font(.dante(size: 11.5, weight: .medium).monospacedDigit())
                        .frame(minWidth: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.text2.color)
                .help("Fit the page to the width")
                IconButton(symbol: "plus.magnifyingglass", label: "Zoom in", size: 12) { pdf.zoom(by: 1.2) }
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(theme.panel.color)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
            PDFKitView(url: url, background: theme.ground.nsColor, state: pdf)
        }
        .onChange(of: query) { pdf.found = nil }
    }
}

@MainActor
@Observable
final class PDFState {
    var page = 1
    var pageCount = 0
    var scale: CGFloat = 1
    /// Following the pane's width (up to `PDFState.widest`), until zoomed by hand.
    var fitting = true
    var found: String?
    @ObservationIgnored weak var view: PDFView?
    @ObservationIgnored private var matches: [PDFSelection] = []
    @ObservationIgnored private var matchIndex = 0
    @ObservationIgnored private var lastQuery = ""

    /// Pages wider than this on screen are harder to read, so fitting stops there.
    static let widest: CGFloat = 920

    func zoom(by factor: CGFloat) {
        guard let view else { return }
        fitting = false
        view.scaleFactor = min(5, max(0.2, view.scaleFactor * factor))
        scale = view.scaleFactor
    }

    func fit() {
        fitting = true
        refit()
    }

    func refit() {
        guard fitting, let view, let page = view.document?.page(at: 0) else { return }
        let width = page.bounds(for: view.displayBox).width
        guard width > 0 else { return }
        let room = min(view.bounds.width - 64, Self.widest)
        let new = max(0.2, room / width)
        // layout() calls this, and a new scale lays out again, so only real changes count.
        if abs(view.scaleFactor - new) > 0.002 { view.scaleFactor = new }
        if scale != view.scaleFactor { scale = view.scaleFactor }
    }

    func pageChanged() {
        guard let view, let document = view.document, let current = view.currentPage else { return }
        page = document.index(for: current) + 1
        pageCount = document.pageCount
    }

    /// Return finds the next match, wrapping round.
    func find(_ query: String) {
        guard let view, let document = view.document, !query.isEmpty else { return }
        if query != lastQuery {
            matches = document.findString(query, withOptions: [.caseInsensitive])
            matchIndex = 0
            lastQuery = query
        } else if !matches.isEmpty {
            matchIndex = (matchIndex + 1) % matches.count
        }
        guard !matches.isEmpty else { found = "None"; return }
        let match = matches[matchIndex]
        view.setCurrentSelection(match, animate: true)
        view.go(to: match)
        found = "\(matchIndex + 1) of \(matches.count)"
    }
}

private struct PDFKitView: NSViewRepresentable {
    let url: URL
    let background: NSColor
    let state: PDFState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = FittingPDFView()
        view.state = state
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 14, left: 24, bottom: 14, right: 24)
        view.pageShadowsEnabled = true
        view.backgroundColor = background
        state.view = view
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak state] _ in
            MainActor.assumeIsolated { state?.pageChanged() }
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        view.backgroundColor = background
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            state.fitting = true
            state.found = nil
            state.refit()
            state.pageChanged()
            if let first = view.document?.page(at: 0) { view.go(to: first) }
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    final class Coordinator {
        var observer: (any NSObjectProtocol)?
    }

    /// Refits as the pane changes width.
    private final class FittingPDFView: PDFView {
        weak var state: PDFState?
        override func layout() {
            super.layout()
            state?.refit()
        }
    }
}
