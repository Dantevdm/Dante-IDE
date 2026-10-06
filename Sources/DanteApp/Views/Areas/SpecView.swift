import DanteKit
import SwiftUI

/// Spec: the `.dante` folder itself. Its files on the left, the selected one in the
/// middle, and on the right whether it holds together and what Claude reads from it.
struct SpecView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var selectedPath: String?
    @State private var text: String?

    private var specFiles: [String] {
        workspace.files.filter { $0.hasPrefix(".dante/") }.sorted { a, b in
            // project.yaml first, then folders after loose files, then by name.
            if a == ".dante/project.yaml" { return true }
            if b == ".dante/project.yaml" { return false }
            let depthA = a.split(separator: "/").count, depthB = b.split(separator: "/").count
            if depthA != depthB { return depthA < depthB }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    private var selected: String? {
        if let selectedPath, specFiles.contains(selectedPath) { return selectedPath }
        return specFiles.first
    }

    var body: some View {
        HStack(spacing: 0) {
            SpecTree(files: specFiles, selected: selected) { selectedPath = $0 }
                .frame(width: 236)
            Rectangle().fill(theme.line.color).frame(width: 1)
            if workspace.lifecycle.hasSpec || !specFiles.isEmpty {
                AreaPage(
                    eyebrow: "Project spec",
                    title: "The .dante folder",
                    subtitle: "Plain text in the repo, reviewed like code. It defines the lifecycle, what “done” means in each phase and what Claude may propose. Claude reads it at the start of every conversation."
                ) {
                    Button {
                        session.askClaude("Check the .dante folder against the code and git history: is project.yaml accurate, are phase definitions missing, are tasks stale? Propose fixes as diffs.")
                    } label: {
                        Label("Review with Claude", systemImage: "sparkle")
                    }
                    .buttonStyle(DanteButtonStyle())
                } content: {
                    HStack(alignment: .top, spacing: 16) {
                        if let selected {
                            FileCard(session: session, workspace: workspace, path: selected, text: text)
                                .frame(minWidth: 380)
                        }
                        VStack(spacing: 16) {
                            ValidationCard(issues: SpecCheck.run(workspace)) { path in
                                if specFiles.contains(path) { selectedPath = path }
                            }
                            ClaudeGetsCard(sections: ClaudeBrief.sections(for: workspace))
                        }
                        .frame(width: 340)
                    }
                }
            } else {
                AreaPage(eyebrow: "Project spec", title: "No .dante folder yet", subtitle: nil) {
                    EmptyState(
                        symbol: "book.closed",
                        title: "Give the project a spec",
                        message: "A .dante/project.yaml names the project, sets its lifecycle phase and says what Claude may change. Plan can create a starter, or Claude can draft one from the README, code and history."
                    ) {
                        Button("Draft with Claude") {
                            session.askClaude("Set this project up for Dante: draft .dante/project.yaml (name, summary, lifecycle.current, and claude: propose/flag/never rules) from the README, docs, code and git history. Keep it short.")
                        }
                        .buttonStyle(DanteButtonStyle(primary: true))
                        Button("Open Plan") { session.area = .plan }
                            .buttonStyle(DanteButtonStyle())
                    }
                }
            }
        }
        .background(theme.ground.color)
        .task(id: "\(selected ?? "")#\(workspace.revision)") {
            text = selected.flatMap { try? String(contentsOf: workspace.url.appending(path: $0), encoding: .utf8) }
        }
    }
}

private struct SpecTree: View {
    @Environment(\.theme) private var theme
    let files: [String]
    let selected: String?
    let select: (String) -> Void

    private struct Entry: Identifiable {
        let path: String
        let name: String
        let depth: Int
        let isFolder: Bool
        var id: String { path + (isFolder ? "/" : "") }
    }

    /// Files with their folders interleaved, as a flat outline.
    private var entries: [Entry] {
        var result: [Entry] = []
        var folders = Set<String>()
        for file in files {
            let parts = file.split(separator: "/").map(String.init)
            for depth in 1..<max(1, parts.count - 1) {
                let folder = parts[0...depth].joined(separator: "/")
                if folders.insert(folder).inserted {
                    result.append(Entry(path: folder, name: parts[depth] + "/", depth: depth - 1, isFolder: true))
                }
            }
            result.append(Entry(path: file, name: parts.last ?? file, depth: parts.count - 2, isFolder: false))
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                Eyebrow("In the repo").padding(.horizontal, 12).padding(.bottom, 6)
                Label(".dante/", systemImage: "folder")
                    .font(.dante(size: 12, design: .monospaced))
                    .foregroundStyle(theme.text2.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                ForEach(entries) { entry in
                    if entry.isFolder {
                        Label(entry.name, systemImage: "folder")
                            .font(.dante(size: 12, design: .monospaced))
                            .foregroundStyle(theme.text2.color)
                            .padding(.leading, 12 + CGFloat(entry.depth + 1) * 14)
                            .padding(.vertical, 5)
                    } else {
                        Button { select(entry.path) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "doc").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                                Text(entry.name).font(.dante(size: 12, design: .monospaced)).lineLimit(1)
                                Spacer(minLength: 4)
                            }
                            .foregroundStyle(entry.path == selected ? theme.text.color : theme.text2.color)
                            .padding(.leading, 12 + CGFloat(entry.depth + 1) * 14)
                            .padding(.trailing, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(entry.path == selected ? theme.accentTint.color : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if files.isEmpty {
                    Text("Nothing here yet.").font(.dante(size: 12)).foregroundStyle(theme.text3.color).padding(12)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 8)
        }
        .background(theme.panel.color)
    }
}

private struct FileCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let path: String
    let text: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                Text(path).font(.dante(size: 12.5, design: .monospaced)).foregroundStyle(theme.text.color)
                Spacer()
                LinkButton("Edit") {
                    session.open(file: workspace.url.appending(path: path))
                    session.area = .code
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(theme.panel.color)
            Rectangle().fill(theme.line.color).frame(height: 1)
            if let text {
                SourceView(text: text, language: Language(url: URL(filePath: path)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Couldn’t read this file.").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color).padding(14)
            }
        }
        .background(theme.codeBackground.color)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
    }
}

private struct ValidationCard: View {
    @Environment(\.theme) private var theme
    let issues: [SpecCheck.Issue]
    let open: (String) -> Void

    var body: some View {
        Card("Checks") {
            if issues.isEmpty {
                Label("All good", systemImage: "checkmark")
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.green.color)
            } else {
                Text("\(issues.count) to look at").font(.dante(size: 12)).foregroundStyle(theme.amber.color)
            }
        } content: {
            if issues.isEmpty {
                Text("project.yaml parses, the current phase is in the lifecycle, and every task points at a real phase and spec.")
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(issues) { issue in
                Button { open(issue.path) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.dante(size: 11))
                            .foregroundStyle(issue.severity == .error ? theme.red.color : theme.amber.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.message).font(.dante(size: 12)).foregroundStyle(theme.text.color).fixedSize(horizontal: false, vertical: true)
                            Text(issue.path).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The system prompt Claude starts from, part by part, with rough sizes.
private struct ClaudeGetsCard: View {
    @Environment(\.theme) private var theme
    let sections: [ClaudeBrief.Section]
    @State private var expanded: String?

    private func barWidth(_ section: ClaudeBrief.Section, total: Int, in width: CGFloat) -> CGFloat {
        let available = width - CGFloat(sections.count - 1) * 2
        let share = CGFloat(section.estimatedTokens) / CGFloat(max(total, 1))
        return max(2, available * share)
    }

    var body: some View {
        let total = sections.reduce(0) { $0 + $1.estimatedTokens }
        let colors = [theme.accent.color, theme.green.color, theme.amber.color, theme.syntax.keyword.color, theme.syntax.type.color]
        Card("What Claude gets") {
            Text("≈ \(total) tokens").font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
        } content: {
            Text("Dante puts this in front of every conversation, then adds the open file and cursor line with each message.")
                .font(.dante(size: 12))
                .foregroundStyle(theme.text2.color)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    VStack(alignment: .leading, spacing: 6) {
                        Rectangle().fill(theme.line.color).frame(height: 1)
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { expanded = expanded == section.id ? nil : section.id }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)").font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).frame(width: 14)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.title).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                                    Text(section.source).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                                }
                                Spacer()
                                Text("\(section.estimatedTokens)").font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text2.color)
                                Image(systemName: expanded == section.id ? "chevron.up" : "chevron.down")
                                    .font(.dante(size: 9, weight: .semibold))
                                    .foregroundStyle(theme.text3.color)
                            }
                            .padding(.top, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if expanded == section.id {
                            Text(MarkdownText.attributed(section.text, theme: theme))
                                .font(.dante(size: 12))
                                .foregroundStyle(theme.text2.color)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 24)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        let color: Color = colors[index % colors.count]
                        color.frame(width: barWidth(section, total: total, in: proxy.size.width))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
        }
    }
}
