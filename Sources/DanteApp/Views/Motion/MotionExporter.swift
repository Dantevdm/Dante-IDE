import AppKit
import DanteEditor
import DanteKit

/// A piece taken out of Dante: one HTML file that plays in any browser (`MotionExport`), or a
/// PDF of a deck's slides or a film's storyboard. Both go in the piece's `renders/`.
@MainActor
enum MotionExporter {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The fonts every exported page carries.
    static let fonts = ["Geist.ttf", "Geist-Italic.ttf", "GeistMono.ttf"]

    /// Writes the piece as one HTML file. Returns it and what couldn't be carried.
    static func webPage(source: MotionSource, refused: @escaping (String) -> Bool) throws -> (file: URL, missing: [String]) {
        let folder = source.folder, root = source.projectRoot
        guard let html = try? String(contentsOf: folder.appending(path: source.piece.scene), encoding: .utf8) else {
            throw Failure(message: "\(source.piece.scene) is missing.")
        }
        let runtime = MotionRuntime.script(piece: source.piece, brand: source.brand, data: source.data, mode: .browser, pixelRatio: 2)
        let libraries = MotionSchemeHandler.libraries, fontFolder = DanteFonts.folder
        let result = MotionExport.page(scene: source.piece.scene, html: html, runtime: runtime, fonts: fonts) { key in
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let path = parts[1]
            let url: URL?
            switch parts[0] {
            case "piece": url = folder.appending(path: path)
            case "lib": url = libraries?.appending(path: path)
            case "fonts": url = fontFolder?.appending(path: path)
            case "project":
                let name = (path as NSString).lastPathComponent.lowercased()
                let allowed = MotionRuntime.servedExtensions.contains((path as NSString).pathExtension.lowercased()) && !name.hasPrefix(".env") && !refused(path)
                url = allowed ? root.appending(path: path) : nil
            default: url = nil
            }
            return url.flatMap { try? Data(contentsOf: $0) }
        }
        if let cycle = result.cycle {
            throw Failure(message: "The scene's modules import each other in a circle (\(cycle.joined(separator: " → "))), so they can't be carried in one page.")
        }
        let file = folder.appending(path: MotionExport.fileName(for: folder.path))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try result.html.write(to: file, atomically: true, encoding: .utf8)
        return (file, result.missing)
    }

    /// Writes a PDF: a deck's slides one to a page, anything else as a storyboard with what's
    /// said under each frame. `progress` gets 0…1.
    static func pdf(source: MotionSource, lengths: [Double], refused: @escaping (String) -> Bool, progress: (Double) -> Void) async throws -> URL {
        let piece = source.piece
        let pages = piece.handoutPages(lengths: lengths)
        let renderer = MotionRenderer(source: source, outputWidth: min(2400, piece.width * 2), refused: refused)
        defer { renderer.close() }
        try await renderer.load()
        let deck = piece.kind == .deck
        // Points: the slide at half its design size; a storyboard page adds a band for the words.
        let slide = CGSize(width: Double(piece.width) / 2, height: Double(piece.height) / 2)
        let band: CGFloat = deck ? 0 : 120
        var box = CGRect(origin: .zero, size: CGSize(width: slide.width, height: slide.height + band))
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: piece.title, kCGPDFContextCreator: "Dante"] as CFDictionary) else {
            throw Failure(message: "The PDF couldn't be started.")
        }
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            let image = try await renderer.frame(at: min(page.time, piece.duration))
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.06, alpha: 1))
            context.fill(box)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: band, width: slide.width, height: slide.height))
            if !deck {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                let time = MotionCritique.clock(page.time)
                (time as NSString).draw(at: CGPoint(x: 24, y: band - 30), withAttributes: [
                    .font: DanteFonts.mono(size: 12, weight: .medium), .foregroundColor: NSColor(white: 0.6, alpha: 1),
                ])
                let words = page.notes.joined(separator: " ")
                (words as NSString).draw(in: CGRect(x: 24, y: 12, width: slide.width - 48, height: band - 48), withAttributes: [
                    .font: DanteFonts.sans(size: 15, weight: .regular), .foregroundColor: NSColor(white: 0.92, alpha: 1),
                ])
                NSGraphicsContext.restoreGraphicsState()
            }
            context.endPDFPage()
            progress(Double(index + 1) / Double(pages.count))
        }
        context.closePDF()
        let file = source.folder.appending(path: "renders/\(source.folder.lastPathComponent)\(deck ? "" : "-storyboard").pdf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data as Data).write(to: file)
        return file
    }
}
