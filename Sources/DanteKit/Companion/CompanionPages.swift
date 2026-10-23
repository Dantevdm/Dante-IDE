import CryptoKit
import DanteCore
import Foundation

/// The Mac's side of exploring from a device (`CompanionLibrary`, `CompanionPage`), the parts
/// that don't draw: what's listed, which files a device may ask for, markdown read into blocks
/// with its figures, and the hash that tells a device its copy is still current.
public enum CompanionPages {
    /// Bumped when pages are drawn differently, so devices fetch them again.
    static let rendering = "1"

    /// The docs the Docs area lists, minus motion pieces and slides (a phone can't play or
    /// open them), plus the system map and the infrastructure when the project has them.
    public static func library(project: String, files: [String], hasSystem: Bool, hasInfrastructure: Bool) -> CompanionLibrary {
        var sections: [CompanionLibrary.Section] = []
        var overview: [CompanionLibrary.Entry] = []
        if hasSystem {
            overview.append(.init(path: CompanionPage.Special.system, title: "System map", kind: .diagram,
                                  detail: "Screens, routes, services and tables, from the code"))
        }
        if hasInfrastructure {
            overview.append(.init(path: CompanionPage.Special.infrastructure, title: "Infrastructure", kind: .diagram,
                                  detail: "What's deployed and the pipelines that ship it"))
        }
        if !overview.isEmpty { sections.append(.init(title: "How it works", entries: overview)) }
        for group in DocLibrary(paths: files).groups {
            let entries = group.docs.compactMap { doc -> CompanionLibrary.Entry? in
                guard let kind = kind(of: doc) else { return nil }
                let folder = (doc.path as NSString).deletingLastPathComponent
                return .init(path: doc.path, title: doc.title, kind: kind, detail: folder.isEmpty ? nil : folder)
            }
            if !entries.isEmpty { sections.append(.init(title: group.title, entries: entries)) }
        }
        return CompanionLibrary(project: project, sections: sections)
    }

    static func kind(of doc: DocLibrary.Doc) -> CompanionPage.Kind? {
        switch doc.kind {
        case .markdown: .markdown
        case .image: .image
        case .pdf: .pdf
        case .diagram: .diagram
        case .document, .html: .text
        case .slides, .motion: nil
        }
    }

    /// The kind of page for a path a device asks for: a library entry, or a picture a doc shows.
    /// Nil for anything else, so a device can't read the project's code or secrets.
    public static func page(for path: String, files: Set<String>) -> CompanionPage.Kind? {
        if path == CompanionPage.Special.system || path == CompanionPage.Special.infrastructure { return .diagram }
        guard files.contains(path), !isHidden(path) else { return nil }
        let doc = DocLibrary.Doc(path: path)
        if DocLibrary.isDoc(path), let kind = kind(of: doc) { return kind }
        // A picture anywhere in the project, for a README's screenshots.
        return doc.kind == .image ? .image : nil
    }

    /// Dot folders stay on the Mac, except `.dante`, where specs and notes live.
    static func isHidden(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { $0.hasPrefix(".") && $0 != ".dante" } || (path as NSString).lastPathComponent.hasPrefix(".env")
    }

    /// Markdown as blocks. ```mermaid blocks and pictures become figures: mermaid ones are
    /// numbered (`Figure.index`, returned in order as sources), pictures named by project path.
    /// Pictures on the web are left as their alt text: the device never fetches anything itself.
    public static func blocks(_ markdown: String, path: String) -> (blocks: [CompanionPage.Block], mermaid: [String]) {
        var blocks: [CompanionPage.Block] = []
        var mermaid: [String] = []
        for block in MarkdownDocument(markdown).blocks {
            switch block {
            case .heading(let level, let text, _):
                blocks.append(.heading(level: level, text: text))
            case .paragraph(let text):
                blocks.append(.paragraph(text))
            case .list(let items, let ordered):
                for item in items {
                    let marker = item.checked.map { $0 ? "☑" : "☐" } ?? (ordered ? "\(item.number ?? 1)." : "•")
                    blocks.append(.item(text: item.text, depth: item.depth, marker: marker))
                }
            case .quote(let text):
                blocks.append(.quote(text))
            case .code(let code, let language):
                if language?.lowercased() == "mermaid" {
                    blocks.append(.figure(.init(index: mermaid.count, caption: mermaidCaption(code))))
                    mermaid.append(code)
                } else {
                    blocks.append(.code(code, language: language))
                }
            case .table(let header, let rows):
                blocks.append(.table(header: header, rows: rows))
            case .rule:
                blocks.append(.rule)
            case .image(let alt, let source, _):
                if let resolved = resolve(source, from: path) {
                    blocks.append(.figure(.init(path: resolved, caption: alt)))
                } else if !alt.isEmpty {
                    blocks.append(.paragraph("*\(alt)*"))
                }
            }
        }
        return (blocks, mermaid)
    }

    static func mermaidCaption(_ source: String) -> String {
        let first = source.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if first.hasPrefix("sequencediagram") { return "Sequence diagram" }
        if first.hasPrefix("erdiagram") { return "Entity relationships" }
        return "Diagram"
    }

    /// `../images/map.png` from `docs/guide/intro.md` → `docs/images/map.png`. Nil for URLs
    /// and paths that leave the project.
    public static func resolve(_ source: String, from path: String) -> String? {
        let source = source.trimmingCharacters(in: .whitespaces).components(separatedBy: "#")[0].components(separatedBy: "?")[0]
        guard !source.isEmpty, !source.contains("://"), !source.hasPrefix("data:"), !source.hasPrefix("//") else { return nil }
        let decoded = source.removingPercentEncoding ?? source
        var parts = decoded.hasPrefix("/") ? [] : (path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(part))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// What a page was made from: the file's size and modification time (or the project's
    /// files, for the map), the size and look asked for, and how Dante draws. Cheap enough to
    /// work out on every request.
    public static func hash(of request: CompanionPageRequest, file: URL?, extra: String = "") -> String {
        var text = [rendering, request.path, request.page.map(String.init) ?? "-", "\(request.pixelWidth)", request.dark ? "d" : "l", extra].joined(separator: "|")
        if let file { text += "|" + stamp(file) }
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Size and modification time, read fresh (a URL caches its resource values).
    static func stamp(_ file: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(modified)"
    }

    /// The hash of a set of files, for pages drawn from the whole project.
    public static func fingerprint(of files: [String], root: URL) -> String {
        var text = ""
        for path in files.sorted() { text += path + ":" + stamp(root.appending(path: path)) + "\n" }
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
