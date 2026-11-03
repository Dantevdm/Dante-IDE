import CryptoKit
import Foundation
import PDFKit

/// What Dante does to a PDF: organise pages (rotate, delete, insert, move), combine, extract
/// and split, comments with replies, safe saving and a recovery copy. The app's PDF view and
/// `dante pdf` (for scripts and agents) both use these, so they behave the same.
///
/// Pages move between documents as `PDFPage`s, which carry their annotations (links, form
/// fields, comments) with them.
public enum PDFTools {
    public enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case locked(String)
        case notAllowed(String)
        case badRange(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): "\(name) isn't a PDF Dante can read."
            case .locked(let name): "\(name) needs its password."
            case .notAllowed(let what): "The PDF's author doesn't allow \(what)."
            case .badRange(let text): text
            case .writeFailed(let name): "Couldn't write \(name)."
            }
        }
    }

    // MARK: Page ranges (pure)

    /// "1-3, 5, 8-" (1-based, inclusive; "8-" runs to the end, "-3" from the start, "all" or
    /// "" every page; "last" is the last page) → zero-based indexes in the order written,
    /// repeats dropped.
    public static func pages(_ text: String, count: Int) throws -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty || trimmed == "all" { return Array(0..<count) }
        var result: [Int] = []
        func number(_ part: Substring, default value: Int) throws -> Int {
            let part = part.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { return value }
            if part == "last" { return count }
            guard let n = Int(part) else { throw Failure.badRange("“\(part)” isn't a page number.") }
            guard n >= 1, n <= count else { throw Failure.badRange("There's no page \(n); the PDF has \(count).") }
            return n
        }
        for piece in trimmed.split(separator: ",") {
            if let dash = piece.firstIndex(of: "-") {
                let start = try number(piece[..<dash], default: 1)
                let end = try number(piece[piece.index(after: dash)...], default: count)
                let span = start <= end ? Array(start...end) : Array((end...start).reversed())
                result += span.map { $0 - 1 }
            } else {
                result.append(try number(piece, default: 1) - 1)
            }
        }
        var seen = Set<Int>()
        return result.filter { seen.insert($0).inserted }
    }

    /// Where a document is cut to split it: every `n` pages → the first page of each part.
    public static func splitPoints(every n: Int, count: Int) -> [Int] {
        guard n > 0, count > 0 else { return [0] }
        return Array(stride(from: 0, to: count, by: n))
    }

    /// The page ranges between cut points (each the first page of a part, zero-based).
    public static func parts(cuttingAt starts: [Int], count: Int) -> [Range<Int>] {
        let starts = Array(Set(starts.filter { $0 > 0 && $0 < count } + [0])).sorted()
        return starts.enumerated().map { index, start in
            start..<(index + 1 < starts.count ? starts[index + 1] : count)
        }
    }

    // MARK: Reading

    public static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable(url.lastPathComponent) }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else { throw Failure.locked(url.lastPathComponent) }
        }
        return document
    }

    public struct Info: Equatable, Sendable {
        public var pages: Int
        public var title: String?
        public var author: String?
        public var encrypted: Bool
        public var canChange: Bool
        public var canCopy: Bool
        public var canPrint: Bool
        public var canComment: Bool
        public var bookmarks: Int
        public var comments: Int
        public var formFields: Int
        public var links: Int

        public var summary: String {
            var lines = ["\(pages) \(pages == 1 ? "page" : "pages")"]
            if let title { lines.append("Title: \(title)") }
            if let author { lines.append("Author: \(author)") }
            if encrypted {
                let denied = [canChange ? nil : "changes", canCopy ? nil : "copying", canPrint ? nil : "printing", canComment ? nil : "comments"].compactMap { $0 }
                lines.append("Encrypted" + (denied.isEmpty ? "" : "; the author doesn't allow " + denied.joined(separator: ", ")))
            }
            lines.append("\(bookmarks) bookmarks, \(comments) comments, \(formFields) form fields, \(links) links")
            return lines.joined(separator: "\n")
        }
    }

    public static func info(_ document: PDFDocument) -> Info {
        let attributes = document.documentAttributes ?? [:]
        var comments = 0, fields = 0, links = 0
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                switch annotation.type {
                case "Widget": fields += 1
                case "Link": links += 1
                case "Text", "Highlight", "FreeText", "Underline", "StrikeOut", "Square", "Circle", "Ink": comments += 1
                default: break
                }
            }
        }
        return Info(pages: document.pageCount,
                    title: (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.nilIfBlank,
                    author: (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.nilIfBlank,
                    encrypted: document.isEncrypted,
                    canChange: document.allowsDocumentChanges,
                    canCopy: document.allowsCopying,
                    canPrint: document.allowsPrinting,
                    canComment: document.allowsCommenting,
                    bookmarks: outlineCount(document.outlineRoot) - (document.outlineRoot == nil ? 0 : 1),
                    comments: comments, formFields: fields, links: links)
    }

    private static func outlineCount(_ outline: PDFOutline?) -> Int {
        guard let outline else { return 0 }
        return 1 + (0..<outline.numberOfChildren).map { outlineCount(outline.child(at: $0)) }.reduce(0, +)
    }

    /// The text of some pages, each under a `--- Page N ---` line.
    public static func text(_ document: PDFDocument, pages: [Int]) -> String {
        pages.compactMap { index in
            document.page(at: index).map { "--- Page \(index + 1) ---\n" + ($0.string ?? "") }
        }.joined(separator: "\n\n")
    }

    // MARK: Organising

    public static func rotate(_ document: PDFDocument, pages: [Int], by degrees: Int) {
        for index in pages {
            guard let page = document.page(at: index) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
    }

    /// Removes pages, returning them with where they were, for undo.
    @discardableResult
    public static func delete(_ document: PDFDocument, pages: [Int]) -> [(index: Int, page: PDFPage)] {
        let removed = pages.sorted().compactMap { index in document.page(at: index).map { (index, $0) } }
        for (index, _) in removed.reversed() { document.removePage(at: index) }
        return removed
    }

    /// Puts pages back where `delete` took them from.
    public static func restore(_ removed: [(index: Int, page: PDFPage)], into document: PDFDocument) {
        for (index, page) in removed.sorted(by: { $0.index < $1.index }) {
            document.insert(page, at: min(index, document.pageCount))
        }
    }

    /// Moves pages (in their order) to stand before the page now at `destination`
    /// (`pageCount` for the end). Returns the new indexes of the moved pages.
    @discardableResult
    public static func move(_ document: PDFDocument, pages: [Int], to destination: Int) -> [Int] {
        let order = reordered(count: document.pageCount, moving: pages, to: destination)
        let current = (0..<document.pageCount).compactMap { document.page(at: $0) }
        guard current.count == order.count else { return pages }
        for index in (0..<document.pageCount).reversed() { document.removePage(at: index) }
        for (position, old) in order.enumerated() { document.insert(current[old], at: position) }
        let moved = Set(pages)
        return order.enumerated().filter { moved.contains($0.element) }.map(\.offset)
    }

    /// The page order after moving `pages` before `destination` (pure): old index per new place.
    public static func reordered(count: Int, moving pages: [Int], to destination: Int) -> [Int] {
        let moving = pages.filter { $0 >= 0 && $0 < count }
        let set = Set(moving)
        let rest = (0..<count).filter { !set.contains($0) }
        let before = (0..<min(max(0, destination), count)).filter { !set.contains($0) }.count
        return Array(rest[..<before]) + moving + Array(rest[before...])
    }

    /// A blank page the size of `like` (or A4), at `index`.
    public static func insertBlank(_ document: PDFDocument, at index: Int, like: PDFPage? = nil) {
        let size = like?.bounds(for: .mediaBox).size ?? CGSize(width: 595, height: 842)
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        document.insert(page, at: min(max(0, index), document.pageCount))
    }

    /// Copies pages of another document in at `index`; returns how many.
    @discardableResult
    public static func insert(_ other: PDFDocument, pages: [Int]? = nil, into document: PDFDocument, at index: Int) -> Int {
        let chosen = pages ?? Array(0..<other.pageCount)
        var at = min(max(0, index), document.pageCount)
        for page in chosen.compactMap({ other.page(at: $0)?.copy() as? PDFPage }) {
            document.insert(page, at: at)
            at += 1
        }
        return chosen.count
    }

    // MARK: Combining and splitting

    /// One document from several, in order, with every one's bookmarks pointing at its pages
    /// in the result (the pages are copies, so the old bookmarks would point elsewhere).
    public static func combine(_ documents: [PDFDocument]) -> PDFDocument {
        let result = PDFDocument()
        let root = PDFOutline()
        for document in documents {
            let offset = result.pageCount
            insert(document, into: result, at: offset)
            guard let outline = document.outlineRoot else { continue }
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index),
                      let copy = copied(child, from: document, into: result, offset: offset) else { continue }
                root.insertChild(copy, at: root.numberOfChildren)
            }
        }
        if root.numberOfChildren > 0 { result.outlineRoot = root }
        return result
    }

    /// A bookmark and its children, aimed at the same places among pages copied in at `offset`.
    private static func copied(_ item: PDFOutline, from source: PDFDocument, into result: PDFDocument, offset: Int) -> PDFOutline? {
        let copy = PDFOutline()
        copy.label = item.label
        copy.isOpen = item.isOpen
        if let destination = item.destination, let page = destination.page,
           let target = result.page(at: offset + source.index(for: page)) {
            copy.destination = PDFDestination(page: target, at: destination.point)
        }
        for index in 0..<item.numberOfChildren {
            if let child = item.child(at: index), let inner = copied(child, from: source, into: result, offset: offset) {
                copy.insertChild(inner, at: copy.numberOfChildren)
            }
        }
        return copy
    }

    public static func extract(_ document: PDFDocument, pages: [Int]) -> PDFDocument {
        let result = PDFDocument()
        insert(document, pages: pages, into: result, at: 0)
        return result
    }

    public static func split(_ document: PDFDocument, cuttingAt starts: [Int]) -> [PDFDocument] {
        parts(cuttingAt: starts, count: document.pageCount).map { extract(document, pages: Array($0)) }
    }

    /// "report.pdf" split in three → report-1.pdf, report-2.pdf, report-3.pdf beside `base`.
    public static func partURLs(for base: URL, count: Int, in folder: URL? = nil) -> [URL] {
        let folder = folder ?? base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        let width = String(count).count
        return (1...max(1, count)).map { n in
            folder.appending(path: "\(stem)-\(String(repeating: "0", count: max(0, width - String(n).count)))\(n).pdf")
        }
    }

    // MARK: Saving

    /// Writes the whole document to a file beside the target and swaps it in, so a crash or a
    /// full disk never leaves half a PDF. A password protects it (opening needs it; the owner
    /// password, when given, guards changes, copying and printing).
    public static func save(_ document: PDFDocument, to url: URL, password: String? = nil, ownerPassword: String? = nil) throws {
        var options: [PDFDocumentWriteOption: Any] = [:]
        if let password, !password.isEmpty {
            options[.userPasswordOption] = password
            options[.ownerPasswordOption] = ownerPassword?.nilIfBlank ?? password
        }
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appending(path: ".\(url.deletingPathExtension().lastPathComponent).\(UUID().uuidString.prefix(8)).pdf")
        guard document.write(to: temporary, withOptions: options) else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.writeFailed(url.lastPathComponent)
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.writeFailed(url.lastPathComponent)
        }
    }
}

// MARK: Comments

extension PDFTools {
    /// A comment and its replies: a note, highlight or other markup, and the notes that answer
    /// it. PDFKit won't write `/IRT` (in reply to) or `/NM`, so Dante writes a reply as a hidden
    /// note at its comment's corner and reads either that or another reader's `/IRT` back.
    public struct Thread: Identifiable {
        public var root: PDFAnnotation
        public var replies: [PDFAnnotation]
        public var page: Int
        /// The words a highlight covers, for a comment on a passage.
        public var quote: String?
        public var id: ObjectIdentifier { ObjectIdentifier(root) }

        public var author: String { root.userName?.nilIfBlank ?? "Someone" }
        public var text: String { root.contents ?? "" }
        public var date: Date? { root.modificationDate }
    }

    static let replyKey = PDFAnnotationKey(rawValue: "/IRT")

    static let commentTypes: Set<String> = ["Text", "Highlight", "FreeText", "Underline", "StrikeOut", "Square", "Circle", "Ink"]

    public static func threads(in document: PDFDocument) -> [Thread] {
        var threads: [Thread] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let annotations = page.annotations.filter { commentTypes.contains($0.type ?? "") }
            let replies = annotations.filter(isReply)
            let roots = annotations.filter { !isReply($0) }
            for root in roots {
                // A passage's later lines are highlights without a note, made with its first.
                if (root.contents ?? "").isEmpty, root.type == "Highlight", roots.contains(where: {
                    $0 !== root && $0.type == "Highlight" && !($0.contents ?? "").isEmpty
                        && $0.userName == root.userName && $0.modificationDate == root.modificationDate
                }) { continue }
                let answers = replies.filter { parent(of: $0, among: roots) === root }
                    .sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
                guard !(root.contents ?? "").isEmpty || !answers.isEmpty || root.type != "Text" else { continue }
                let quote = root.type == "Highlight" ? passage(of: root, on: page) : nil
                threads.append(Thread(root: root, replies: answers, page: index, quote: quote))
            }
        }
        return threads
    }

    /// The text a highlight (and the lines made with it) covers.
    static func passage(of root: PDFAnnotation, on page: PDFPage) -> String? {
        let lines = page.annotations.filter {
            $0.type == "Highlight" && $0.userName == root.userName && $0.modificationDate == root.modificationDate
        }
        let text = (lines.isEmpty ? [root] : lines)
            .sorted { $0.bounds.maxY > $1.bounds.maxY }
            .compactMap { page.selection(for: $0.bounds.insetBy(dx: 0, dy: $0.bounds.height * 0.2))?.string?.nilIfBlank }
            .joined(separator: " ")
        return text.nilIfBlank
    }

    static func isReply(_ annotation: PDFAnnotation) -> Bool {
        annotation.value(forAnnotationKey: replyKey) is PDFAnnotation || (annotation.type == "Text" && !annotation.shouldDisplay)
    }

    static func parent(of reply: PDFAnnotation, among roots: [PDFAnnotation]) -> PDFAnnotation? {
        if let parent = reply.value(forAnnotationKey: replyKey) as? PDFAnnotation {
            return roots.first { $0 === parent } ?? roots.first { $0.bounds == parent.bounds }
        }
        let corner = reply.bounds.origin
        return roots.min { distance($0.bounds.origin, corner) < distance($1.bounds.origin, corner) }
            .flatMap { distance($0.bounds.origin, corner) < 1 ? $0 : nil }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// A note on a page (a sticky note at `point`), or on a passage (highlights over each line).
    @discardableResult
    public static func comment(_ text: String, by author: String, on page: PDFPage, at point: CGPoint? = nil,
                               passage: PDFSelection? = nil) -> [PDFAnnotation] {
        var added: [PDFAnnotation] = []
        let now = Date()
        if let passage {
            for line in passage.selectionsByLine() {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0 else { continue }
                let highlight = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                highlight.color = NSColor.systemYellow.withAlphaComponent(0.45)
                highlight.userName = author
                highlight.modificationDate = now
                if added.isEmpty { highlight.contents = text }
                page.addAnnotation(highlight)
                added.append(highlight)
            }
        }
        if added.isEmpty {
            let spot = point ?? CGPoint(x: page.bounds(for: .mediaBox).maxX - 40, y: page.bounds(for: .mediaBox).maxY - 40)
            let note = PDFAnnotation(bounds: CGRect(x: spot.x - 12, y: spot.y - 12, width: 24, height: 24), forType: .text, withProperties: nil)
            note.contents = text
            note.userName = author
            note.modificationDate = Date()
            note.color = NSColor.systemYellow
            page.addAnnotation(note)
            added.append(note)
        }
        return added
    }

    /// A reply under a comment: a hidden note at the comment's corner.
    @discardableResult
    public static func reply(_ text: String, by author: String, to root: PDFAnnotation) -> PDFAnnotation? {
        guard let page = root.page else { return nil }
        // 24 points square, the size PDFKit gives every note on saving, so the corner stays put.
        let reply = PDFAnnotation(bounds: CGRect(origin: root.bounds.origin, size: CGSize(width: 24, height: 24)), forType: .text, withProperties: nil)
        reply.contents = text
        reply.userName = author
        reply.modificationDate = Date()
        reply.shouldDisplay = false
        page.addAnnotation(reply)
        return reply
    }

    /// Removes a thread: the comment, its replies and the other lines of its passage. Returns
    /// what it took, for undo.
    @discardableResult
    public static func remove(_ thread: Thread) -> [(annotation: PDFAnnotation, page: PDFPage)] {
        guard let page = thread.root.page else { return [] }
        let lines = thread.root.type == "Highlight" ? page.annotations.filter {
            $0 !== thread.root && $0.type == "Highlight" && ($0.contents ?? "").isEmpty
                && $0.userName == thread.root.userName && $0.modificationDate == thread.root.modificationDate
        } : []
        let taken = ([thread.root] + lines + thread.replies).map { ($0, page) }
        for (annotation, page) in taken { page.removeAnnotation(annotation) }
        return taken
    }
}

// MARK: Recovery

/// A copy of a PDF with unsaved changes, kept per Mac in Application Support so a crash or a
/// quit doesn't lose them; offered back the next time the file opens.
public enum PDFRecovery {
    public static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Dante/pdf-recovery")
    }

    public static func url(for file: URL, in folder: URL = folder) -> URL {
        let digest = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8))
        return folder.appending(path: digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".pdf")
    }

    public static func keep(_ document: PDFDocument, for file: URL, in folder: URL = folder) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        document.write(to: url(for: file, in: folder))
    }

    /// The recovery copy, when it's newer than the file itself.
    public static func pending(for file: URL, in folder: URL = folder) -> URL? {
        let copy = url(for: file, in: folder)
        guard let copied = modified(copy) else { return nil }
        guard let saved = modified(file) else { return copy }
        return copied > saved ? copy : nil
    }

    public static func discard(for file: URL, in folder: URL = folder) {
        try? FileManager.default.removeItem(at: url(for: file, in: folder))
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
