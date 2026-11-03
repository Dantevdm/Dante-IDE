import AppKit
import DanteKit
import PDFKit
import SwiftUI

/// A PDF in Docs or Code: the pages at a readable width, with a sidebar of pages (drag to
/// reorder; rotate, delete, insert, extract, split), bookmarks and comments; search as you
/// type; one or two pages; dark reading; undo for every change; and a tools palette.
struct PDFPreview: View {
    @Environment(\.theme) private var theme
    let url: URL
    @State private var pdf = PDFState()
    @State private var sidebar: Sidebar? = .pages
    @State private var showsTools = false
    @State private var protecting = false

    enum Sidebar: String, CaseIterable, Identifiable {
        case pages = "Pages", bookmarks = "Bookmarks", comments = "Comments"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .pages: "square.grid.2x2"
            case .bookmarks: "list.bullet.indent"
            case .comments: "text.bubble"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let recovery = pdf.recovery { recoveryBanner(recovery) }
            if let problem = pdf.problem {
                Text(problem)
                    .font(.dante(size: 12)).foregroundStyle(theme.red.color)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.panel.color)
            }
            HStack(spacing: 0) {
                if let sidebar, !pdf.locked {
                    PDFSidebar(pdf: pdf, tab: Binding(get: { sidebar }, set: { self.sidebar = $0 }))
                        .frame(width: 220)
                    Rectangle().fill(theme.line.color).frame(width: 1)
                }
                ZStack {
                    PDFKitView(url: url, background: theme.ground.nsColor, state: pdf)
                    if pdf.locked { PDFUnlockView(pdf: pdf) }
                }
            }
        }
        .task(id: url) {
            if let root = Self.projectRoot(of: url), let name = await CodeReview.reviewer(in: root) { pdf.author = name }
        }
        .sheet(isPresented: $protecting) { PDFProtectSheet(pdf: pdf) }
    }

    /// The git repository a PDF is in, for the name comments are signed with.
    static func projectRoot(of url: URL) -> URL? {
        var folder = url.deletingLastPathComponent()
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) { return folder }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: The bar

    private var toolbar: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "sidebar.left", label: sidebar == nil ? "Show pages, bookmarks and comments" : "Hide the sidebar", size: 12) {
                sidebar = sidebar == nil ? .pages : nil
            }
            IconButton(symbol: "arrow.uturn.backward", label: pdf.undo.undoMenuItemTitle, size: 12) { pdf.undo.undo() }
                .disabled(!pdf.canUndo)
            IconButton(symbol: "arrow.uturn.forward", label: pdf.undo.redoMenuItemTitle, size: 12) { pdf.undo.redo() }
                .disabled(!pdf.canRedo)
            Text(pdf.pageCount == 0 ? "No pages" : "Page \(pdf.page) of \(pdf.pageCount)")
                .font(.dante(size: 12).monospacedDigit())
                .foregroundStyle(theme.text2.color)
                .fixedSize()
            Spacer(minLength: 8)
            searchField
            IconButton(symbol: pdf.twoUp ? "book" : "doc", label: pdf.twoUp ? "One page at a time" : "Two pages side by side", size: 12) {
                pdf.twoUp.toggle()
            }
            IconButton(symbol: pdf.darkReading ? "sun.max" : "moon", label: pdf.darkReading ? "Light pages" : "Dark reading: light text on dark pages", size: 12) {
                pdf.darkReading.toggle()
            }
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
            Button { showsTools = true } label: {
                Label("Tools", systemImage: "square.grid.2x2").font(.dante(size: 12, weight: .medium))
            }
            .buttonStyle(DanteButtonStyle())
            .help("Every PDF tool, searchable")
            .popover(isPresented: $showsTools, arrowEdge: .bottom) {
                PDFToolsPalette(pdf: pdf, protect: { protecting = true }, comment: { sidebar = .comments }) { showsTools = false }
            }
            if pdf.dirty {
                Button("Save") { pdf.save() }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Saves in place; until then the changes are kept in a recovery copy")
            } else if let saved = pdf.lastSaved {
                Text("Saved \(saved.formatted(date: .omitted, time: .shortened))")
                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(theme.panel.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
            TextField("Find in PDF", text: $pdf.query)
                .textFieldStyle(.plain)
                .font(.dante(size: 12))
                .frame(width: 140)
                .onSubmit { pdf.step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                .onKeyPress(.downArrow) { pdf.step(1); return .handled }
                .onKeyPress(.upArrow) { pdf.step(-1); return .handled }
            if let found = pdf.found {
                Text(found).font(.dante(size: 11).monospacedDigit()).foregroundStyle(theme.text3.color).fixedSize()
                Button { pdf.step(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).help("Previous match (⇧Return)")
                Button { pdf.step(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).help("Next match (Return)")
            }
        }
        .font(.dante(size: 10.5, weight: .semibold))
        .foregroundStyle(theme.text3.color)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color))
        .onChange(of: pdf.query) { pdf.search() }
    }

    private func recoveryBanner(_ recovery: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(theme.amber.color)
            Text("This PDF has changes that weren't saved, kept from \(Self.modified(recovery))." )
                .font(.dante(size: 12.5))
            Spacer()
            Button("Restore them") { pdf.restoreRecovery() }.buttonStyle(DanteButtonStyle(primary: true))
            Button("Discard") { pdf.discardRecovery() }.buttonStyle(DanteButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(theme.amber.color.opacity(0.1))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    static func modified(_ url: URL) -> String {
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? Date()
        return date.formatted(.relative(presentation: .named))
    }
}

// MARK: The sidebar

private struct PDFSidebar: View {
    @Environment(\.theme) private var theme
    let pdf: PDFState
    @Binding var tab: PDFPreview.Sidebar

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                ForEach(PDFPreview.Sidebar.allCases) { item in
                    Image(systemName: item.symbol).help(item.rawValue).accessibilityLabel(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.top, 8)
            HStack {
                Text(tab == .comments && !pdf.threads.isEmpty ? "\(pdf.threads.count) \(pdf.threads.count == 1 ? "comment" : "comments")" : tab.rawValue)
                    .font(.dante(size: 11, weight: .medium)).foregroundStyle(theme.text3.color)
                Spacer()
                if tab == .pages, pdf.selected.count > 1 {
                    Text("\(pdf.selected.count) chosen").font(.dante(size: 11)).foregroundStyle(theme.accent.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            switch tab {
            case .pages: PDFPagesList(pdf: pdf)
            case .bookmarks: PDFBookmarks(pdf: pdf)
            case .comments: PDFCommentsList(pdf: pdf)
            }
        }
        .background(theme.panel.color)
    }
}

/// Thumbnails: click, ⌘-click and ⇧-click select; drag onto another page to move the selection
/// before it; the context menu has the page tools.
private struct PDFPagesList: View {
    @Environment(\.theme) private var theme
    let pdf: PDFState
    @State private var dropTarget: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    let _ = pdf.revision
                    ForEach(0..<pdf.pageCount, id: \.self) { index in
                        thumbnail(index).id(index)
                    }
                    // Dropping below the last page moves pages to the end.
                    Color.clear.frame(height: 30)
                        .dropDestination(for: String.self) { items, _ in drop(items, at: pdf.pageCount) } isTargeted: { dropTarget = $0 ? pdf.pageCount : nil }
                        .overlay(alignment: .top) { if dropTarget == pdf.pageCount { insertionLine } }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .onChange(of: pdf.page) { _, page in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(page - 1, anchor: .center) }
            }
        }
    }

    private var insertionLine: some View {
        RoundedRectangle(cornerRadius: 1.5).fill(theme.accent.color).frame(height: 3).offset(y: -6)
    }

    private func thumbnail(_ index: Int) -> some View {
        let selected = pdf.selected.contains(index)
        let current = pdf.page == index + 1
        return VStack(spacing: 4) {
            Group {
                if let image = pdf.thumbnail(index) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Rectangle().fill(theme.card.color).aspectRatio(0.75, contentMode: .fit)
                }
            }
            .frame(maxWidth: 150, maxHeight: 190)
            .background(Color.white)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(selected ? theme.accent.color : current ? theme.line2.color : .clear, lineWidth: selected ? 3 : 1.5))
            Text("\(index + 1)")
                .font(.dante(size: 11, weight: current ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(selected ? theme.accent.color : theme.text3.color)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { pdf.click(index, modifiers: NSEvent.modifierFlags) }
        .draggable(String(index)) {
            Text(pdf.selected.contains(index) && pdf.selected.count > 1 ? "\(pdf.selected.count) pages" : "Page \(index + 1)")
                .font(.dante(size: 12, weight: .medium)).padding(6)
        }
        .dropDestination(for: String.self) { items, _ in drop(items, at: index) } isTargeted: { dropTarget = $0 ? index : (dropTarget == index ? nil : dropTarget) }
        .overlay(alignment: .top) { if dropTarget == index { insertionLine } }
        .contextMenu { PDFPageMenu(pdf: pdf, index: index) }
        .help("Page \(index + 1). Drag to move; ⌘-click or ⇧-click to choose several.")
    }

    private func drop(_ items: [String], at destination: Int) -> Bool {
        dropTarget = nil
        guard let dragged = items.first.flatMap(Int.init) else { return false }
        let pages = pdf.selected.contains(dragged) ? pdf.selected.sorted() : [dragged]
        guard !(pages.count == 1 && (pages[0] == destination || pages[0] + 1 == destination)) else { return false }
        pdf.movePages(pages, to: destination)
        return true
    }
}

private struct PDFPageMenu: View {
    let pdf: PDFState
    let index: Int

    var body: some View {
        let _ = prepare()
        let count = pdf.targets.count
        let pages = count == 1 ? "Page" : "\(count) Pages"
        Button("Rotate \(pages) Left") { pdf.rotate(by: -90) }.disabled(!pdf.canChange)
        Button("Rotate \(pages) Right") { pdf.rotate(by: 90) }.disabled(!pdf.canChange)
        Divider()
        Button("Insert Blank Page After") { pdf.insertBlank() }.disabled(!pdf.canChange)
        Button("Insert Pages from a PDF…") { pdf.choosePDFs(atEnd: false) }.disabled(!pdf.canChange)
        Divider()
        Button("Extract \(pages) to a New PDF…") { pdf.extractPages() }
        Button("Split After This Page…") { pdf.split(everyPage: false) }
        Divider()
        Button("Delete \(pages)", role: .destructive) { pdf.deletePages() }.disabled(!pdf.canChange)
    }

    /// A right-click on a page outside the selection acts on that page.
    private func prepare() {
        if !pdf.selected.contains(index) { DispatchQueue.main.async { pdf.selected = [index] } }
    }
}

private struct PDFBookmarks: View {
    @Environment(\.theme) private var theme
    let pdf: PDFState

    struct Entry: Identifiable {
        var id: Int
        var title: String
        var depth: Int
        var page: Int?
    }

    var body: some View {
        let entries = Self.entries(pdf.document)
        if entries.isEmpty {
            Text("This PDF has no bookmarks.")
                .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        Button { if let page = entry.page { pdf.go(to: page) } } label: {
                            HStack {
                                Text(entry.title).font(.dante(size: 12.5, weight: entry.depth == 0 ? .medium : .regular)).lineLimit(2)
                                Spacer()
                                if let page = entry.page {
                                    Text("\(page + 1)").font(.dante(size: 11).monospacedDigit()).foregroundStyle(theme.text3.color)
                                }
                            }
                            .padding(.leading, CGFloat(entry.depth) * 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    static func entries(_ document: PDFDocument?) -> [Entry] {
        guard let document, let root = document.outlineRoot else { return [] }
        var entries: [Entry] = []
        func walk(_ outline: PDFOutline, depth: Int) {
            for index in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: index) else { continue }
                let page = child.destination?.page.map { document.index(for: $0) }
                entries.append(Entry(id: entries.count, title: child.label ?? "Untitled", depth: depth, page: page))
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return entries
    }
}

/// Comments, newest page last: who, when, the passage, the note and its replies, with Reply
/// and Delete; a box at the top comments on the selected text or the page in view.
private struct PDFCommentsList: View {
    @Environment(\.theme) private var theme
    let pdf: PDFState
    @State private var draft = ""
    @State private var replies: [ObjectIdentifier: String] = [:]

    private func send(_ text: String, to thread: PDFTools.Thread) {
        guard !text.isEmpty else { return }
        pdf.reply(text, to: thread)
        replies[thread.id] = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Comment on the selected text or this page", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.dante(size: 12))
                    .onSubmit(add)
                HStack {
                    Text("as \(pdf.author)").font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
                    Spacer()
                    Button("Comment", action: add).buttonStyle(DanteButtonStyle(primary: true))
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || !pdf.canComment)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Rectangle().fill(theme.line.color).frame(height: 1)
            if pdf.threads.isEmpty {
                Text(pdf.canComment ? "No comments yet. Select text in the page and write above, or highlight it from Tools." : "The PDF's author doesn't allow comments.")
                    .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                    .padding(12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(pdf.threads) { thread in
                            row(thread)
                            Rectangle().fill(theme.line.color).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pdf.addComment(text)
        draft = ""
    }

    private func row(_ thread: PDFTools.Thread) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ReviewerBadge(name: thread.author, current: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(thread.author).font(.dante(size: 12, weight: .semibold)).lineLimit(1)
                    Text("Page \(thread.page + 1)" + (thread.date.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                        .font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
                }
                Spacer()
                Button { pdf.remove(thread) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(theme.text3.color).help("Delete this comment and its replies")
                    .disabled(!pdf.canComment)
            }
            if let quote = thread.quote {
                Text("“\(quote)”").font(.dante(size: 11.5)).italic().foregroundStyle(theme.text2.color).lineLimit(3)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(theme.amber.color).frame(width: 2) }
            }
            if !thread.text.isEmpty {
                Text(thread.text).font(.dante(size: 12.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ForEach(Array(thread.replies.enumerated()), id: \.offset) { _, reply in
                VStack(alignment: .leading, spacing: 2) {
                    Text((reply.userName ?? "Someone") + (reply.modificationDate.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                        .font(.dante(size: 10.5, weight: .medium)).foregroundStyle(theme.text3.color)
                    Text(reply.contents ?? "").font(.dante(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .padding(.leading, 14)
            }
            if pdf.canComment {
                let reply = (replies[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                HStack(spacing: 4) {
                    TextField("Reply", text: Binding(get: { replies[thread.id] ?? "" }, set: { replies[thread.id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.dante(size: 11.5))
                        .onSubmit { send(reply, to: thread) }
                    if !reply.isEmpty {
                        Button { send(reply, to: thread) } label: {
                            Image(systemName: "arrow.up.circle.fill").foregroundStyle(theme.accent.color)
                        }
                        .buttonStyle(.plain)
                        .help("Reply")
                    }
                }
                .padding(.leading, 14)
            }
        }
        .padding(10)
        .contentShape(Rectangle())
        .onTapGesture { pdf.go(to: thread.page) }
    }
}

// MARK: The tools palette

/// Every tool by name, filtered as you type; Return runs the first.
private struct PDFToolsPalette: View {
    @Environment(\.theme) private var theme
    let pdf: PDFState
    let protect: () -> Void
    let comment: () -> Void
    let close: () -> Void
    @State private var filter = ""

    struct Tool: Identifiable {
        var title: String
        var detail: String
        var symbol: String
        var enabled = true
        var run: () -> Void
        var id: String { title }
    }

    private var tools: [Tool] {
        let pages = pdf.targets.count == 1 ? "page \(pdf.targets[0] + 1)" : "\(pdf.targets.count) pages"
        let changes = pdf.canChange
        return [
            Tool(title: "Rotate left", detail: pages, symbol: "rotate.left", enabled: changes) { pdf.rotate(by: -90) },
            Tool(title: "Rotate right", detail: pages, symbol: "rotate.right", enabled: changes) { pdf.rotate(by: 90) },
            Tool(title: "Delete pages", detail: pages, symbol: "trash", enabled: changes) { pdf.deletePages() },
            Tool(title: "Insert a blank page", detail: "after \(pages)", symbol: "doc.badge.plus", enabled: changes) { pdf.insertBlank() },
            Tool(title: "Insert pages from a PDF…", detail: "after \(pages)", symbol: "square.and.arrow.down.on.square", enabled: changes) { pdf.choosePDFs(atEnd: false) },
            Tool(title: "Combine with other PDFs…", detail: "adds their pages at the end", symbol: "rectangle.stack.badge.plus", enabled: changes) { pdf.choosePDFs(atEnd: true) },
            Tool(title: "Extract pages…", detail: "\(pages) to a new PDF", symbol: "doc.on.doc") { pdf.extractPages() },
            Tool(title: "Split after this page…", detail: "two files", symbol: "scissors") { pdf.split(everyPage: false) },
            Tool(title: "Split into single pages…", detail: "a file per page", symbol: "square.split.2x1") { pdf.split(everyPage: true) },
            Tool(title: "Comment", detail: "on the selected text or this page", symbol: "text.bubble", enabled: pdf.canComment) { comment() },
            Tool(title: "Highlight the selected text", detail: "without a note", symbol: "highlighter", enabled: pdf.canComment) { pdf.highlightSelection() },
            Tool(title: pdf.twoUp ? "One page at a time" : "Two pages side by side", detail: "reading layout", symbol: "book") { pdf.twoUp.toggle() },
            Tool(title: pdf.darkReading ? "Light pages" : "Dark reading", detail: "light text on dark pages", symbol: "moon") { pdf.darkReading.toggle() },
            Tool(title: "Fit to width", detail: "zoom", symbol: "arrow.left.and.right") { pdf.fit() },
            Tool(title: "Copy this page's text", detail: "page \(pdf.page)", symbol: "doc.plaintext", enabled: pdf.document?.allowsCopying ?? false) { pdf.copyPageText() },
            Tool(title: "Protect with a password…", detail: "opening will need it", symbol: "lock", enabled: changes) { protect() },
            Tool(title: "Save a copy…", detail: "the whole PDF", symbol: "square.and.arrow.down") { pdf.saveCopy() },
            Tool(title: "Save", detail: pdf.dirty ? "in place" : "nothing to save", symbol: "checkmark.circle", enabled: pdf.dirty) { pdf.save() },
            Tool(title: "Show in Finder", detail: pdf.url?.lastPathComponent ?? "", symbol: "folder") {
                if let url = pdf.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            },
        ]
    }

    private var shown: [Tool] {
        let words = filter.lowercased().split(separator: " ")
        return tools.filter { tool in words.allSatisfy { (tool.title + " " + tool.detail).lowercased().contains($0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search PDF tools", text: $filter)
                .textFieldStyle(.roundedBorder)
                .font(.dante(size: 13))
                .padding(10)
                .onSubmit { if let tool = shown.first(where: \.enabled) { run(tool) } }
            Rectangle().fill(theme.line.color).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { tool in
                        Button { run(tool) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tool.symbol).frame(width: 18).foregroundStyle(theme.accent.color)
                                Text(tool.title).font(.dante(size: 12.5))
                                Spacer()
                                Text(tool.detail).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!tool.enabled)
                        .opacity(tool.enabled ? 1 : 0.45)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 360)
        }
        .frame(width: 380)
    }

    private func run(_ tool: Tool) {
        close()
        tool.run()
    }
}

// MARK: Locked and protecting

private struct PDFUnlockView: View {
    @Environment(\.theme) private var theme
    let pdf: PDFState
    @State private var password = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.doc").font(.dante(size: 30, weight: .light)).foregroundStyle(theme.text3.color)
            Text("This PDF is protected").font(.dante(size: 15, weight: .semibold))
            Text("Type its password to open it. Dante keeps the password only while it's open, and saving keeps the file protected.")
                .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder).frame(width: 240)
                .onSubmit { pdf.unlock(with: password) }
            if pdf.unlockFailed {
                Text("That isn't its password.").font(.dante(size: 12)).foregroundStyle(theme.red.color)
            }
            Button("Open") { pdf.unlock(with: password) }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(password.isEmpty)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.ground.color)
    }
}

private struct PDFProtectSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let pdf: PDFState
    @State private var password = ""
    @State private var again = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Protect with a password").font(.dante(size: 16, weight: .semibold))
            Text("Opening \(pdf.url?.lastPathComponent ?? "the PDF") will need this password, in any PDF reader. Dante doesn't keep it.")
                .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            SecureField("Again", text: $again).textFieldStyle(.roundedBorder)
            if !again.isEmpty, again != password {
                Text("The two don't match.").font(.dante(size: 12)).foregroundStyle(theme.red.color)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DanteButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Protect") {
                    pdf.protect(with: password)
                    dismiss()
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(password.count < 4 || password != again)
            }
        }
        .padding(22)
        .frame(width: 400)
    }
}

// MARK: The PDFKit view

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
        if state.url != url {
            state.open(url)
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    final class Coordinator {
        var observer: (any NSObjectProtocol)?
    }

    /// Refits as the pane changes width, and answers Edit › Undo with the PDF's own history.
    private final class FittingPDFView: PDFView {
        weak var state: PDFState?
        override func layout() {
            super.layout()
            state?.refit()
        }
        override var undoManager: UndoManager? { state?.undo ?? super.undoManager }
    }
}
