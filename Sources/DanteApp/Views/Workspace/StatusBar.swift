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
                        ProblemsList(diagnostics: diagnostics, document: document, server: server.name) { showsList = false }
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
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 420)
        .background(theme.panel.color)
    }
}
