import AppKit
import DanteKit
import SwiftUI
import UniformTypeIdentifiers

/// The file tree. Folders load their contents the first time they're opened.
struct ExplorerView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    /// Selected rows (⌘- and ⇧-click for more); the last one clicked is where the header's
    /// new file and folder buttons put things.
    @State private var selection = ExplorerSelection()
    /// The tree has keyboard focus, so ⌘C, ⌘V and ⌘⌫ act on files rather than text.
    @FocusState private var treeFocused: Bool
    /// A name being typed for a new item or a rename.
    @State private var editing: Edit?
    @State private var rootTargeted = false

    enum Edit: Equatable {
        case newFile(in: URL)
        case newFolder(in: URL)
        case rename(URL)

        var folder: URL {
            switch self {
            case .newFile(let folder), .newFolder(let folder): folder
            case .rename(let url): url.deletingLastPathComponent()
            }
        }

        /// The folder a new file or folder is being named in; nil for a rename.
        var newItemFolder: String? {
            if case .rename = self { return nil }
            return folder.standardizedFileURL.path
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                tab("Explorer", .files)
                tab("Search", .search)
                tab("Changes", .changes, count: session.git.changeCount)
                tab("Problems", .problems, count: problemCount.total, alert: problemCount.errors > 0)
                Spacer()
                if session.sidebar == .files {
                    IconButton(symbol: "doc.badge.plus", label: "New file", size: 11) { startNew(folder: false) }
                    IconButton(symbol: "folder.badge.plus", label: "New folder", size: 11) { startNew(folder: true) }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(height: 38)

            if session.sidebar == .search {
                SearchPanel(session: session, workspace: workspace)
            } else if session.sidebar == .changes {
                ChangesPanel(session: session, workspace: workspace)
            } else if session.sidebar == .problems {
                ProblemsPanel(session: session, workspace: workspace)
            } else {
                tree
            }
        }
        .background(theme.panel.color)
    }

    /// Errors and warnings across the project, for the Problems tab's badge.
    private var problemCount: (total: Int, errors: Int) {
        let files = Problems.files(session.languages?.allDiagnostics ?? [:], root: workspace.url)
        return (files.reduce(0) { $0 + $1.errors + $1.warnings }, files.reduce(0) { $0 + $1.errors })
    }

    private func tab(_ title: String, _ sidebar: Session.Sidebar, count: Int = 0, alert: Bool = false) -> some View {
        let selected = session.sidebar == sidebar
        let symbol = switch sidebar {
        case .files: "folder"
        case .search: "magnifyingglass"
        case .changes: "arrow.triangle.branch"
        case .problems: "exclamationmark.triangle"
        }
        return Button { session.sidebar = sidebar } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.dante(size: 11.5, weight: .medium))
                if selected {
                    Text(title.uppercased())
                        .font(.dante(size: 10.5, weight: .medium))
                        .tracking(0.9)
                        .fixedSize()
                }
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.dante(size: 9.5, weight: .bold))
                        .fixedSize()
                        .foregroundStyle(theme.onAccent.color)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 14)
                        .background(Capsule().fill(alert ? theme.red.color : theme.accent.color))
                }
            }
            .foregroundStyle(selected ? theme.text.color : theme.text3.color)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? theme.raised.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sidebar == .search ? "Find in Project (⇧⌘F)" : sidebar == .changes ? "Source Control (⌃⇧G)" : sidebar == .problems ? "Problems (⇧⌘M)" : "Files")
        .accessibilityLabel(count > 0 ? "\(title), \(count) \(sidebar == .problems ? "problems" : "changes")" : title)
        .accessibilityAddTraits(session.sidebar == sidebar ? .isSelected : [])
    }

    private var tree: some View {
        let changes = gitMarks
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let editing, editing.newItemFolder == workspace.url.standardizedFileURL.path {
                    nameField(editing, depth: 0)
                }
                ForEach(rows(), id: \.node.id) { row in
                    if editing == .rename(row.node.url) {
                        nameField(.rename(row.node.url), depth: row.depth)
                    } else {
                        FileRow(
                            node: row.node,
                            depth: row.depth,
                            isActive: row.node.url == workspace.activeDocument?.url,
                            isFocused: selection.contains(row.node.url),
                            mark: changes[row.node.url.standardizedFileURL.path],
                            action: { click(row.node) },
                            menu: { menu(for: row.node) },
                            drag: { dragProvider(for: row.node) },
                            drop: { urls in drop(urls, into: row.node.isDirectory ? row.node.url : row.node.url.deletingLastPathComponent()) }
                        )
                    }
                    if row.node.isExpanded, let editing, editing.newItemFolder == row.node.url.standardizedFileURL.path {
                        nameField(editing, depth: row.depth + 1)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        // Empty space below the tree is the project folder: drop there, or right-click it.
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $rootTargeted) { providers in
            Self.loadFileURLs(providers) { drop($0, into: workspace.url) }
            return true
        }
        .background(rootTargeted ? theme.accentTint.opacity(0.5).color : .clear)
        .focusable()
        .focused($treeFocused)
        .focusEffectDisabled()
        .onCopyCommand { selection.topLevel.map { NSItemProvider(object: $0 as NSURL) } }
        .onPasteCommand(of: [.fileURL]) { providers in
            Self.loadFileURLs(providers) { session.paste($0, into: pasteFolder) }
        }
        .onDeleteCommand { session.trash(selection.topLevel) }
        .onExitCommand { selection.clear() }
        .onChange(of: workspace.revision) {
            selection.update { FileManager.default.fileExists(atPath: $0.path) }
        }
        .contextMenu {
            Button("New File…") { editing = .newFile(in: workspace.url) }
            Button("New Folder…") { editing = .newFolder(in: workspace.url) }
            pasteButton(into: workspace.url)
            Divider()
            Button("Refresh") { refresh(workspace.root) }
            Button("Collapse All") { collapse(workspace.root) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.url]) }
        }
    }

    @ViewBuilder
    private func menu(for node: FileNode) -> some View {
        let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        // Right-clicking inside the selection acts on all of it, as in Finder.
        let targets = selection.count > 1 && selection.contains(node.url) ? selection.topLevel : [node.url]
        let several = targets.count > 1
        Button("New File…") { begin(.newFile(in: folder)) }
        Button("New Folder…") { begin(.newFolder(in: folder)) }
        Divider()
        if !several {
            Button("Rename…") { editing = .rename(node.url) }
        }
        Button(several ? "Duplicate \(targets.count) Items" : "Duplicate") { session.duplicate(targets) }
        Button(several ? "Move \(targets.count) Items to Trash" : "Move to Trash") { session.trash(targets) }
        Divider()
        Button(several ? "Copy \(targets.count) Items" : "Copy") { session.copyToPasteboard(targets) }
        pasteButton(into: folder)
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        Button(several ? "Copy Paths" : "Copy Path") { copy(targets.map(\.path).joined(separator: "\n")) }
        Button(several ? "Copy Relative Paths" : "Copy Relative Path") { copy(targets.map(relativePath).joined(separator: "\n")) }
        let files = targets.filter { !$0.hasDirectoryPath && !(workspace.root.node(for: $0)?.isDirectory ?? false) }
        if !files.isEmpty {
            Divider()
            if files.count == 1 {
                Button("Ask Claude About This File") {
                    session.askClaude("Explain what \(relativePath(files[0])) does and how it fits into the project.", about: files[0])
                }
            } else {
                Button("Ask Claude About These Files") {
                    let list = files.map { "- \(relativePath($0))" }.joined(separator: "\n")
                    session.askClaude("Explain what these files do, how they relate to each other and how they fit into the project:\n\(list)")
                }
            }
        }
    }

    /// Paste, when the pasteboard holds files (Finder's Copy or the tree's).
    @ViewBuilder
    private func pasteButton(into folder: URL) -> some View {
        let files = Session.pasteboardFiles
        if !files.isEmpty {
            Button(files.count == 1 ? "Paste “\(files[0].lastPathComponent)”" : "Paste \(files.count) Items") {
                session.paste(files, into: folder)
            }
        }
    }

    /// A click on a row: plain opens it, ⌘ adds or removes it, ⇧ selects a run.
    private func click(_ node: FileNode) {
        treeFocused = true
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let kind: ExplorerSelection.Click = flags.contains(.command) ? .toggle : flags.contains(.shift) ? .range : .plain
        selection.click(node.url, kind, visible: rows().map(\.node.url))
        guard kind == .plain else { return }
        if node.isDirectory {
            node.toggle()
        } else {
            session.open(file: node.url)
        }
    }

    /// Where ⌘V puts files: the selected folder, or the folder of the selected file.
    private var pasteFolder: URL {
        session.newItemFolder(for: selection.anchor) ?? workspace.url
    }

    /// Dragging a selected row takes the whole selection with it.
    private func dragProvider(for node: FileNode) -> NSItemProvider {
        session.draggedFiles = selection.contains(node.url) ? selection.topLevel : [node.url]
        return NSItemProvider(object: node.url as NSURL)
    }

    private func drop(_ urls: [URL], into folder: URL) {
        var urls = urls.map(FileOperations.resolved)
        let dragged = session.draggedFiles
        if urls.count == 1, dragged.contains(where: { $0.standardizedFileURL.path == urls[0].path }) { urls = dragged }
        session.draggedFiles = []
        session.drop(urls, into: folder)
    }

    /// The file URLs in a drop or paste, read on the main actor.
    static func loadFileURLs(_ providers: [NSItemProvider], then handle: @escaping @MainActor ([URL]) -> Void) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url { urls.append(FileOperations.resolved(url)) }
            }
            if !urls.isEmpty { handle(urls) }
        }
    }

    private func nameField(_ edit: Edit, depth: Int) -> some View {
        NameField(edit: edit, depth: depth, workspace: workspace) { name in
            editing = nil
            guard let name else { return }
            switch edit {
            case .newFile(let folder): session.createFile(named: name, in: folder)
            case .newFolder(let folder): session.createFolder(named: name, in: folder)
            case .rename(let url): session.rename(url, to: name)
            }
        }
    }

    private func startNew(folder: Bool) {
        guard let target = session.newItemFolder(for: selection.anchor) else { return }
        begin(folder ? .newFolder(in: target) : .newFile(in: target))
    }

    /// Opens the folder the new item goes in, so the name field shows inside it.
    private func begin(_ edit: Edit) {
        if let node = workspace.root.node(for: edit.folder), node !== workspace.root {
            if node.children == nil { node.loadChildren() }
            node.isExpanded = true
        }
        editing = edit
    }

    /// Git's view of each changed file, and of folders that contain changes.
    private var gitMarks: [String: GitStatus.Kind] {
        guard let status = session.git.status else { return [:] }
        let root = workspace.url.standardizedFileURL.path
        var marks: [String: GitStatus.Kind] = [:]
        for change in status.changes {
            let kind: GitStatus.Kind = change.isConflicted ? .conflicted : (change.unstaged ?? change.staged ?? .modified)
            marks[root + "/" + change.path] = kind
            var folder = (change.path as NSString).deletingLastPathComponent
            while !folder.isEmpty {
                let key = root + "/" + folder
                if marks[key] == nil { marks[key] = .modified }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        return marks
    }

    private func relativePath(_ url: URL) -> String {
        let root = workspace.url.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private struct Row {
        let node: FileNode
        let depth: Int
    }

    /// The expanded part of the tree, flattened into rows.
    private func rows() -> [Row] {
        var result: [Row] = []
        func walk(_ node: FileNode, depth: Int) {
            for child in node.children ?? [] {
                result.append(Row(node: child, depth: depth))
                if child.isDirectory, child.isExpanded { walk(child, depth: depth + 1) }
            }
        }
        walk(workspace.root, depth: 0)
        return result
    }

    private func refresh(_ node: FileNode) {
        node.loadChildren()
        node.children?.filter { $0.isDirectory && $0.children != nil }.forEach(refresh)
    }

    private func collapse(_ node: FileNode) {
        node.children?.forEach { child in
            child.isExpanded = false
            collapse(child)
        }
    }
}

/// Typing a name in the tree: Return to accept, Escape to cancel. Problems with the name
/// show underneath as it's typed.
private struct NameField: View {
    @Environment(\.theme) private var theme
    let edit: ExplorerView.Edit
    let depth: Int
    let workspace: Workspace
    let done: (String?) -> Void

    @State private var name = ""
    @FocusState private var focused: Bool
    @State private var finished = false

    private var isFolder: Bool {
        switch edit {
        case .newFolder: true
        case .newFile: false
        case .rename(let url): (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
    }

    private var problem: String? {
        guard !name.isEmpty else { return nil }
        var current: URL?
        if case .rename(let url) = edit { current = url }
        let allowsSubfolders: Bool = if case .rename = edit { false } else { true }
        return FileOperations.problem(with: name, in: edit.folder, allowsSubfolders: allowsSubfolders, current: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Color.clear.frame(width: 10)
                Image(systemName: isFolder ? "folder" : FileIcon.symbol(for: URL(filePath: name.isEmpty ? "x" : name), isDirectory: false))
                    .font(.dante(size: 12))
                    .foregroundStyle(isFolder ? theme.accent.color.opacity(0.8) : theme.text3.color)
                    .frame(width: 16)
                TextField(placeholder, text: $name)
                    .textFieldStyle(.plain)
                    .font(.dante(size: 12.5))
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { finish(nil) }
                    // A pasted or injected newline means Return: names can't hold one.
                    .onChange(of: name) {
                        if name.contains(where: \.isNewline) {
                            name = name.filter { !$0.isNewline }
                            submit()
                        }
                    }
                    .accessibilityLabel(placeholder)
            }
            .padding(.leading, CGFloat(8 + depth * 14))
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(problem == nil ? theme.accent.color : theme.red.color))
            if let problem {
                Text(problem)
                    .font(.dante(size: 11))
                    .foregroundStyle(theme.red.color)
                    .padding(.leading, CGFloat(30 + depth * 14))
            }
        }
        .task {
            if case .rename(let url) = edit { name = url.lastPathComponent }
            // Take the keyboard from whatever had it (often the terminal) once the field exists.
            try? await Task.sleep(for: .milliseconds(60))
            NSApp.keyWindow?.makeFirstResponder(nil)
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            // Clicking away accepts a good name, like Finder; anything else cancels.
            if !isFocused { problem == nil && !name.isEmpty ? submit() : finish(nil) }
        }
    }

    private var placeholder: String {
        switch edit {
        case .newFile: "File name (folders/like/this.swift)"
        case .newFolder: "Folder name"
        case .rename: "New name"
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { finish(nil); return }
        guard problem == nil else { return }
        finish(trimmed)
    }

    private func finish(_ result: String?) {
        guard !finished else { return }
        finished = true
        done(result)
    }
}

private struct FileRow: View {
    @Environment(\.theme) private var theme
    let node: FileNode
    let depth: Int
    let isActive: Bool
    let isFocused: Bool
    let mark: GitStatus.Kind?
    let action: () -> Void
    let menu: () -> AnyView
    let drag: () -> NSItemProvider
    let drop: ([URL]) -> Void
    @State private var hovering = false
    @State private var targeted = false

    init(node: FileNode, depth: Int, isActive: Bool, isFocused: Bool, mark: GitStatus.Kind?, action: @escaping () -> Void,
         @ViewBuilder menu: @escaping () -> some View, drag: @escaping () -> NSItemProvider, drop: @escaping ([URL]) -> Void) {
        self.node = node
        self.depth = depth
        self.isActive = isActive
        self.isFocused = isFocused
        self.mark = mark
        self.action = action
        self.menu = { AnyView(menu()) }
        self.drag = drag
        self.drop = drop
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Group {
                    if node.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.dante(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                            .animation(.easeOut(duration: 0.12), value: node.isExpanded)
                    }
                }
                .frame(width: 10)
                .foregroundStyle(theme.text3.color)

                Image(systemName: icon)
                    .font(.dante(size: 12))
                    .foregroundStyle(node.isDirectory ? theme.accent.color.opacity(0.8) : theme.text3.color)
                    .frame(width: 16)
                Text(node.name)
                    .font(.dante(size: 12.5))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let mark {
                    if node.isDirectory {
                        Circle().fill(markColor(mark).opacity(0.7)).frame(width: 5, height: 5)
                    } else {
                        Text(mark.letter)
                            .font(.dante(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(markColor(mark))
                    }
                }
            }
            .padding(.leading, CGFloat(8 + depth * 14))
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive || targeted ? theme.accentTint.color
                          : isFocused ? theme.accentTint.opacity(0.55).color
                          : hovering ? theme.raised.color : .clear)
            )
            .overlay {
                if targeted { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.accent.color) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onDrag(drag)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { targeted }, set: { targeted = $0 && node.isDirectory })) { providers in
            ExplorerView.loadFileURLs(providers, then: drop)
            return true
        }
        .contextMenu { menu() }
        .accessibilityLabel(node.isDirectory ? "\(node.name), folder" : node.name)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private var nameColor: Color {
        if let mark, !node.isDirectory { return markColor(mark) }
        return isActive ? theme.text.color : (node.name.hasPrefix(".") ? theme.text3.color : theme.text2.color)
    }

    private func markColor(_ kind: GitStatus.Kind) -> Color {
        switch kind {
        case .added, .untracked: theme.green.color
        case .deleted, .conflicted: theme.red.color
        default: theme.amber.color
        }
    }

    private var icon: String {
        if node.isDirectory { return node.isExpanded ? "folder.fill" : "folder" }
        return FileIcon.symbol(for: node.url, isDirectory: false)
    }
}

/// The SF Symbol for a file, shared by the explorer and the command palette.
enum FileIcon {
    static func symbol(for url: URL, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        switch Language(url: url) {
        case .swift: return "swift"
        case .json, .yaml, .toml: return "curlybraces"
        case .markdown: return "doc.richtext"
        case .shell: return "terminal"
        case .dockerfile: return "shippingbox"
        case .plain: return "doc"
        default: return "doc.text"
        }
    }
}
