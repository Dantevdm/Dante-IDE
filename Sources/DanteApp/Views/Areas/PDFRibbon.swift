import AppKit
import DanteKit
import SwiftUI

// MARK: The tools

/// One PDF tool, as the ribbon and the tool search both show it.
struct PDFTool: Identifiable {
    var id: String
    /// The name in the tool search and the ScreenTip's heading.
    var title: String
    /// The toolbar label beside its icon: a word or two.
    var label: String
    /// What it acts on right now ("page 6", "3 pages").
    var detail: String
    /// The ScreenTip's sentence.
    var tip: String
    var symbol: String
    var enabled = true
    /// Why it can't be used, when it can't.
    var unavailable: String?
    /// For switches (two pages, dark reading, the sidebar): whether it's on.
    var isOn: Bool?
    var run: () -> Void
}

/// Every tool for one open PDF, by id.
@MainActor
struct PDFToolbox {
    let pdf: PDFState
    let sidebar: PDFPreview.Sidebar?
    let showSidebar: (PDFPreview.Sidebar?) -> Void
    let protect: () -> Void

    var all: [PDFTool] {
        let pages = pdf.targets.count == 1 ? "page \(pdf.targets[0] + 1)" : "\(pdf.targets.count) pages"
        let changes = pdf.canChange
        let locked = changes ? nil : "This PDF doesn’t allow its pages to be changed."
        let commenting = pdf.canComment ? nil : "This PDF doesn’t allow comments."
        let copying = pdf.document?.allowsCopying ?? false
        return [
            PDFTool(id: "rotateLeft", title: "Rotate left", label: "Rotate Left", detail: pages,
                    tip: "Turns the page a quarter turn anticlockwise. Choose several pages in the sidebar to turn them all.",
                    symbol: "rotate.left", enabled: changes, unavailable: locked) { pdf.rotate(by: -90) },
            PDFTool(id: "rotateRight", title: "Rotate right", label: "Rotate Right", detail: pages,
                    tip: "Turns the page a quarter turn clockwise. Choose several pages in the sidebar to turn them all.",
                    symbol: "rotate.right", enabled: changes, unavailable: locked) { pdf.rotate(by: 90) },
            PDFTool(id: "delete", title: "Delete pages", label: "Delete Pages", detail: pages,
                    tip: "Takes the pages out of the PDF. Undo brings them back.",
                    symbol: "trash", enabled: changes && pdf.pageCount > pdf.targets.count, unavailable: locked ?? (pdf.pageCount > pdf.targets.count ? nil : "A PDF needs at least one page.")) { pdf.deletePages() },
            PDFTool(id: "blank", title: "Insert a blank page", label: "Blank Page", detail: "after \(pages)",
                    tip: "Adds an empty page the size of this one after it.",
                    symbol: "doc.badge.plus", enabled: changes, unavailable: locked) { pdf.insertBlank() },
            PDFTool(id: "insertPDF", title: "Insert pages from a PDF…", label: "Pages from PDF", detail: "after \(pages)",
                    tip: "Choose PDFs; their pages go in after this one, in order.",
                    symbol: "square.and.arrow.down.on.square", enabled: changes, unavailable: locked) { pdf.choosePDFs(atEnd: false) },
            PDFTool(id: "combine", title: "Combine with other PDFs…", label: "Combine PDFs", detail: "adds their pages at the end",
                    tip: "Choose PDFs to add at the end of this one. Their bookmarks come with them.",
                    symbol: "rectangle.stack.badge.plus", enabled: changes, unavailable: locked) { pdf.choosePDFs(atEnd: true) },
            PDFTool(id: "extract", title: "Extract pages…", label: "Extract Pages", detail: "\(pages) to a new PDF",
                    tip: "Saves the chosen pages as a PDF of their own. This one stays as it is.",
                    symbol: "doc.on.doc") { pdf.extractPages() },
            PDFTool(id: "splitAfter", title: "Split after this page…", label: "Split Here", detail: "two files",
                    tip: "Saves two PDFs: the pages up to this one, and the rest.",
                    symbol: "scissors") { pdf.split(everyPage: false) },
            PDFTool(id: "splitEach", title: "Split into single pages…", label: "Every Page", detail: "a file per page",
                    tip: "Saves each page as a PDF of its own, numbered, in a folder you choose.",
                    symbol: "square.split.2x1") { pdf.split(everyPage: true) },
            PDFTool(id: "comment", title: "Comment", label: "New Comment", detail: "on the selected text or this page",
                    tip: "Adds a note to the selected text, or to the page when nothing is selected. Replies and resolving are in the Comments list.",
                    symbol: "text.bubble", enabled: pdf.canComment, unavailable: commenting) { showSidebar(.comments) },
            PDFTool(id: "highlight", title: "Highlight the selected text", label: "Highlight", detail: "without a note",
                    tip: "Marks the selected text in yellow. Select some text on the page first.",
                    symbol: "highlighter", enabled: pdf.canComment, unavailable: commenting) { pdf.highlightSelection() },
            PDFTool(id: "comments", title: "Show the comments", label: "Comments", detail: "\(pdf.threads.count) in this PDF",
                    tip: "Every comment in the PDF, with its replies, in the sidebar.",
                    symbol: "list.bullet.rectangle", isOn: sidebar == .comments) { showSidebar(sidebar == .comments ? nil : .comments) },
            PDFTool(id: "bookmarks", title: "Show the bookmarks", label: "Bookmarks", detail: "the PDF’s outline",
                    tip: "The PDF’s table of contents in the sidebar; click one to go there.",
                    symbol: "list.bullet.indent", isOn: sidebar == .bookmarks) { showSidebar(sidebar == .bookmarks ? nil : .bookmarks) },
            PDFTool(id: "thumbnails", title: "Show the pages", label: "Pages", detail: "thumbnails",
                    tip: "Every page in the sidebar. Drag to reorder; ⌘-click or ⇧-click to choose several for the page tools.",
                    symbol: "square.grid.2x2", isOn: sidebar == .pages) { showSidebar(sidebar == .pages ? nil : .pages) },
            PDFTool(id: "single", title: "One page at a time", label: "One Page", detail: "reading layout",
                    tip: "Pages one under another, as wide as reads comfortably.",
                    symbol: "doc", isOn: !pdf.twoUp) { pdf.twoUp = false },
            PDFTool(id: "twoUp", title: "Two pages side by side", label: "Two Pages", detail: "reading layout",
                    tip: "Pages in pairs, like an open book.",
                    symbol: "book", isOn: pdf.twoUp) { pdf.twoUp = true },
            PDFTool(id: "dark", title: pdf.darkReading ? "Light pages" : "Dark reading", label: "Dark Reading", detail: "light text on dark pages",
                    tip: "Turns the pages dark for reading at night, keeping their colours’ hues. The file isn’t changed.",
                    symbol: "moon", isOn: pdf.darkReading) { pdf.darkReading.toggle() },
            PDFTool(id: "fit", title: "Fit to width", label: "Fit Width", detail: "zoom",
                    tip: "Zooms so the page fills the width, up to a comfortable reading width.",
                    symbol: "arrow.left.and.right", isOn: pdf.fitting) { pdf.fit() },
            PDFTool(id: "zoomIn", title: "Zoom in", label: "Zoom In", detail: "\(Int((pdf.scale * 100).rounded()))%",
                    tip: "Makes the pages larger. Pinch on the trackpad does it too.",
                    symbol: "plus.magnifyingglass") { pdf.zoom(by: 1.2) },
            PDFTool(id: "zoomOut", title: "Zoom out", label: "Zoom Out", detail: "\(Int((pdf.scale * 100).rounded()))%",
                    tip: "Makes the pages smaller.",
                    symbol: "minus.magnifyingglass") { pdf.zoom(by: 1 / 1.2) },
            PDFTool(id: "copyText", title: "Copy this page’s text", label: "Copy Text", detail: "page \(pdf.page)",
                    tip: "Puts the text of the page in view on the clipboard.",
                    symbol: "doc.plaintext", enabled: copying, unavailable: copying ? nil : "This PDF doesn’t allow copying.") { pdf.copyPageText() },
            PDFTool(id: "protect", title: "Protect with a password…", label: "Password", detail: "opening will need it",
                    tip: "Encrypts the PDF so it opens only with the password you choose.",
                    symbol: "lock", enabled: changes, unavailable: locked) { protect() },
            PDFTool(id: "save", title: "Save", label: "Save", detail: pdf.dirty ? "in place" : "nothing to save",
                    tip: "Writes the changes into the file (⌘S). Until then they’re kept in a recovery copy.",
                    symbol: "checkmark.circle", enabled: pdf.dirty, unavailable: pdf.dirty ? nil : "There are no changes to save.") { pdf.save() },
            PDFTool(id: "saveCopy", title: "Save a copy…", label: "Save a Copy", detail: "the whole PDF",
                    tip: "Saves the PDF as it is now under another name, leaving this file alone.",
                    symbol: "square.and.arrow.down") { pdf.saveCopy() },
            PDFTool(id: "finder", title: "Show in Finder", label: "Show in Finder", detail: pdf.url?.lastPathComponent ?? "",
                    tip: "Opens the folder with this PDF selected.",
                    symbol: "folder") { if let url = pdf.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } },
        ]
    }

    func tools(_ ids: [String]) -> [PDFTool] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }
}

// MARK: The ribbon

/// The PDF toolbar: one row with the tabs on the left, that tab's tools beside them as small
/// buttons in groups split by hairlines, and "Search tools" on the right. Each tool has a
/// ScreenTip; dropdowns hold related tools.
struct PDFRibbon: View {
    @Environment(\.theme) private var theme
    let toolbox: PDFToolbox
    @AppStorage("pdf.ribbon.tab") private var tab = Tab.home.rawValue
    @State private var searching = false

    enum Tab: String, CaseIterable, Identifiable {
        case file = "File", home = "Home", insert = "Insert", organise = "Organise", review = "Review", view = "View"
        var id: String { rawValue }
    }

    struct Group: Identifiable {
        var title: String
        var items: [Item]
        var id: String { title }
    }

    enum Item {
        case tools([String])
        /// A button that opens a list of tools.
        case menu(label: String, symbol: String, tip: String, [String])
    }

    static func groups(_ tab: Tab) -> [Group] {
        switch tab {
        case .file:
            [Group(title: "Save", items: [.tools(["save", "saveCopy"])]),
             Group(title: "Protect", items: [.tools(["protect"])]),
             Group(title: "File", items: [.tools(["finder", "copyText"])])]
        case .home:
            [Group(title: "Pages", items: [.tools(["delete", "rotateLeft", "rotateRight", "blank"])]),
             Group(title: "Comments", items: [.tools(["comment", "highlight"])]),
             Group(title: "Clipboard", items: [.tools(["copyText"])]),
             Group(title: "Save", items: [.tools(["save", "saveCopy", "finder"])])]
        case .insert:
            [Group(title: "Pages", items: [.tools(["blank", "insertPDF"])]),
             Group(title: "Documents", items: [.tools(["combine"])])]
        case .organise:
            [Group(title: "Rotate", items: [.tools(["rotateLeft", "rotateRight"])]),
             Group(title: "Pages", items: [.tools(["delete", "extract"])]),
             Group(title: "Split", items: [.menu(label: "Split", symbol: "scissors",
                                                 tip: "Cut the PDF into separate files, after this page or one per page.",
                                                 ["splitAfter", "splitEach"])])]
        case .review:
            [Group(title: "Comments", items: [.tools(["comment", "highlight", "comments"])]),
             Group(title: "Navigate", items: [.tools(["bookmarks"])])]
        case .view:
            [Group(title: "Layout", items: [.tools(["single", "twoUp"])]),
             Group(title: "Reading", items: [.tools(["dark"])]),
             Group(title: "Zoom", items: [.tools(["fit", "zoomIn", "zoomOut"])]),
             Group(title: "Sidebar", items: [.menu(label: "Sidebar", symbol: "sidebar.left",
                                                   tip: "Show the pages, the bookmarks or the comments beside the PDF.",
                                                   ["thumbnails", "bookmarks", "comments"])])]
        }
    }

    private var current: Tab { Tab(rawValue: tab) ?? .home }

    var body: some View {
        HStack(spacing: 0) {
            tabs
            Rectangle().fill(theme.line.color).frame(width: 1, height: 16).padding(.horizontal, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(Self.groups(current).enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Rectangle().fill(theme.line.color).frame(width: 1, height: 16).padding(.horizontal, 5) }
                        groupView(group)
                    }
                }
                .id(current)
                .transition(.opacity)
                .padding(.trailing, 18)
            }
            // A soft edge, so tools that don't fit read as scrolling on rather than cut off.
            .mask {
                HStack(spacing: 0) {
                    Rectangle().fill(theme.text.color)
                    LinearGradient(colors: [theme.text.color, theme.text.color.opacity(0)], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                }
            }
            Spacer(minLength: 8)
            search
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(theme.panel.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
        .animation(.easeOut(duration: 0.15), value: tab)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                let on = item == current
                Button { tab = item.rawValue } label: {
                    Text(item.rawValue)
                        .font(.dante(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? theme.accent.color : theme.text2.color)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? theme.accent.color.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var search: some View {
        Button { searching = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.dante(size: 10.5))
                Text("Search tools").font(.dante(size: 11.5))
            }
            .foregroundStyle(theme.text3.color)
            .padding(.horizontal, 8)
            .frame(width: 130, height: 22, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.card.color))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color))
        }
        .buttonStyle(.plain)
        .help("Find any PDF tool by name")
        .popover(isPresented: $searching, arrowEdge: .bottom) {
            PDFToolsPalette(tools: toolbox.all) { searching = false }
        }
    }

    private func groupView(_ group: Group) -> some View {
        HStack(spacing: 1) {
            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .tools(let ids):
                    ForEach(toolbox.tools(ids)) { RibbonSmallButton(tool: $0) }
                case .menu(let label, let symbol, let tip, let ids):
                    RibbonMenuButton(label: label, symbol: symbol, tip: tip, tools: toolbox.tools(ids))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.title)
    }
}

// MARK: Buttons

private struct RibbonSmallButton: View {
    @Environment(\.theme) private var theme
    let tool: PDFTool
    /// Tools whose icon says it all; their ScreenTip still names them.
    static let iconOnly: Set<String> = ["rotateLeft", "rotateRight", "zoomIn", "zoomOut"]
    @State private var hovering = false
    @State private var tip = false

    var body: some View {
        Button { tip = false; tool.run() } label: {
            HStack(spacing: 5) {
                Image(systemName: tool.symbol)
                    .font(.dante(size: 12))
                    .frame(width: 15)
                    .foregroundStyle(tool.isOn == true ? theme.accent.color : theme.text.color)
                if !Self.iconOnly.contains(tool.id) {
                    Text(tool.label).font(.dante(size: 11.5)).foregroundStyle(theme.text2.color).fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .ribbonBackground(hovering: hovering && tool.enabled, on: tool.isOn == true)
        }
        .buttonStyle(.plain)
        .disabled(!tool.enabled)
        .opacity(tool.enabled ? 1 : 0.4)
        .screenTip(title: tool.title, text: tool.tip, detail: tool.enabled ? tool.detail : tool.unavailable, hovering: $hovering, shows: $tip)
        .accessibilityLabel(tool.title)
    }
}

/// A small button with a chevron that drops down its tools, each with what it acts on.
private struct RibbonMenuButton: View {
    @Environment(\.theme) private var theme
    let label: String
    let symbol: String
    let tip: String
    let tools: [PDFTool]
    @State private var hovering = false
    @State private var tipShown = false
    @State private var open = false

    var body: some View {
        Button { tipShown = false; open = true } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.dante(size: 12)).frame(width: 15)
                    .foregroundStyle(tools.contains { $0.isOn == true } ? theme.accent.color : theme.text.color)
                Text(label).font(.dante(size: 11.5)).foregroundStyle(theme.text2.color).fixedSize()
                Image(systemName: "chevron.down").font(.dante(size: 7.5, weight: .bold)).foregroundStyle(theme.text3.color)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .ribbonBackground(hovering: hovering || open, on: false)
        }
        .buttonStyle(.plain)
        .screenTip(title: label, text: tip, detail: nil, hovering: $hovering, shows: $tipShown)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tools) { tool in
                    RibbonMenuRow(tool: tool) { open = false; tool.run() }
                }
            }
            .padding(6)
            .frame(width: 300)
        }
        .accessibilityLabel(label)
    }
}

private struct RibbonMenuRow: View {
    @Environment(\.theme) private var theme
    let tool: PDFTool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .font(.dante(size: 14))
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.accent.color.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(tool.title).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                        if tool.isOn == true { Image(systemName: "checkmark").font(.dante(size: 10, weight: .bold)).foregroundStyle(theme.accent.color) }
                    }
                    Text(tool.enabled ? tool.tip : (tool.unavailable ?? tool.tip))
                        .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering && tool.enabled ? theme.raised.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tool.enabled)
        .opacity(tool.enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

private extension View {
    func ribbonBackground(hovering: Bool, on: Bool) -> some View {
        modifier(RibbonBackground(hovering: hovering, on: on))
    }

    /// Word's ScreenTip: after a moment's hover, the tool's name, what it does and what it'll
    /// act on (or why it can't be used), under the button.
    func screenTip(title: String, text: String, detail: String?, hovering: Binding<Bool>, shows: Binding<Bool>) -> some View {
        modifier(ScreenTip(title: title, text: text, detail: detail, hovering: hovering, shows: shows))
    }
}

private struct RibbonBackground: ViewModifier {
    @Environment(\.theme) private var theme
    let hovering: Bool
    let on: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? theme.accent.color.opacity(0.12) : hovering ? theme.raised.color : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? theme.accent.color.opacity(0.35) : .clear))
            .contentShape(Rectangle())
    }
}

private struct ScreenTip: ViewModifier {
    @Environment(\.theme) private var theme
    let title: String
    let text: String
    let detail: String?
    @Binding var hovering: Bool
    @Binding var shows: Bool

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0; if !$0 { shows = false } }
            .task(id: hovering) {
                guard hovering else { return }
                try? await Task.sleep(for: .milliseconds(700))
                if hovering, !Task.isCancelled { shows = true }
            }
            .popover(isPresented: $shows, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color)
                    Text(text).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                    }
                }
                .padding(12)
                .frame(width: 250, alignment: .leading)
            }
    }
}

// MARK: Search tools

/// Every tool by name, filtered as you type; Return runs the first.
struct PDFToolsPalette: View {
    @Environment(\.theme) private var theme
    let tools: [PDFTool]
    let close: () -> Void
    @State private var filter = ""

    private var shown: [PDFTool] {
        let words = filter.lowercased().split(separator: " ")
        return tools.filter { tool in words.allSatisfy { (tool.title + " " + tool.label + " " + tool.detail + " " + tool.tip).lowercased().contains($0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("What do you want to do?", text: $filter)
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
                        .help(tool.enabled ? tool.tip : (tool.unavailable ?? tool.tip))
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 360)
        }
        .frame(width: 380)
    }

    private func run(_ tool: PDFTool) {
        close()
        tool.run()
    }
}
