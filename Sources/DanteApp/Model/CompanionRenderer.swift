import AppKit
import DanteCore
import DanteKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Draws what a paired device opens (`CompanionPage`), at the device's size: the Mac does the
/// heavy lifting and the device gets a picture or a few blocks of text, never the file itself.
/// Works on recent projects as well as open ones, without opening a window.
@MainActor
enum CompanionRenderer {
    /// Each picture message stays well under the device's 4 MB limit once base64'd.
    nonisolated static let pictureBudget = 2_600_000

    // MARK: Library

    static func library(project: String, root: URL, files: [String]) async -> CompanionLibrary {
        let hasInfrastructure = await Task.detached { files.contains(where: Infrastructure.isCandidate) }.value
        let hasCode = files.contains { ![.plain, .markdown, .json, .yaml, .toml].contains(Language(url: URL(filePath: $0))) }
        return CompanionPages.library(project: project, files: files, hasSystem: hasCode, hasInfrastructure: hasInfrastructure)
    }

    // MARK: Pages

    static func page(_ request: CompanionPageRequest, root: URL, files: [String]) async -> CompanionPage {
        let title = title(of: request.path)
        guard let kind = CompanionPages.page(for: request.path, files: Set(files)) else {
            return CompanionPage(path: request.path, title: title, kind: .text, hash: "", problem: "That file can’t be opened from the phone.")
        }
        let rules = ClaudeRules.load(projectRoot: root)
        var file: URL?
        if !request.path.hasPrefix("dante:") {
            do { file = try ProjectFileOpen.resolve(request.path, root: root, rules: rules) } catch {
                return CompanionPage(path: request.path, title: title, kind: kind, hash: "", problem: error.localizedDescription)
            }
        }
        let extra = request.path.hasPrefix("dante:") ? await Task.detached { CompanionPages.fingerprint(of: files.filter(SystemMap.isReadable), root: root) }.value : ""
        let hash = CompanionPages.hash(of: request, file: file, extra: extra)
        if request.known == hash { return CompanionPage(path: request.path, title: title, kind: kind, hash: hash, unchanged: true) }
        var page = CompanionPage(path: request.path, title: title, kind: kind, hash: hash, page: request.page)
        switch kind {
        case .markdown:
            guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return failed(page, "Couldn’t read it.") }
            let (blocks, mermaid) = CompanionPages.blocks(String(text.prefix(CompanionPage.textLimit)), path: request.path)
            if let index = request.page {
                // One of its diagrams.
                guard mermaid.indices.contains(index) else { return failed(page, "That diagram isn’t in the file any more.") }
                page.kind = .diagram
                set(&page, picture(of: mermaidView(mermaid[index], dark: request.dark), request: request, zoomable: true))
            } else {
                page.blocks = blocks
            }
        case .image:
            guard let file else { return failed(page, "Couldn’t read it.") }
            set(&page, await Task.detached { scaledImage(file, pixels: request.pixelWidth) }.value)
        case .pdf:
            guard let file else { return failed(page, "Couldn’t read it.") }
            let result = await Task.detached { pdfPage(file, index: request.page ?? 0, pixels: request.pixelWidth) }.value
            page.pages = result.pages
            page.page = min(request.page ?? 0, max(0, result.pages - 1))
            set(&page, result.picture)
        case .diagram:
            let diagram: Diagram?
            if let file {
                diagram = (try? Data(contentsOf: file)).flatMap { try? Diagram.decode($0) }
            } else {
                let system = request.path == CompanionPage.Special.system
                let name = root.lastPathComponent
                diagram = await Task.detached { Diagram.fromProject(root, system: system, title: name) }.value
            }
            guard let diagram else { return failed(page, request.path.hasPrefix("dante:") ? "Nothing to draw yet." : "Couldn’t read the diagram.") }
            let theme = (request.dark ? ThemeID.dark : ThemeID.light).theme
            let still = DiagramStill(diagram: diagram, showsTitle: false).environment(\.theme, theme).environment(\.colorScheme, theme.colorScheme)
            set(&page, picture(of: still, request: request, zoomable: true))
        case .text:
            guard let file else { return failed(page, "Couldn’t read it.") }
            let text = await Task.detached { await plainText(file) }.value
            guard let text else { return failed(page, "Couldn’t turn it into text.") }
            page.text = String(text.prefix(CompanionPage.textLimit))
        }
        return page
    }

    private static func title(of path: String) -> String {
        switch path {
        case CompanionPage.Special.system: "System map"
        case CompanionPage.Special.infrastructure: "Infrastructure"
        default: DocLibrary.Doc(path: path).title
        }
    }

    private static func failed(_ page: CompanionPage, _ problem: String) -> CompanionPage {
        var page = page
        page.problem = problem
        return page
    }

    private static func set(_ page: inout CompanionPage, _ picture: Picture?) {
        guard let picture else {
            page.problem = "Couldn’t draw it."
            return
        }
        page.image = picture.data
        page.imageWidth = picture.width
        page.imageHeight = picture.height
    }

    struct Picture: Sendable {
        var data: Data
        var width: Int
        var height: Int
    }

    // MARK: Drawing

    private static func mermaidView(_ source: String, dark: Bool) -> some View {
        let theme = (dark ? ThemeID.dark : ThemeID.light).theme
        // Exported at its natural size (up to 2,400 points), so the device can zoom in.
        return MermaidBlock(source: source)
            .environment(\.isExporting, true)
            .environment(\.exportWidth, 2400)
            .environment(\.theme, theme)
            .environment(\.colorScheme, theme.colorScheme)
            .fixedSize()
    }

    /// A SwiftUI view as a JPEG. Diagrams are drawn at twice the device's width (for zooming),
    /// within the picture budget.
    private static func picture(of view: some View, request: CompanionPageRequest, zoomable: Bool) -> Picture? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let natural = renderer.cgImage, natural.width > 0 else { return nil }
        let wanted = Double(request.pixelWidth) * (zoomable ? 2 : 1)
        // At most about 16 million pixels, and never more than three times natural size.
        let byArea = (16_000_000 / Double(natural.width * natural.height)).squareRoot()
        renderer.scale = max(0.5, min(3, wanted / Double(natural.width), byArea))
        guard let image = renderer.cgImage else { return nil }
        return encode(image, opaque: true)
    }

    /// A JPEG (a PNG when it has transparency), shrunk until it fits the budget.
    nonisolated static func encode(_ image: CGImage, opaque: Bool) -> Picture? {
        let hasAlpha = !opaque && ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        var image = image
        for _ in 0..<4 {
            let data = NSMutableData()
            let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
            guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, hasAlpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if data.length <= pictureBudget { return Picture(data: data as Data, width: image.width, height: image.height) }
            guard let smaller = scaled(image, by: 0.75) else { return nil }
            image = smaller
        }
        return nil
    }

    nonisolated static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * factor)), height = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A picture file, no wider than the device shows it.
    nonisolated static func scaledImage(_ file: URL, pixels: Int) -> Picture? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else {
            // SVG and friends: let AppKit draw them.
            guard let image = NSImage(contentsOf: file), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return encode(cgImage, opaque: false)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? pixels
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? pixels
        let longest = Double(max(width, height)) * min(1, Double(pixels) / Double(max(1, width)))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(64, Int(longest))]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image, opaque: false)
    }

    nonisolated static func pdfPage(_ file: URL, index: Int, pixels: Int) -> (pages: Int, picture: Picture?) {
        guard let document = PDFDocument(url: file), document.pageCount > 0 else { return (0, nil) }
        let page = document.page(at: min(max(0, index), document.pageCount - 1))!
        let bounds = page.bounds(for: .mediaBox)
        let width = Double(pixels)
        let size = NSSize(width: width, height: width * bounds.height / max(1, bounds.width))
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (document.pageCount, nil) }
        return (document.pageCount, encode(cgImage, opaque: true))
    }

    /// Word, RTF, OpenDocument and HTML as plain text, through `textutil`.
    nonisolated static func plainText(_ file: URL) async -> String? {
        if ["txt", "text", "log", "csv"].contains(file.pathExtension.lowercased()) { return try? String(contentsOf: file, encoding: .utf8) }
        let result = await Shell.run(["textutil", "-convert", "txt", "-stdout", file.path], in: file.deletingLastPathComponent())
        return result.status == 0 ? result.stdout : nil
    }
}
