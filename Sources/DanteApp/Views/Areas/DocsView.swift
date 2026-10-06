import DanteEditor
import DanteKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Docs: the project's markdown as documents to read, not files to edit. An outline on
/// the left, the document in the middle, and what links to it on the right. Paper
/// theme sets it in a serif. PDFs, images and Word files under docs/ and .dante/ sit
/// alongside, for Claude to read or write up; dropping files here copies them into docs/.
struct DocsView: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore
    let session: Session
    let workspace: Workspace

    @State private var markdown: MarkdownDocument?
    @State private var loadError: String?
    @State private var dropTargeted = false
    /// Reading width: a comfortable column, or the whole window.
    @AppStorage("docsWide") private var wide = false
    /// Read the rendered doc, edit its markdown, or both side by side.
    @State private var mode: Mode = .preview
    /// The doc's editor document while it's being edited. The same one the Code area
    /// shows, so unsaved changes and ⌘S are shared.
    @State private var editing: EditorDocument?
    /// The heading above the cursor, which the side-by-side preview keeps in view.
    @State private var cursorAnchor: String?

    enum Mode: String, CaseIterable, Identifiable {
        case preview, edit, split
        var id: Self { self }
        var title: String {
            switch self {
            case .preview: "Preview"
            case .edit: "Markdown"
            case .split: "Side by Side"
            }
        }
        var symbol: String {
            switch self {
            case .preview: "doc.richtext"
            case .edit: "chevron.left.forwardslash.chevron.right"
            case .split: "rectangle.split.2x1"
            }
        }
    }

    private var library: DocLibrary { DocLibrary(paths: workspace.files) }

    private var selected: DocLibrary.Doc? { library.doc(preferring: session.docPath) }

    var body: some View {
        HStack(spacing: 0) {
            DocsSidebar(session: session, library: library, selected: selected, markdown: markdown, addFiles: pickFiles)
                .frame(width: 236)
            Rectangle().fill(theme.line.color).frame(width: 1)
            if let selected {
                VStack(spacing: 0) {
                    toolbar(for: selected)
                    Rectangle().fill(theme.line.color).frame(height: 1)
                    if selected.kind != .markdown {
                        FilePreview(url: workspace.url.appending(path: selected.path), kind: selected.kind)
                    } else {
                        switch mode {
                        case .preview:
                            HStack(spacing: 0) {
                                preview(selected)
                                Rectangle().fill(theme.line.color).frame(width: 1)
                                LinkedPanel(session: session, workspace: workspace, doc: selected, markdown: markdown)
                                    .frame(width: 250)
                            }
                        case .edit:
                            sourceEditor
                        case .split:
                            HSplitView {
                                sourceEditor.frame(minWidth: 280, maxWidth: .infinity)
                                preview(selected).frame(minWidth: 280, maxWidth: .infinity)
                            }
                        }
                    }
                }
                .environment(\.openURL, OpenURLAction { url in open(url, from: selected) })
            } else {
                EmptyState(
                    symbol: "doc.text",
                    title: "No docs yet",
                    message: "Markdown files in the repo show up here: the README, .dante specs and decisions, and anything under docs/. Drop PDFs, images or Word files here to add them to docs/."
                ) {
                    Button("Add files…", action: pickFiles).buttonStyle(DanteButtonStyle())
                    Button("Ask Claude to draft a README") {
                        session.askClaude("Draft a README.md for this project from the code, the .dante folder and git history. Keep it short and accurate.")
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(theme.ground.color)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.accent.color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(theme.accentTint.opacity(0.4).color)
                    .overlay {
                        Label("Drop to add to docs/", systemImage: "tray.and.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.accent.color)
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in importFiles([url]) }
                }
            }
            return true
        }
        .task(id: "\(selected?.path ?? "")#\(workspace.revision)") { load() }
        .task(id: "\(selected?.path ?? "")#\(mode)") {
            startEditing()
            load()
        }
        // Re-render while typing, once the keys pause.
        .task(id: editing?.text) {
            guard let editing, mode != .preview else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            markdown = MarkdownDocument(editing.text)
            loadError = nil
        }
    }

    private func preview(_ doc: DocLibrary.Doc) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if let markdown {
                        DocumentBody(document: markdown, path: doc.path, root: workspace.url)
                    } else if let loadError {
                        Text(loadError).foregroundStyle(theme.red.color)
                    }
                }
                .padding(.horizontal, mode == .split ? 32 : 44)
                .padding(.vertical, mode == .split ? 28 : 40)
                .frame(maxWidth: wide || mode == .split ? .infinity : 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.docAnchor) { _, anchor in
                guard let anchor else { return }
                withAnimation(.snappy) { proxy.scrollTo(anchor, anchor: .top) }
                session.docAnchor = nil
            }
            .onChange(of: cursorAnchor) { _, anchor in
                guard mode == .split, let anchor else { return }
                withAnimation(.snappy) { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private var sourceEditor: some View {
        if let editing {
            CodeEditorView(
                text: Binding(get: { editing.text }, set: { editing.text = $0 }),
                language: editing.language,
                theme: theme,
                fontSize: themeStore.editorFontSize,
                onCursorChange: { position in
                    let anchor = MarkdownDocument.anchor(atLine: position.line, in: editing.text)
                    if anchor != cursorAnchor { cursorAnchor = anchor }
                }
            )
            .id(editing.id)
            .background(theme.ground.color)
        } else {
            Color.clear
        }
    }

    /// The doc's tab in the editor, if it has one.
    private func openDocument(for doc: DocLibrary.Doc) -> EditorDocument? {
        let url = workspace.url.appending(path: doc.path).standardizedFileURL
        return workspace.documents.first { $0.url.standardizedFileURL == url }
    }

    /// Opens the doc as an editor document for the Markdown and Side by Side modes.
    private func startEditing() {
        guard mode != .preview, let selected, selected.kind == .markdown else {
            editing = nil
            cursorAnchor = nil
            return
        }
        let url = workspace.url.appending(path: selected.path)
        do {
            editing = try workspace.open(url)
        } catch {
            session.errorMessage = error.localizedDescription
            mode = .preview
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to add to docs/: specs, PDFs, screenshots, diagrams"
        panel.prompt = "Add to Docs"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Copies files into docs/ (files already in the project are just shown) and opens the last one.
    private func importFiles(_ urls: [URL]) {
        var existing = Set(workspace.files)
        var last: String?
        let root = workspace.url.standardizedFileURL.path + "/"
        for url in urls {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(root) {
                let relative = String(path.dropFirst(root.count))
                if DocLibrary.isDoc(relative) { last = relative; continue }
            }
            let destination = DocLibrary.importPath(for: url.lastPathComponent, existing: existing)
            do {
                try FileManager.default.createDirectory(at: workspace.url.appending(path: DocLibrary.importFolder), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: workspace.url.appending(path: destination))
                existing.insert(destination)
                if DocLibrary.isDoc(destination) { last = destination }
            } catch {
                session.errorMessage = "Couldn’t add \(url.lastPathComponent) to docs/: \(error.localizedDescription)"
            }
        }
        workspace.refreshFileIndex()
        if let last { session.showDoc(last) }
    }

    private func toolbar(for doc: DocLibrary.Doc) -> some View {
        HStack(spacing: 8) {
            let parts = doc.path.split(separator: "/").map(String.init)
            Text("Docs").foregroundStyle(theme.text3.color)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.text3.color)
                Text(part).foregroundStyle(index == parts.count - 1 ? theme.text.color : theme.text3.color)
            }
            Spacer()
            if doc.kind == .markdown {
                if mode == .preview {
                    Button {
                        wide.toggle()
                    } label: {
                        Label(wide ? "Narrow" : "Wide", systemImage: wide ? "arrow.right.and.line.vertical.and.arrow.left" : "arrow.left.and.line.vertical.and.arrow.right")
                    }
                    .buttonStyle(DanteButtonStyle())
                    .help(wide ? "Read in a comfortable column" : "Use the whole width of the window")
                }
                Menu {
                    Button("Export as PDF…") { session.exportDoc() }
                    Button("Print…") { session.exportDoc(printing: true) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Export or print this doc, set in the Paper theme")
                Button {
                    session.askClaude("Read \(doc.path) and tell me what's out of date or missing compared with the code. Don't change anything yet.")
                } label: {
                    Label("Check against the code", systemImage: "sparkle")
                }
                .buttonStyle(DanteButtonStyle())
                if let open = openDocument(for: doc), open.isDirty {
                    Button {
                        session.save(open)
                    } label: {
                        Label("Save", systemImage: "circle.fill").labelStyle(DirtyLabelStyle())
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .help("Save \(doc.path) (⌘S)")
                }
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Read the doc, edit its markdown, or edit with a live preview beside it")
            } else {
                let url = workspace.url.appending(path: doc.path)
                Button {
                    Task { await session.attach([url]) }
                } label: {
                    Label("Ask Claude about this", systemImage: "paperclip")
                }
                .buttonStyle(DanteButtonStyle())
                .help("Attaches the file to your next message to Claude")
                Button {
                    let target = ((doc.path as NSString).deletingPathExtension) + ".md"
                    session.askClaude("Write up the attached \(doc.path) as a markdown doc at \(target), so it can be read in Docs and used as a spec. Keep its structure and every requirement, decision and number; turn diagrams into mermaid code blocks where you can, and tables into markdown tables. Link the original near the top. Then tell me anything in it the code doesn't do yet.", about: url)
                } label: {
                    Label("Write it up as markdown", systemImage: "sparkle")
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(DanteButtonStyle())
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 20)
        .frame(height: 46)
        .background(theme.panel.color)
    }

    private func load() {
        guard let selected, selected.kind == .markdown else { markdown = nil; loadError = nil; return }
        let url = workspace.url.appending(path: selected.path)
        // Unsaved edits, here or in the Code area, are what the preview shows.
        if let open = openDocument(for: selected), open.isDirty {
            markdown = MarkdownDocument(open.text)
            loadError = nil
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            markdown = MarkdownDocument(text)
            loadError = nil
        } catch {
            markdown = nil
            loadError = "Couldn’t read \(selected.path): \(error.localizedDescription)"
        }
    }

    /// Relative links to other docs open here; files open in the editor; the rest go to the browser.
    private func open(_ url: URL, from doc: DocLibrary.Doc) -> OpenURLAction.Result {
        if url.scheme != nil { return .systemAction }
        let raw = url.relativeString
        if raw.hasPrefix("#") {
            session.docAnchor = String(raw.dropFirst())
            return .handled
        }
        let base = (doc.path as NSString).deletingLastPathComponent
        let target = (((base as NSString).appendingPathComponent(raw.components(separatedBy: "#")[0])) as NSString).standardizingPath
        if library.all.contains(where: { $0.path == target }) {
            session.showDoc(target)
        } else if workspace.files.contains(target) {
            session.open(file: workspace.url.appending(path: target))
            session.area = .code
        }
        return .handled
    }
}

/// A Save button's dot: the same "unsaved" mark the editor tabs use.
private struct DirtyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}
