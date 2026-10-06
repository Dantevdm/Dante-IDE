import DanteKit
import SwiftUI

struct StatusBar: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore
    let session: Session
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 16) {
            if let branch = session.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
            }
            if let current = workspace.lifecycle.currentIndex {
                HStack(spacing: 5) {
                    StatusDot(color: theme.accent.color, size: 6)
                    Text("\(workspace.lifecycle.phases[current]) phase")
                }
            }
            Spacer()
            if let document = workspace.activeDocument {
                LanguageStatus(session: session, document: document)
                BlameStatus(session: session, workspace: workspace, document: document)
                Text("Ln \(session.cursor.line), Col \(session.cursor.column)")
                Text(document.language.displayName)
                Text("UTF-8")
            }
            Text(themeStore.id.displayName)
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11.5))
        .foregroundStyle(theme.text3.color)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(theme.panel.color)
        .overlay(alignment: .top) { Rectangle().fill(theme.line.color).frame(height: 1) }
    }
}

/// Who last changed the caret's line, and the commit a click away.
private struct BlameStatus: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let document: EditorDocument
    @State private var blame: GitBlame?
    @State private var showsCommit = false

    var body: some View {
        // An HStack rather than a Group: with nothing in it, a Group has no view to run the task.
        HStack(spacing: 0) {
            if session.git.isRepository, let commit = blame?.commit(atLine: session.cursor.line) {
                Button { showsCommit.toggle() } label: {
                    Label(commit.isUncommitted ? "Not committed yet" : "\(commit.author), \(commit.date.relative)", systemImage: "person.crop.circle")
                        .lineLimit(1)
                        .frame(maxWidth: 240, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .help(commit.isUncommitted ? "This line has changes not yet committed" : "\(commit.shortHash) \(commit.summary)")
                .popover(isPresented: $showsCommit, arrowEdge: .top) {
                    BlameCard(commit: commit, line: session.cursor.line, path: ProposedChange.relativePath(of: document.url, in: workspace.url)) { command in
                        showsCommit = false
                        session.runInTerminal(command)
                    }
                }
            }
        }
        // Blame again once typing settles, so lines below an edit keep their commits.
        .task(id: "\(document.url.path)|\(document.text.hashValue)|\(workspace.revision)|\(session.git.isRepository)") {
            if blame != nil { try? await Task.sleep(for: .milliseconds(700)) }
            guard !Task.isCancelled, session.git.isRepository else { return }
            blame = await GitBlame.load(file: document.url, text: document.text, root: workspace.url)
        }
    }
}

private struct BlameCard: View {
    @Environment(\.theme) private var theme
    let commit: GitBlame.Commit
    let line: Int
    let path: String
    let run: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if commit.isUncommitted {
                Text("Line \(line) has changes that aren’t committed yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text.color)
            } else {
                Text(commit.summary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(commit.shortHash).font(.system(size: 11.5, design: .monospaced))
                    Text("·")
                    Text(commit.author)
                    Text("·")
                    Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(theme.text3.color)
            }
            HStack(spacing: 8) {
                if !commit.isUncommitted {
                    Button("Show Commit") { run("git show \(commit.hash)") }
                        .buttonStyle(DanteButtonStyle(primary: true))
                    Button("Copy Hash") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.hash, forType: .string)
                    }
                    .buttonStyle(DanteButtonStyle())
                }
                Button("Line History") { run("git log -L \(line),\(line):\(Shell.quote(path))") }
                    .buttonStyle(DanteButtonStyle())
                    .help("Every commit that changed this line, in the terminal")
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(theme.panel.color)
    }
}

/// Problems in the active file and its language server's state. The problem on the
/// caret's line shows in full, since the editor only underlines it.
private struct LanguageStatus: View {
    @Environment(\.theme) private var theme
    let session: Session
    let document: EditorDocument
    @State private var showsList = false

    var body: some View {
        if let languages = session.languages, let server = LanguageServer.for(document.language) {
            let diagnostics = languages.diagnostics(for: document)
            let errors = diagnostics.count { $0.severity == .error }
            let warnings = diagnostics.count { $0.severity == .warning }
            let here = diagnostics.first { $0.range.start.line == session.cursor.line - 1 }
            HStack(spacing: 10) {
                if let here {
                    Text(here.message)
                        .foregroundStyle(here.severity == .error ? theme.red.color : theme.amber.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 420, alignment: .trailing)
                    if here.severity <= .warning {
                        Button { session.fixWithClaude(here, in: document) } label: {
                            Label("Fix", systemImage: "sparkle")
                        }
                        .accessibilityLabel("Fix with Claude")
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.accent.color)
                        .help("Ask Claude to fix this \(here.severity == .error ? "error" : "warning")")
                    }
                }
                if let client = languages.existingClient(for: document.language) {
                    Button { showsList.toggle() } label: {
                        HStack(spacing: 8) {
                            Label("\(errors)", systemImage: "xmark.octagon").foregroundStyle(errors > 0 ? theme.red.color : theme.text3.color)
                            Label("\(warnings)", systemImage: "exclamationmark.triangle").foregroundStyle(warnings > 0 ? theme.amber.color : theme.text3.color)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(state(client))
                    .popover(isPresented: $showsList, arrowEdge: .top) {
                        ProblemsList(diagnostics: diagnostics, document: document, server: server.name, fix: { session.fixWithClaude($0, in: document) }, fixAll: { session.fixAllWithClaude(in: document) }) { showsList = false }
                    }
                } else if let reason = languages.unavailable[server.name] {
                    Text("No language server").help(reason + " Install it for diagnostics and Jump to Definition.")
                }
            }
        }
    }

    private func state(_ client: LSPClient) -> String {
        switch client.state {
        case .starting: "\(client.server.name) is starting…"
        case .ready: "\(client.server.name): click to list problems"
        case .stopped(let reason): reason
        }
    }
}

private struct ProblemsList: View {
    @Environment(\.theme) private var theme
    let diagnostics: [LSPDiagnostic]
    let document: EditorDocument
    let server: String
    let fix: (LSPDiagnostic) -> Void
    let fixAll: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(diagnostics.isEmpty ? "No problems in \(document.name)" : "\(document.name) · \(server)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text2.color)
                .padding(12)
            if !diagnostics.isEmpty {
                Rectangle().fill(theme.line.color).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(diagnostics) { diagnostic in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Button {
                                    document.revealRange = LineIndex(document.text as NSString).range(of: diagnostic.range)
                                    dismiss()
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(diagnostic.severity == .error ? theme.red.color : theme.amber.color)
                                        Text(diagnostic.message)
                                            .font(.system(size: 12))
                                            .foregroundStyle(theme.text.color)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 8)
                                        Text("\(diagnostic.range.start.line + 1)")
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .foregroundStyle(theme.text3.color)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Show in the editor")
                                Button {
                                    fix(diagnostic)
                                    dismiss()
                                } label: {
                                    Image(systemName: "sparkle").font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.accent.color)
                                .help("Ask Claude to fix this")
                                .accessibilityLabel("Fix with Claude")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            if diagnostics.contains(where: { $0.severity <= .warning }) {
                Rectangle().fill(theme.line.color).frame(height: 1)
                HStack {
                    Spacer()
                    Button("Fix all with Claude") {
                        fixAll()
                        dismiss()
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                }
                .padding(10)
            }
        }
        .frame(width: 420)
        .background(theme.panel.color)
    }
}
