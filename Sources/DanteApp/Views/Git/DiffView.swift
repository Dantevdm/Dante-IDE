import DanteKit
import SwiftUI

/// One file's changes in the editor area: hunks with old and new line numbers, added lines
/// tinted green and removed ones red. Stage or unstage the file from the header.
struct DiffView: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore
    let session: Session
    let workspace: Workspace
    let target: GitModel.DiffTarget

    @State private var diff: UnifiedDiff?

    private var git: GitModel { session.git }
    private var font: Font { .dante(size: themeStore.editorFontSize, design: .monospaced) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.line.color).frame(height: 1)
            if let diff {
                if diff.isBinary {
                    message("Binary file: no text diff to show.")
                } else if diff.hunks.isEmpty {
                    message(target.staged ? "Nothing staged in this file." : "No unstaged changes in this file.")
                } else {
                    GeometryReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(diff.hunks) { hunk in
                                Text(hunk.header)
                                    .font(.dante(size: themeStore.editorFontSize - 1, design: .monospaced))
                                    .foregroundStyle(theme.accent.color)
                                    .padding(.leading, 96)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(theme.accentTint.opacity(0.5).color)
                                ForEach(hunk.lines) { line in row(line) }
                            }
                        }
                        .padding(.bottom, 20)
                        .textSelection(.enabled)
                        // Short diffs start at the top left, and tints run the full width.
                        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                    }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.codeBackground.color)
        .task(id: "\(target.change.path)#\(target.staged)#\(workspace.revision)") {
            diff = await GitRepository.diff(of: target.change, staged: target.staged, in: workspace.url)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "plusminus").foregroundStyle(theme.text3.color)
            Text(target.change.path)
                .font(.dante(size: 12.5, weight: .medium))
                .foregroundStyle(theme.text.color)
                .lineLimit(1)
                .truncationMode(.head)
            if let old = target.change.oldPath {
                Text("from \(old)").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
            }
            Text(target.staged ? "Staged" : "Working tree")
                .font(.dante(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.text2.color)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(theme.raised.color))
            if let diff, !diff.isBinary {
                Text("+\(diff.added)").font(.dante(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(theme.green.color)
                Text("−\(diff.removed)").font(.dante(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(theme.red.color)
            }
            Spacer()
            if !target.change.isConflicted {
                Button(target.staged ? "Unstage" : "Stage") {
                    Task { target.staged ? await git.unstage([target.change]) : await git.stage([target.change]) }
                }
                .buttonStyle(DanteButtonStyle())
            }
            if target.change.unstaged != .deleted || target.staged {
                Button("Open File") {
                    git.diff = nil
                    session.open(file: workspace.url.appending(path: target.change.path))
                }
                .buttonStyle(DanteButtonStyle())
            }
            IconButton(symbol: "xmark", label: "Close diff", size: 11) { git.diff = nil }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(theme.panel.color)
    }

    private func row(_ line: UnifiedDiff.Line) -> some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                .foregroundStyle(tint(line.kind) ?? theme.text3.color)
                .frame(width: 18)
            Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                .foregroundStyle(theme.syntax.plain.color)
                .fixedSize()
            Spacer(minLength: 20)
        }
        .font(font)
        .frame(minHeight: themeStore.editorFontSize + 7)
        .background(tint(line.kind)?.opacity(0.11) ?? .clear)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.dante(size: themeStore.editorFontSize - 2, design: .monospaced))
            .foregroundStyle(theme.lineNumber.color)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private func tint(_ kind: UnifiedDiff.Line.Kind) -> Color? {
        switch kind {
        case .added: theme.green.color
        case .removed: theme.red.color
        case .context: nil
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.dante(size: 13))
            .foregroundStyle(theme.text3.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
