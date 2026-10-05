import AppKit
import DanteKit
import SwiftUI

/// The file tree. Folders load their contents the first time they're opened.
struct ExplorerView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Explorer")
                Spacer()
                IconButton(symbol: "arrow.clockwise", label: "Refresh", size: 11) { refresh(workspace.root) }
                IconButton(symbol: "rectangle.compress.vertical", label: "Collapse all", size: 11) { collapse(workspace.root) }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 38)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows(), id: \.node.id) { row in
                        FileRow(
                            node: row.node,
                            depth: row.depth,
                            isActive: row.node.url == workspace.activeDocument?.url,
                            isOpen: workspace.documents.contains { $0.url == row.node.url }
                        ) {
                            if row.node.isDirectory {
                                row.node.toggle()
                            } else {
                                session.open(file: row.node.url)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
        }
        .background(theme.panel.color)
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

private struct FileRow: View {
    @Environment(\.theme) private var theme
    let node: FileNode
    let depth: Int
    let isActive: Bool
    let isOpen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Group {
                    if node.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                            .animation(.easeOut(duration: 0.12), value: node.isExpanded)
                    }
                }
                .frame(width: 10)
                .foregroundStyle(theme.text3.color)

                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(node.isDirectory ? theme.accent.color.opacity(0.8) : theme.text3.color)
                    .frame(width: 16)
                Text(node.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isActive ? theme.text.color : (node.name.hasPrefix(".") ? theme.text3.color : theme.text2.color))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(8 + depth * 14))
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? theme.accentTint.color : (hovering ? theme.raised.color : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
        }
        .accessibilityLabel(node.isDirectory ? "\(node.name), folder" : node.name)
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
