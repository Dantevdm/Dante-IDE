import SwiftUI
import UIKit

/// Every project the Mac knows, open ones first, each opening into its library.
struct ExploreProjects: View {
    let explorer: Explorer

    var body: some View {
        List {
            let projects = explorer.projects
            if projects.isEmpty {
                Text("Connect to your Mac to see its projects.").foregroundStyle(Palette.text3)
            }
            ForEach(projects, id: \.id) { project in
                NavigationLink {
                    LibraryView(explorer: explorer, project: project.id, name: project.name)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name).foregroundStyle(Palette.text)
                            Text(project.isOpen ? "Open on the Mac" : "Recent").font(.caption).foregroundStyle(Palette.text3)
                        }
                    } icon: {
                        Image(systemName: project.isOpen ? "folder.fill" : "folder").foregroundStyle(Palette.accent)
                    }
                }
            }
        }
        .navigationTitle("Explore")
    }
}

/// A project's docs, pictures and diagrams, with how it works first.
struct LibraryView: View {
    let explorer: Explorer
    let project: String
    let name: String
    /// On the iPad the reader sits beside the list rather than pushing.
    var selection: Binding<CompanionLibrary.Entry?>?
    @State private var filter = ""

    var body: some View {
        Group {
            switch explorer.listing(of: project) {
            case .loading:
                ProgressView("Asking the Mac…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn’t list \(name)", systemImage: "wifi.exclamationmark")
                } description: { Text(message) } actions: {
                    Button("Try Again") { Task { await explorer.loadLibrary(project) } }
                }
            case .loaded(let library):
                if library.isEmpty {
                    ContentUnavailableView("Nothing to read yet", systemImage: "doc.text",
                                           description: Text("\(name) has no docs, pictures or diagrams Dante can show."))
                } else {
                    list(library)
                }
            }
        }
        .navigationTitle(name)
        .task(id: project) { await explorer.loadLibrary(project) }
        .refreshable { await explorer.loadLibrary(project) }
    }

    private func list(_ library: CompanionLibrary) -> some View {
        List {
            ForEach(library.sections) { section in
                let entries = section.entries.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.path.localizedCaseInsensitiveContains(filter) }
                if !entries.isEmpty {
                    Section(section.title) {
                        ForEach(entries) { entry in
                            if let selection {
                                Button { selection.wrappedValue = entry } label: { EntryRow(entry: entry) }
                                    .listRowBackground(selection.wrappedValue == entry ? Palette.accentTint : nil)
                            } else {
                                NavigationLink { PageView(explorer: explorer, project: project, entry: entry) } label: { EntryRow(entry: entry) }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter")
    }
}

struct EntryRow: View {
    let entry: CompanionLibrary.Entry

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).foregroundStyle(Palette.text).lineLimit(2)
                if let detail = entry.detail { Text(detail).font(.caption).foregroundStyle(Palette.text3).lineLimit(1) }
            }
        } icon: {
            Image(systemName: entry.kind.symbol).foregroundStyle(Palette.accent)
        }
    }
}

extension CompanionPage.Kind {
    var symbol: String {
        switch self {
        case .markdown: "doc.richtext"
        case .image: "photo"
        case .pdf: "doc.text.image"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .text: "doc.plaintext"
        }
    }
}

/// One page, drawn by the Mac for this screen's width.
struct PageView: View {
    let explorer: Explorer
    let project: String
    let entry: CompanionLibrary.Entry
    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var scheme
    @State private var page: CompanionPage?
    @State private var problem: String?
    @State private var pdfPage = 0
    @State private var asked = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(200, Int(geometry.size.width / 10) * 10)
            content(width: width)
                .task(id: "\(entry.path)|\(width)|\(scheme == .dark)|\(pdfPage)") { await load(width: width) }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Explain", systemImage: "sparkles") {
                    explorer.connection.ask("Explain \(entry.title) (\(entry.path.hasPrefix("dante:") ? "Dante’s \(entry.title.lowercased())" : entry.path)) for me: what it shows and how that part of the system works. Keep it short; I’m reading on my phone.",
                                            project: project, spoken: false)
                    asked = true
                }
            }
        }
        .alert("Asked \(explorer.connection.snapshot?.projects.first { $0.id == project }?.lead ?? "the agent")", isPresented: $asked) {
            Button("OK") {}
        } message: {
            Text("The answer appears on Home, and on the Mac.")
        }
    }

    @ViewBuilder
    private func content(width: Int) -> some View {
        if let page, page.problem == nil {
            switch page.kind {
            case .markdown:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array((page.blocks ?? []).enumerated()), id: \.offset) { _, block in
                            BlockView(block: block, explorer: explorer, project: project, docPath: entry.path, width: width - 32)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            case .text:
                ScrollView {
                    Text(page.text ?? "").font(.body).foregroundStyle(Palette.text).textSelection(.enabled)
                        .padding(16).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                }
            case .image, .diagram:
                ZoomableImage(data: page.image)
            case .pdf:
                VStack(spacing: 0) {
                    ZoomableImage(data: page.image)
                    if let pages = page.pages, pages > 1 {
                        HStack {
                            Button("Previous", systemImage: "chevron.left") { pdfPage = max(0, pdfPage - 1) }.disabled(pdfPage == 0)
                            Spacer()
                            Text("Page \((page.page ?? 0) + 1) of \(pages)").font(.subheadline).foregroundStyle(Palette.text2)
                            Spacer()
                            Button("Next", systemImage: "chevron.right") { pdfPage = min(pages - 1, pdfPage + 1) }.disabled(pdfPage >= pages - 1)
                        }
                        .labelStyle(.iconOnly)
                        .padding(12)
                        .background(Palette.card)
                    }
                }
            }
        } else if let message = page?.problem ?? problem {
            ContentUnavailableView {
                Label("Can’t show this", systemImage: "exclamationmark.triangle")
            } description: { Text(message) } actions: {
                Button("Try Again") { Task { await load(width: width) } }
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(entry.path.hasPrefix("dante:") ? "The Mac is drawing it from the code…" : "The Mac is drawing it…")
                    .font(.subheadline).foregroundStyle(Palette.text3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load(width: Int) async {
        problem = nil
        let request = CompanionPageRequest(path: entry.path, page: entry.kind == .pdf ? pdfPage : nil, width: width, scale: scale, dark: scheme == .dark)
        problem = await explorer.fetch(request, project: project) { page = $0 }
    }
}

/// A markdown block. Figures are fetched as they scroll into view.
private struct BlockView: View {
    let block: CompanionPage.Block
    let explorer: Explorer
    let project: String
    let docPath: String
    let width: Int

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : level == 3 ? .title3.weight(.semibold) : .headline)
                .foregroundStyle(Palette.text).padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            inline(text).foregroundStyle(Palette.text)
        case .item(let text, let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(Palette.text3).monospacedDigit()
                inline(text).foregroundStyle(Palette.text)
            }
            .padding(.leading, CGFloat(depth) * 18)
        case .quote(let text):
            inline(text).foregroundStyle(Palette.text2).padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Palette.accent.opacity(0.5)).frame(width: 3) }
        case .code(let code, _):
            ScrollView(.horizontal) {
                Text(code).font(.system(.footnote, design: .monospaced)).foregroundStyle(Palette.text).padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { inline($0.element).font(.subheadline.weight(.semibold)) } }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { inline($0.element).font(.subheadline) } }
                    }
                }
                .foregroundStyle(Palette.text)
                .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
        case .rule:
            Divider()
        case .figure(let figure):
            FigureView(figure: figure, explorer: explorer, project: project, docPath: docPath, width: width)
        }
    }

    private func inline(_ markdown: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown))
    }
}

/// A diagram or picture inside a doc: tap to open it full screen and zoom.
private struct FigureView: View {
    let figure: CompanionPage.Figure
    let explorer: Explorer
    let project: String
    let docPath: String
    let width: Int
    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var scheme
    @State private var page: CompanionPage?
    @State private var problem: String?
    @State private var full = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image = page?.image.flatMap(UIImage.init(data:)) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .onTapGesture { full = true }
                } else if let message = page?.problem ?? problem {
                    Label(message, systemImage: "photo").font(.footnote).foregroundStyle(Palette.text3).padding(12)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // A diagram's picture carries its own label; a picture's alt text is its caption.
            if figure.index == nil, !figure.caption.isEmpty { Text(figure.caption).font(.caption).foregroundStyle(Palette.text3) }
        }
        .task(id: "\(width)|\(scheme == .dark)") {
            let request = CompanionPageRequest(path: figure.path ?? docPath, page: figure.index, width: width, scale: scale, dark: scheme == .dark)
            problem = await explorer.fetch(request, project: project) { page = $0 }
        }
        .fullScreenCover(isPresented: $full) {
            NavigationStack {
                ZoomableImage(data: page?.image)
                    .background(Palette.background.ignoresSafeArea())
                    .navigationTitle(figure.caption.isEmpty ? "Figure" : figure.caption)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { full = false } } }
            }
        }
    }
}

/// A picture that fits the screen and zooms with a pinch or a double tap.
struct ZoomableImage: UIViewRepresentable {
    let data: Data?

    func makeUIView(context: Context) -> ZoomView { ZoomView() }

    func updateUIView(_ view: ZoomView, context: Context) {
        view.show(data)
    }

    final class ZoomView: UIScrollView, UIScrollViewDelegate {
        private let imageView = UIImageView()
        private var shown: Data?

        init() {
            super.init(frame: .zero)
            delegate = self
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            decelerationRate = .fast
            contentInsetAdjustmentBehavior = .never
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }

        required init?(coder: NSCoder) { fatalError() }

        func show(_ data: Data?) {
            guard data != shown else { return }
            shown = data
            imageView.image = data.flatMap(UIImage.init(data:))
            zoomScale = 1
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let image = imageView.image, bounds.width > 0, zoomScale == minimumZoomScale || imageView.frame.isEmpty else { return center() }
            // Fit the picture to the view at zoom 1, then allow zooming in to its own pixels and a little past.
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(x: 0, y: 0, width: image.size.width * fit, height: image.size.height * fit)
            contentSize = imageView.frame.size
            minimumZoomScale = 1
            maximumZoomScale = max(3, 1 / fit * image.scale * 1.5)
            center()
        }

        private func center() {
            let x = max(0, (bounds.width - contentSize.width) / 2), y = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

        @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
            if zoomScale > minimumZoomScale {
                setZoomScale(minimumZoomScale, animated: true)
            } else {
                let point = tap.location(in: imageView)
                let scale = min(maximumZoomScale, 3)
                let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
                zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
