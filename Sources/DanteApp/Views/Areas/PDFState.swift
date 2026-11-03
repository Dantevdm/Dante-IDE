import AppKit
import DanteKit
import PDFKit
import SwiftUI

/// One open PDF in the workbench: the document, the view's place and zoom, search, the
/// sidebar's page selection, comments, and every change with its undo. Changes are kept in a
/// recovery copy until saved, and saved in place without ever leaving half a file.
@MainActor
@Observable
final class PDFState {
    // Where the reader is
    var page = 1
    var pageCount = 0
    var scale: CGFloat = 1
    /// Following the pane's width (up to `widest`), until zoomed by hand.
    var fitting = true
    var twoUp = false { didSet { applyLayout() } }
    var darkReading = false { didSet { applyLayout() } }

    // Search, as you type
    var query = ""
    var found: String?
    @ObservationIgnored private var matches: [PDFSelection] = []
    @ObservationIgnored private var matchIndex = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    // The document
    private(set) var document: PDFDocument?
    private(set) var url: URL?
    var locked = false
    var unlockFailed = false
    /// The password it was opened with, so saving keeps it protected.
    @ObservationIgnored private var password: String?
    var dirty = false
    var lastSaved: Date?
    var problem: String?
    var recovery: URL?
    /// Bumped on every change, for thumbnails and the comments list.
    var revision = 0
    var selected: Set<Int> = []
    @ObservationIgnored private var anchor: Int?
    var threads: [PDFTools.Thread] = []
    var author = NSFullUserName()

    @ObservationIgnored weak var view: PDFView?
    @ObservationIgnored let undo = UndoManager()
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnails: [String: NSImage] = [:]

    /// Pages wider than this on screen are harder to read, so fitting stops there.
    static let widest: CGFloat = 920

    var canChange: Bool { document?.allowsDocumentChanges ?? false }
    var canComment: Bool { document.map { $0.allowsCommenting || $0.allowsDocumentChanges } ?? false }
    var canUndo: Bool { _ = revision; return undo.canUndo }
    var canRedo: Bool { _ = revision; return undo.canRedo }

    // MARK: Opening

    func open(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        password = nil
        dirty = false
        problem = nil
        selected = []
        undo.removeAllActions()
        thumbnails = [:]
        let document = PDFDocument(url: url)
        self.document = document
        locked = document?.isLocked ?? false
        recovery = PDFRecovery.pending(for: url)
        if document == nil { problem = "macOS can't read this PDF." }
        attach()
    }

    /// Opens a protected PDF with what the reader typed.
    func unlock(with password: String) {
        guard let document, document.unlock(withPassword: password) else { unlockFailed = true; return }
        self.password = password
        unlockFailed = false
        locked = false
        attach()
    }

    /// Hands the document to the view (again, after unlocking or restoring).
    func attach() {
        guard let view else { return }
        view.document = locked ? nil : document
        fitting = true
        found = nil
        applyLayout()
        refit()
        pageChanged()
        // After the fit's layout (and again once the sidebar and banner have settled), or the
        // view keeps its old place at the new scale and opens part-way down a later page.
        for delay in [0.0, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let view, let first = view.document?.page(at: 0) else { return }
                let top = first.bounds(for: view.displayBox).maxY
                view.go(to: PDFDestination(page: first, at: CGPoint(x: 0, y: top)))
            }
        }
        changedContent()
    }

    func applyLayout() {
        guard let view else { return }
        view.displayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        view.displaysAsBook = twoUp
        // Dark reading turns the pages' white to near-black and keeps hues where they were.
        if darkReading, let invert = CIFilter(name: "CIColorInvert"), let hue = CIFilter(name: "CIHueAdjust") {
            hue.setValue(Double.pi, forKey: kCIInputAngleKey)
            view.documentView?.wantsLayer = true
            view.documentView?.contentFilters = [invert, hue]
        } else {
            view.documentView?.contentFilters = []
        }
        refit()
    }

    // MARK: Zoom and place

    func zoom(by factor: CGFloat) {
        guard let view else { return }
        fitting = false
        view.scaleFactor = min(6, max(0.15, view.scaleFactor * factor))
        scale = view.scaleFactor
    }

    func fit() {
        fitting = true
        refit()
    }

    func refit() {
        guard fitting, let view, let page = view.document?.page(at: 0) else { return }
        let bounds = page.bounds(for: view.displayBox)
        let width = (page.rotation % 180 == 0 ? bounds.width : bounds.height) * (twoUp ? 2 : 1)
        guard width > 0 else { return }
        let room = min(view.bounds.width - 64, Self.widest * (twoUp ? 1.6 : 1))
        let new = max(0.15, room / width)
        // layout() calls this, and a new scale lays out again, so only real changes count.
        // A new scale leaves the scroll offset where it was, which drifts down the document as
        // the window, sidebar or panel lay out; keep the place being read instead.
        if abs(view.scaleFactor - new) > 0.002 {
            let place = view.currentDestination
            view.scaleFactor = new
            if let place { view.go(to: place) }
        }
        if scale != view.scaleFactor { scale = view.scaleFactor }
    }

    func pageChanged() {
        guard let view, let document = view.document, let current = view.currentPage else {
            pageCount = document?.pageCount ?? 0
            return
        }
        page = document.index(for: current) + 1
        pageCount = document.pageCount
    }

    func go(to index: Int) {
        guard let view, let page = view.document?.page(at: index) else { return }
        view.go(to: page)
    }

    var currentIndex: Int { max(0, page - 1) }

    // MARK: Search as you type

    func search() {
        searchTask?.cancel()
        let text = query
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self else { return }
            self.runSearch(text)
        }
    }

    private func runSearch(_ text: String) {
        guard let view, let document = view.document else { return }
        guard text.count >= 2 else {
            matches = []
            view.highlightedSelections = nil
            found = nil
            return
        }
        matches = document.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for match in matches { match.color = NSColor.systemYellow.withAlphaComponent(0.5) }
        view.highlightedSelections = matches
        // The first match at or after the page in view.
        matchIndex = matches.firstIndex { match in
            match.pages.first.map { document.index(for: $0) >= currentIndex } ?? false
        } ?? 0
        show()
    }

    /// Return and ↓ go to the next match, ⇧Return and ↑ the one before, wrapping round.
    func step(_ delta: Int) {
        if matches.isEmpty { runSearch(query); return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        show()
    }

    private func show() {
        guard let view, !matches.isEmpty else { found = query.count >= 2 ? "None" : nil; return }
        let match = matches[matchIndex]
        view.setCurrentSelection(match, animate: true)
        view.go(to: match)
        found = "\(matchIndex + 1) of \(matches.count)"
    }

    // MARK: The sidebar's pages

    func thumbnail(_ index: Int) -> NSImage? {
        guard let page = document?.page(at: index) else { return nil }
        let key = "\(ObjectIdentifier(page).hashValue)-\(page.rotation)-\(revision)"
        if let image = thumbnails[key] { return image }
        let image = page.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox)
        if thumbnails.count > 400 { thumbnails = [:] }
        thumbnails[key] = image
        return image
    }

    /// Finder's rules: a click picks one, ⌘ adds or removes, ⇧ takes the run from the last.
    func click(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let anchor {
            selected = Set(min(anchor, index)...max(anchor, index))
        } else if modifiers.contains(.command) {
            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
            anchor = index
        } else {
            selected = [index]
            anchor = index
            go(to: index)
        }
    }

    /// The pages a tool acts on: the sidebar's selection, else the page in view.
    var targets: [Int] {
        let chosen = selected.filter { $0 < (document?.pageCount ?? 0) }.sorted()
        return chosen.isEmpty ? [currentIndex] : chosen
    }

    // MARK: Changes, each undoable

    private struct Snapshot {
        var pages: [PDFPage]
        var rotations: [Int]
    }

    private func snapshot() -> Snapshot? {
        guard let document else { return nil }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        return Snapshot(pages: pages, rotations: pages.map(\.rotation))
    }

    private func restore(_ snapshot: Snapshot) {
        guard let document else { return }
        for index in (0..<document.pageCount).reversed() { document.removePage(at: index) }
        for (index, page) in snapshot.pages.enumerated() {
            page.rotation = snapshot.rotations[index]
            document.insert(page, at: index)
        }
    }

    /// Runs a change to the pages with undo (back to the snapshot) and redo (forward to the
    /// state it made).
    private func changePages(_ name: String, _ change: (PDFDocument) -> Void) {
        guard let document, canChange, let before = snapshot() else {
            problem = "The PDF's author doesn't allow changes to its pages."
            return
        }
        change(document)
        guard let after = snapshot() else { return }
        register(name, undo: before, redo: after)
        changed()
    }

    private func register(_ name: String, undo before: Snapshot, redo after: Snapshot) {
        undo.registerUndo(withTarget: self) { state in
            state.restore(before)
            state.register(name, undo: after, redo: before)
            state.changed()
        }
        undo.setActionName(name)
    }

    func rotate(by degrees: Int) {
        let pages = targets
        changePages(degrees < 0 ? "Rotate Left" : "Rotate Right") { PDFTools.rotate($0, pages: pages, by: degrees) }
    }

    func deletePages() {
        let pages = targets
        guard let document, pages.count < document.pageCount else {
            problem = "A PDF needs at least one page."
            return
        }
        changePages(pages.count == 1 ? "Delete Page" : "Delete Pages") { PDFTools.delete($0, pages: pages) }
        selected = []
    }

    func movePages(_ pages: [Int], to destination: Int) {
        var moved: [Int] = []
        changePages(pages.count == 1 ? "Move Page" : "Move Pages") { moved = PDFTools.move($0, pages: pages, to: destination) }
        selected = Set(moved)
    }

    func insertBlank() {
        let at = (targets.last ?? currentIndex) + 1
        changePages("Insert Page") { PDFTools.insertBlank($0, at: at, like: $0.page(at: at - 1)) }
        selected = [at]
        go(to: at)
    }

    /// Insert pages from other PDFs after the selection (or at the end with `atEnd`).
    func insertFiles(_ urls: [URL], atEnd: Bool = false) {
        var others: [PDFDocument] = []
        for url in urls {
            guard let other = PDFDocument(url: url), !other.isLocked else {
                problem = "\(url.lastPathComponent) can't be read, or needs its password."
                return
            }
            others.append(other)
        }
        var at = atEnd ? (document?.pageCount ?? 0) : (targets.last ?? currentIndex) + 1
        let start = at
        changePages(urls.count > 1 ? "Combine PDFs" : "Insert Pages") { document in
            for other in others { at += PDFTools.insert(other, into: document, at: at) }
        }
        selected = Set(start..<at)
        go(to: start)
    }

    // MARK: Comments

    func addComment(_ text: String) {
        guard let view, let document, canComment, let page = view.currentPage ?? document.page(at: 0) else { return }
        let passage = view.currentSelection.flatMap { $0.pages.contains(page) && !($0.string ?? "").isEmpty ? $0 : nil }
        let added = PDFTools.comment(text, by: author, on: passage?.pages.first ?? page, passage: passage)
        registerAnnotations(added, adding: true, name: passage == nil ? "Add Note" : "Add Comment")
        view.clearSelection()
        changed()
    }

    /// Highlights the selected text without a note.
    func highlightSelection() {
        guard let view, canComment, let selection = view.currentSelection, let page = selection.pages.first else { return }
        let added = PDFTools.comment("", by: author, on: page, passage: selection)
        registerAnnotations(added, adding: true, name: "Highlight")
        view.clearSelection()
        changed()
    }

    func reply(_ text: String, to thread: PDFTools.Thread) {
        guard canComment, let reply = PDFTools.reply(text, by: author, to: thread.root) else { return }
        registerAnnotations([reply], adding: true, name: "Reply")
        changed()
    }

    func remove(_ thread: PDFTools.Thread) {
        guard canComment else { return }
        let taken = PDFTools.remove(thread)
        registerAnnotations(taken.map(\.annotation), pages: taken.map(\.page), adding: false, name: "Delete Comment")
        changed()
    }

    private func registerAnnotations(_ annotations: [PDFAnnotation], pages: [PDFPage]? = nil, adding: Bool, name: String) {
        let pages = pages ?? annotations.compactMap(\.page)
        guard pages.count == annotations.count else { return }
        undo.registerUndo(withTarget: self) { state in
            for (annotation, page) in zip(annotations, pages) {
                if adding { page.removeAnnotation(annotation) } else { page.addAnnotation(annotation) }
            }
            state.registerAnnotations(annotations, pages: pages, adding: !adding, name: name)
            state.changed()
        }
        undo.setActionName(name)
    }

    // MARK: After a change

    func changed() {
        // Rebuilding the page list sends the view to the top, so it goes back to where it was.
        let keep = currentIndex
        dirty = true
        problem = nil
        view?.layoutDocumentView()
        changedContent()
        if let document, document.pageCount > 0, view?.currentPage.map(document.index(for:)) != keep {
            go(to: min(keep, document.pageCount - 1))
        }
        pageChanged()
        scheduleRecovery()
        if Preferences.shared.autoSave != .off { scheduleAutosave() }
    }

    private func changedContent() {
        revision += 1
        threads = document.map(PDFTools.threads(in:)) ?? []
    }

    private func scheduleRecovery() {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.dirty, let document = self.document, let url = self.url else { return }
            PDFRecovery.keep(document, for: url)
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.dirty else { return }
            self.save()
        }
    }

    // MARK: Saving

    func save() {
        guard let document, let url else { return }
        do {
            try PDFTools.save(document, to: url, password: password)
            dirty = false
            lastSaved = Date()
            problem = nil
            recoveryTask?.cancel()
            PDFRecovery.discard(for: url)
            recovery = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Writes a copy (the whole document, or some pages) where the reader picks.
    func saveCopy(pages: [Int]? = nil, suggestion: String? = nil) {
        guard let document, let url else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = suggestion ?? url.deletingPathExtension().lastPathComponent + " copy.pdf"
        panel.begin { [weak self] response in
            guard response == .OK, let target = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    let copy = pages.map { PDFTools.extract(document, pages: $0) } ?? document
                    try PDFTools.save(copy, to: target)
                } catch {
                    self?.problem = error.localizedDescription
                }
            }
        }
    }

    func extractPages() {
        let pages = targets
        let stem = url?.deletingPathExtension().lastPathComponent ?? "pages"
        let label = pages.count == 1 ? "page \(pages[0] + 1)" : "pages \(pages.first! + 1)-\(pages.last! + 1)"
        saveCopy(pages: pages, suggestion: "\(stem) \(label).pdf")
    }

    /// Splits into a file per page, or in two after the page in view, into a folder the reader picks.
    func split(everyPage: Bool) {
        guard let document, let url else { return }
        let starts = everyPage ? PDFTools.splitPoints(every: 1, count: document.pageCount) : [targets.last.map { $0 + 1 } ?? page]
        let parts = PDFTools.split(document, cuttingAt: starts)
        guard parts.count > 1 else { problem = "There's nothing after this page to split off."; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Split Here"
        panel.message = "Where the \(parts.count) parts go"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    for (part, target) in zip(parts, PDFTools.partURLs(for: url, count: parts.count, in: folder)) {
                        try PDFTools.save(part, to: target)
                    }
                } catch {
                    self?.problem = error.localizedDescription
                }
            }
        }
    }

    func choosePDFs(atEnd: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.prompt = atEnd ? "Combine" : "Insert"
        panel.directoryURL = url?.deletingLastPathComponent()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { self?.insertFiles(urls, atEnd: atEnd) }
        }
    }

    /// Saves with a password (or a new one); opening the file needs it from then on.
    func protect(with password: String) {
        self.password = password
        save()
    }

    func restoreRecovery() {
        guard let recovery, let copy = PDFDocument(url: recovery) else { return }
        document = copy
        self.recovery = nil
        attach()
        dirty = true
    }

    func discardRecovery() {
        guard let url else { return }
        PDFRecovery.discard(for: url)
        recovery = nil
    }

    func copyPageText() {
        guard document?.allowsCopying == true, let text = document?.page(at: currentIndex)?.string else {
            problem = "The PDF's author doesn't allow copying its text."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
