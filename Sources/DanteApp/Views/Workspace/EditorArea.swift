import DanteEditor
import DanteKit
import SwiftUI

/// Tabs, a path bar and the editor for the active file.
struct EditorArea: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore
    let session: Session
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.documents.isEmpty {
                TabBar(session: session, workspace: workspace)
            }
            if let document = workspace.activeDocument {
                PathBar(document: document, root: workspace.url)
                if session.conflicts.contains(document.url) {
                    ConflictBar(session: session, document: document)
                }
                DocumentEditor(document: document, theme: theme, fontSize: themeStore.editorFontSize) { position in
                    session.cursor = position
                }
                .id(document.id)
            } else {
                EmptyEditor(hasTabs: !workspace.documents.isEmpty)
            }
        }
        .background(theme.codeBackground.color)
    }
}

private struct DocumentEditor: View {
    @Bindable var document: EditorDocument
    let theme: Theme
    let fontSize: Double
    let onCursorChange: (CursorPosition) -> Void

    var body: some View {
        CodeEditorView(
            text: $document.text,
            language: document.language,
            theme: theme,
            fontSize: fontSize,
            onCursorChange: onCursorChange
        )
    }
}

private struct TabBar: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(workspace.documents) { document in
                    TabItem(
                        document: document,
                        isActive: document.id == workspace.activeDocumentID,
                        select: { workspace.activeDocumentID = document.id },
                        close: { session.close(document) }
                    )
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: 36)
        .background(theme.panel.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }
}

private struct TabItem: View {
    @Environment(\.theme) private var theme
    let document: EditorDocument
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(document.name)
                .font(.system(size: 12.5))
                .foregroundStyle(isActive ? theme.text.color : theme.text3.color)
                .lineLimit(1)
            ZStack {
                if hovering || (isActive && !document.isDirty) {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.text3.color)
                    .accessibilityLabel("Close \(document.name)")
                } else if document.isDirty {
                    StatusDot(color: theme.text2.color, size: 7)
                        .accessibilityLabel("Unsaved changes")
                }
            }
            .frame(width: 16, height: 16)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(isActive ? theme.codeBackground.color : .clear)
        .overlay(alignment: .top) {
            if isActive { Rectangle().fill(theme.accent.color).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(theme.line.color).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(document.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

private struct PathBar: View {
    @Environment(\.theme) private var theme
    let document: EditorDocument
    let root: URL

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(theme.text3.color)
                }
                Text(part)
                    .foregroundStyle(index == components.count - 1 ? theme.text2.color : theme.text3.color)
            }
            Spacer()
            Text(document.language.displayName)
                .foregroundStyle(theme.text3.color)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(theme.codeBackground.color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }

    private var components: [String] {
        let rootPath = root.standardizedFileURL.path
        let path = document.url.standardizedFileURL.path
        let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : document.name
        return relative.split(separator: "/").map(String.init)
    }
}

private struct EmptyEditor: View {
    @Environment(\.theme) private var theme
    let hasTabs: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.text3.color)
            Text("Open a file from the explorer")
                .font(.system(size: 14))
                .foregroundStyle(theme.text2.color)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                shortcut("Open folder", "⌘O")
                shortcut("Save", "⌘S")
                shortcut("Toggle terminal", "⌃`")
                shortcut("Next theme", "⌥⌘T")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.codeBackground.color)
    }

    private func shortcut(_ label: String, _ keys: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 12.5)).foregroundStyle(theme.text3.color)
            Text(keys).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text2.color)
        }
    }
}

/// Shown when the open file changed on disk while it had unsaved edits.
private struct ConflictBar: View {
    @Environment(\.theme) private var theme
    let session: Session
    let document: EditorDocument

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(theme.amber.color)
            Text("\(document.name) changed on disk. Your unsaved edits are still here.")
                .font(.system(size: 12))
                .foregroundStyle(theme.text.color)
            Spacer()
            Button("Keep mine") { session.resolveConflict(document, reload: false) }
                .buttonStyle(DanteButtonStyle())
            Button("Reload from disk") { session.resolveConflict(document, reload: true) }
                .buttonStyle(DanteButtonStyle(primary: true))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.amber.opacity(0.1).color)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }
}
