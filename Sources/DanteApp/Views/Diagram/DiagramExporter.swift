import AppKit
import DanteKit
import SwiftUI
import UniformTypeIdentifiers

/// A diagram as a file to share: PNG and PDF drawn by the same views as the editor, SVG from
/// DanteKit with the icons drawn here, and Mermaid text.
@MainActor
enum DiagramExporter {
    enum Format: String, CaseIterable, Identifiable {
        case png = "PNG", pdf = "PDF", svg = "SVG", mermaid = "Mermaid"
        var id: String { rawValue }

        var type: UTType {
            switch self {
            case .png: .png
            case .pdf: .pdf
            case .svg: .svg
            case .mermaid: UTType(filenameExtension: "md") ?? .plainText
            }
        }

        var fileExtension: String { self == .mermaid ? "md" : rawValue.lowercased() }

        var note: String {
            switch self {
            case .png: "An image at twice the size, for slides and chat"
            case .pdf: "Sharp at any size, for documents and printing"
            case .svg: "For the web: the pulses and flowing links move in a browser"
            case .mermaid: "A Mermaid flowchart in a markdown file, laid out by Mermaid"
            }
        }
    }

    private static func still(_ diagram: Diagram, theme: Theme) -> some View {
        DiagramStill(diagram: diagram, showsTitle: false)
            .environment(\.theme, theme)
            .environment(\.colorScheme, theme.colorScheme)
    }

    static func png(_ diagram: Diagram, theme: Theme, scale: CGFloat = 2) -> Data? {
        let renderer = ImageRenderer(content: still(diagram, theme: theme))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func pdf(_ diagram: Diagram, theme: Theme) -> Data? {
        let renderer = ImageRenderer(content: still(diagram, theme: theme))
        let data = NSMutableData()
        var made = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            made = true
        }
        return made ? data as Data : nil
    }

    static func svg(_ diagram: Diagram, theme: Theme) -> String {
        var cache: [String: String] = [:]
        return DiagramSVG.render(diagram, theme: theme) { symbol, color, size in
            let key = "\(symbol)|\(color.css)|\(size)"
            if let known = cache[key] { return known }
            let url = symbolPNG(symbol, color: color, size: size)
            cache[key] = url
            return url
        }
    }

    /// An SF Symbol as a PNG data URL at three times its size, in one colour.
    static func symbolPNG(_ symbol: String, color: RGBA, size: CGFloat) -> String? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 3, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color.nsColor]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        let side = Int(size * 3)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        // Fitted inside the square, keeping the symbol's shape.
        let fit = min(CGFloat(side) / image.size.width, CGFloat(side) / image.size.height)
        let drawn = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        image.draw(in: CGRect(x: (CGFloat(side) - drawn.width) / 2, y: (CGFloat(side) - drawn.height) / 2, width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    static func mermaid(_ diagram: Diagram) -> String {
        "# \(diagram.title)\n\n" + (diagram.note.isEmpty ? "" : diagram.note + "\n\n") + "```mermaid\n" + diagram.mermaid() + "```\n"
    }

    static func data(_ format: Format, _ diagram: Diagram, theme: Theme) -> Data? {
        switch format {
        case .png: png(diagram, theme: theme)
        case .pdf: pdf(diagram, theme: theme)
        case .svg: Data(svg(diagram, theme: theme).utf8)
        case .mermaid: Data(mermaid(diagram).utf8)
        }
    }

    /// Asks where to save, next to the diagram by default, writes it and shows it in Finder.
    /// Returns an error to show, or nil.
    static func export(_ format: Format, _ diagram: Diagram, from url: URL, theme: Theme) -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        let base = url.lastPathComponent.lowercased().hasSuffix(Diagram.fileSuffix)
            ? String(url.lastPathComponent.dropLast(Diagram.fileSuffix.count)) : url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = base + "." + format.fileExtension
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = format.note
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        guard let data = data(format, diagram, theme: theme) else { return "Couldn’t draw the \(format.rawValue)." }
        do {
            try data.write(to: destination, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return nil
        } catch {
            return "Couldn’t save the \(format.rawValue): \(error.localizedDescription)"
        }
    }

    /// The picture on the clipboard, as PNG and PDF, for pasting into slides.
    static func copyImage(_ diagram: Diagram, theme: Theme) {
        let board = NSPasteboard.general
        board.clearContents()
        if let pdf = pdf(diagram, theme: theme) { board.setData(pdf, forType: .pdf) }
        if let png = png(diagram, theme: theme) { board.setData(png, forType: .png) }
    }
}
