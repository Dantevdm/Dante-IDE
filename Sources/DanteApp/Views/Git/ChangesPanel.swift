import AppKit
import DanteKit
import SwiftUI

/// Source control in the sidebar: a commit box, then staged, changed and conflicted files.
/// Click a file to see its diff; hover for stage, unstage and discard.
struct ChangesPanel: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    @State private var confirmDiscard: [GitStatus.Change]?

    private var git: GitModel { session.git }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status = git.status {
                commitBox(status)
                if let error = git.error { banner(error) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if status.changes.isEmpty {
                            Text("No changes. Edits you make show up here, ready to commit.")
                                .font(.dante(size: 12))
                                .foregroundStyle(theme.text3.color)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 14)
                        }
                        group("Conflicts", status.conflicted, staged: false)
                        group("Staged", status.staged, staged: true)
                        group(status.staged.isEmpty ? "Changes" : "Not staged", status.unstaged, staged: false)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This folder isn’t a git repository.")
                        .font(.dante(size: 12.5))
                        .foregroundStyle(theme.text2.color)
                    Button("Initialise Repository") { session.runInTerminal("git init") }
                        .buttonStyle(DanteButtonStyle())
                }
                .padding(14)
            }
        }
        .confirmationDialog(discardTitle, isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } })) {
            Button("Discard Changes", role: .destructive) {
                if let changes = confirmDiscard { Task { await git.discard(changes) } }
            }
        } message: {
            Text("This can’t be undone. New files go to the Trash.")
        }
    }

    private var discardTitle: String {
        guard let changes = confirmDiscard else { return "" }
        return changes.count == 1 ? "Discard changes to \((changes[0].path as NSString).lastPathComponent)?" : "Discard \(changes.count) changes?"
    }

    // MARK: Commit box

    private func commitBox(_ status: GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if git.message.isEmpty {
                    Text(status.staged.isEmpty ? "Message (commits all changes)" : "Message")
                        .font(.dante(size: 12.5))
                        .foregroundStyle(theme.text3.color)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Bindable(git).message)
                    .font(.dante(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 7)
                    .frame(minHeight: 58, maxHeight: 140)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Commit message")
            }
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.ground.color))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.line.color))
            .overlay(alignment: .bottomTrailing) {
                Button {
                    Task { await git.writeMessage(tasks: inProgressTasks) }
                } label: {
                    Group {
                        if git.writingMessage {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkle").font(.dante(size: 11, weight: .semibold))
                        }
                    }
                    .frame(width: 22, height: 22)
                    .foregroundStyle(theme.accent.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(git.writingMessage || status.changes.isEmpty)
                .help("Write the message with Claude, from the diff")
                .accessibilityLabel("Write message with Claude")
                .padding(4)
            }

            HStack(spacing: 6) {
                Button {
                    Task { await git.commit(thenPush: false) }
                } label: {
                    Text(git.busy ?? (git.amend ? "Amend" : "Commit"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!git.canCommit)
                .help("Commit (⌘↩)")
                Button {
                    Task { await git.commit(thenPush: true) }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(DanteButtonStyle())
                .disabled(!git.canCommit)
                .help("Commit and push")
                .accessibilityLabel("Commit and push")
            }
            HStack(spacing: 8) {
                Toggle("Amend last commit", isOn: Bindable(git).amend)
                    .toggleStyle(.checkbox)
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.text2.color)
                    .disabled(status.isNewRepository)
                Spacer()
                if let notice = git.notice {
                    Text(notice)
                        .font(.dante(size: 11))
                        .foregroundStyle(theme.green.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var inProgressTasks: [String] {
        workspace.tasks.tasks.filter { $0.state == .inProgress }.map { "\($0.id) \($0.title)" }
    }

    private func banner(_ error: GitRepository.Failure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(error.message)
                .font(.dante(size: 11.5))
                .foregroundStyle(theme.text.color)
                .textSelection(.enabled)
                .lineLimit(8)
            HStack(spacing: 6) {
                if error.needsCredentials, let command = error.terminalCommand {
                    Button("Run in Terminal") {
                        session.runInTerminal(command)
                        git.error = nil
                    }
                    .buttonStyle(DanteButtonStyle())
                }
                Button("Ask Claude") {
                    session.askClaude("Git said this when I tried to work with the repository. Explain what happened and how to fix it; don't run anything that changes history without asking.\n\n\(error.message)")
                }
                .buttonStyle(DanteButtonStyle())
                Spacer()
                IconButton(symbol: "xmark", label: "Dismiss", size: 10) { git.error = nil }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.red.opacity(0.1).color))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(theme.red.opacity(0.35).color))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: File lists

    @ViewBuilder
    private func group(_ title: String, _ changes: [GitStatus.Change], staged: Bool) -> some View {
        if !changes.isEmpty {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.dante(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(theme.text3.color)
                Text("\(changes.count)")
                    .font(.dante(size: 10, weight: .semibold))
                    .foregroundStyle(theme.text3.color)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(theme.raised.color))
                Spacer()
                if title != "Conflicts" {
                    if staged {
                        IconButton(symbol: "minus", label: "Unstage all", size: 10) { Task { await git.unstage(changes) } }
                    } else {
                        IconButton(symbol: "arrow.uturn.backward", label: "Discard all", size: 10) { confirmDiscard = changes }
                        IconButton(symbol: "plus", label: "Stage all", size: 10) { Task { await git.stage(changes) } }
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
            ForEach(changes) { change in
                ChangeRow(
                    change: change,
                    kind: (staged ? change.staged : change.unstaged) ?? .modified,
                    isSelected: git.diff == GitModel.DiffTarget(change: change, staged: staged),
                    open: {
                        git.diff = GitModel.DiffTarget(change: change, staged: staged)
                        session.area = .code
                    },
                    openFile: { session.open(file: workspace.url.appending(path: change.path)) },
                    toggle: { Task { staged ? await git.unstage([change]) : await git.stage([change]) } },
                    discard: staged || change.isConflicted ? nil : { confirmDiscard = [change] },
                    staged: staged
                )
            }
        }
    }
}

private struct ChangeRow: View {
    @Environment(\.theme) private var theme
    let change: GitStatus.Change
    let kind: GitStatus.Kind
    let isSelected: Bool
    let open: () -> Void
    let openFile: () -> Void
    let toggle: () -> Void
    let discard: (() -> Void)?
    let staged: Bool
    @State private var hovering = false

    private var name: String { (change.path as NSString).lastPathComponent }
    private var folder: String { (change.path as NSString).deletingLastPathComponent }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: FileIcon.symbol(for: URL(filePath: change.path), isDirectory: false))
                        .font(.dante(size: 11.5))
                        .foregroundStyle(theme.text3.color)
                        .frame(width: 16)
                    Text(name)
                        .font(.dante(size: 12.5))
                        .foregroundStyle(kind == .deleted ? theme.text3.color : theme.text.color)
                        .strikethrough(kind == .deleted)
                        .lineLimit(1)
                    if !folder.isEmpty {
                        Text(folder)
                            .font(.dante(size: 11))
                            .foregroundStyle(theme.text3.color)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(change.path), \(kind.label)")

            if hovering || isSelected {
                if kind != .deleted {
                    IconButton(symbol: "doc.text", label: "Open file", size: 10, action: openFile)
                }
                if let discard {
                    IconButton(symbol: "arrow.uturn.backward", label: "Discard changes", size: 10, action: discard)
                }
                if kind != .conflicted {
                    IconButton(symbol: staged ? "minus" : "plus", label: staged ? "Unstage" : "Stage", size: 10, action: toggle)
                }
            }
            Text(kind.letter)
                .font(.dante(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 14)
                .help(kind.label)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? theme.accentTint.color : (hovering ? theme.raised.color : .clear))
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button(staged ? "Unstage" : "Stage", action: toggle).disabled(kind == .conflicted)
            if let discard { Button("Discard Changes…", action: discard) }
            Divider()
            Button("Open File", action: openFile).disabled(kind == .deleted)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
        }
    }

    private var color: Color {
        switch kind {
        case .added, .untracked: theme.green.color
        case .deleted, .conflicted: theme.red.color
        case .renamed, .copied: theme.accent.color
        default: theme.amber.color
        }
    }
}
