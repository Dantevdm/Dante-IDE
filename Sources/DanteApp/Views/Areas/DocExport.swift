import DanteEditor
import DanteKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Docs as PDF, set in the Paper theme on A4. Each block is rendered on its own so a page
/// break never cuts through a paragraph, list or diagram that fits on a page.
@MainActor
enum DocExport {
    static let page = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 54
    static let gap: CGFloat = 14

    static func pdf(_ document: MarkdownDocument, path: String, root: URL) -> Data? {
        let theme = Theme.paper
        let width = page.width - margin * 2
        let usable = page.height - margin * 2 - 18
        func renderer(_ blocks: [MarkdownDocument.Block]?, path showsPath: Bool) -> ImageRenderer<some View> {
            let view = DocumentBody(document: document, path: path, root: root, only: blocks ?? [], showsPath: showsPath)
                .frame(width: width, alignment: .leading)
                .environment(\.theme, theme)
                .environment(\.isExporting, true)
                .environment(\.exportWidth, width - 2)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            return renderer
        }
        let pieces = [renderer(nil, path: true)] + document.blocks.map { renderer([$0], path: false) }
        var heights: [CGFloat] = []
        for piece in pieces { piece.render { size, _ in heights.append(size.height) } }

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: (path as NSString).lastPathComponent] as CFDictionary)
        else { return nil }

        var pageNumber = -1
        func footer() {
            let label = "\((path as NSString).lastPathComponent) · \(pageNumber + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: theme.text3.nsColor]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            label.draw(at: CGPoint(x: margin, y: margin / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        func newPage() {
            if pageNumber >= 0 { footer(); context.endPDFPage() }
            pageNumber += 1
            context.beginPDFPage(nil)
            context.setFillColor(theme.ground.nsColor.cgColor)
            context.fill(CGRect(origin: .zero, size: page))
        }

        // A heading stays with the start of the block after it.
        let keepsWithNext = [false] + document.blocks.map { if case .heading = $0 { true } else { false } }
        newPage()
        for slice in PageLayout.slices(heights: heights, keepsWithNext: keepsWithNext, usable: usable, gap: gap) {
            while pageNumber < slice.page { newPage() }
            let height = heights[slice.block]
            pieces[slice.block].render { _, render in
                context.saveGState()
                let top = page.height - margin - slice.y
                context.clip(to: CGRect(x: margin - 4, y: top - slice.height, width: width + 8, height: slice.height))
                // The piece draws upwards from its bottom-left corner.
                context.translateBy(x: margin, y: top - height + slice.offset)
                render(context)
                context.restoreGState()
            }
        }
        footer()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
