import DanteKit
import SwiftUI

/// Every language server's errors and warnings across the project, in the sidebar.
struct ProblemsPanel: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @AppStorage("problemsShowHints") private var showsHints = false
    @State private var collapsed: Set<String> = []

    var body: some View {
        let files = Problems.files(session.languages?.allDiagnostics ?? [:], root: workspace.url, includeHints: showsHints)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                summary(files)
                Spacer()
                Toggle("Hints", isOn: $showsHints)
                    .toggleStyle(.checkbox)
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.text2.color)
                    .help("Also show information and hints")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if files.isEmpty {
                Text("Problems appear here as language servers check the files you open. Servers for Swift, TypeScript and others start with the first file of their language.")
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.text3.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            ProblemFileHeader(file: file, isCollapsed: collapsed.contains(file.path), fix: { session.fixWithClaude(file) }) {
                                if collapsed.contains(file.path) { collapsed.remove(file.path) } else { collapsed.insert(file.path) }
                            }
                            if !collapsed.contains(file.path) {
                                ForEach(Array(file.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                                    ProblemRow(diagnostic: diagnostic) { session.reveal(diagnostic, in: file.url) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func summary(_ files: [ProblemFile]) -> some View {
        let errors = files.reduce(0) { $0 + $1.errors }
        let warnings = files.reduce(0) { $0 + $1.warnings }
        return Text(errors + warnings == 0 ? "No errors or warnings" :
                        "\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s") in \(files.count) file\(files.count == 1 ? "" : "s")")
            .font(.dante(size: 11.5))
            .foregroundStyle(theme.text3.color)
    }
}

private struct ProblemFileHeader: View {
    @Environment(\.theme) private var theme
    let file: ProblemFile
    let isCollapsed: Bool
    let fix: () -> Void
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.dante(size: 8.5, weight: .semibold))
                    .foregroundStyle(theme.text3.color)
                    .frame(width: 10)
                Text((file.path as NSString).lastPathComponent)
                    .font(.dante(size: 12.5, weight: .medium))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text((file.path as NSString).deletingLastPathComponent)
                    .font(.dante(size: 11))
                    .foregroundStyle(theme.text3.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                Text("\(file.diagnostics.count)")
                    .font(.dante(size: 10.5, weight: .medium))
                    .foregroundStyle(file.errors > 0 ? theme.red.color : theme.text2.color)
                    .padding(.horizontal, 5)
                    .background(theme.raised.color, in: Capsule())
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.path)
        .overlay(alignment: .trailing) {
            IconButton(symbol: "sparkle", label: "Ask Claude to fix \((file.path as NSString).lastPathComponent)", size: 10, action: fix)
                .background(theme.panel.color, in: RoundedRectangle(cornerRadius: 6))
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}

private struct ProblemRow: View {
    @Environment(\.theme) private var theme
    let diagnostic: LSPDiagnostic
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: icon)
                    .font(.dante(size: 10))
                    .foregroundStyle(color)
                    .frame(width: 14)
                Text(diagnostic.message)
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text("\(diagnostic.range.start.line + 1)")
                    .font(.dante(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.text3.color)
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? theme.raised.color : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Line \(diagnostic.range.start.line + 1)")
    }

    private var icon: String {
        switch diagnostic.severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information, .hint: "info.circle"
        }
    }

    private var color: Color {
        switch diagnostic.severity {
        case .error: theme.red.color
        case .warning: theme.amber.color
        case .information, .hint: theme.text3.color
        }
    }
}
