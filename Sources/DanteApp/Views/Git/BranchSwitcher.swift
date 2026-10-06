import DanteKit
import SwiftUI

/// The branch beside the project name: click to switch or create a branch, and the arrows
/// beside it push or pull when the branch is ahead of or behind its upstream.
struct BranchButton: View {
    @Environment(\.theme) private var theme
    let session: Session
    let branch: String
    @State private var hovering = false

    private var git: GitModel { session.git }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                session.showsBranches.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.text3.color)
                    Text(branch)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.text2.color)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.text3.color)
                }
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering || session.showsBranches ? theme.raised.color : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Switch branch (⌃⇧B)")
            .accessibilityLabel("Branch \(branch)")
            .popover(isPresented: Bindable(session).showsBranches, arrowEdge: .bottom) {
                BranchPicker(session: session)
            }

            if let status = git.status {
                if git.busy != nil {
                    ProgressView().controlSize(.mini).padding(.horizontal, 4).help(git.busy ?? "")
                } else if status.ahead > 0 || status.behind > 0 || (status.upstream == nil && status.branch != nil && !status.isNewRepository) {
                    Button {
                        Task { await git.sync() }
                    } label: {
                        HStack(spacing: 3) {
                            if status.upstream == nil {
                                Image(systemName: "icloud.and.arrow.up")
                            } else {
                                if status.behind > 0 { Text("↓\(status.behind)") }
                                if status.ahead > 0 { Text("↑\(status.ahead)") }
                            }
                        }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .background(Capsule().fill(theme.accentTint.color))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(syncHelp(status))
                    .accessibilityLabel(syncHelp(status))
                }
            }
        }
    }

    private func syncHelp(_ status: GitStatus) -> String {
        if status.upstream == nil { return "Publish \(branch) to the remote" }
        var parts: [String] = []
        if status.behind > 0 { parts.append("pull \(status.behind) commit\(status.behind == 1 ? "" : "s")") }
        if status.ahead > 0 { parts.append("push \(status.ahead) commit\(status.ahead == 1 ? "" : "s")") }
        return "Sync with \(status.upstream!): " + parts.joined(separator: " and ")
    }
}

/// Branches to switch to, newest first, with a field that filters them or names a new one.
private struct BranchPicker: View {
    @Environment(\.theme) private var theme
    let session: Session
    @State private var query = ""
    @FocusState private var focused: Bool

    private var git: GitModel { session.git }

    private var filtered: [GitBranch] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        return text.isEmpty ? git.branches : git.branches.filter { $0.name.lowercased().contains(text) }
    }

    private var newName: String? {
        let name = query.trimmingCharacters(in: .whitespaces)
        guard GitBranch.isValidName(name), !git.branches.contains(where: { $0.localName == name }) else { return nil }
        return name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.text3.color)
                TextField("Switch to or create a branch", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                IconButton(symbol: "arrow.down.circle", label: "Fetch from remotes", size: 12) { Task { await git.fetch() } }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 40)
            Rectangle().fill(theme.line.color).frame(height: 1)

            if let error = git.error {
                Text(error.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.red.color)
                    .padding(10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if (git.status?.changes.isEmpty == false) {
                Label("You have uncommitted changes. Git carries them to the new branch unless they clash.", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text3.color)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if let newName {
                        row(symbol: "plus", title: "Create branch \(newName)", detail: "from \(git.status?.branch ?? "HEAD")", current: false) {
                            Task { await git.createBranch(newName); if git.error == nil { session.showsBranches = false } }
                        }
                    }
                    let local = filtered.filter { !$0.isRemote }
                    let remote = filtered.filter(\.isRemote)
                    if !local.isEmpty { heading("Branches") }
                    ForEach(local) { branch in branchRow(branch) }
                    if !remote.isEmpty { heading("Remote") }
                    ForEach(remote) { branch in branchRow(branch) }
                }
                .padding(6)
            }
            // A scroll view in a popover has no height of its own; size it to its rows.
            .frame(height: min(380, CGFloat(filtered.count + (newName == nil ? 0 : 1)) * 42 + 70))
        }
        .frame(width: 380)
        .background(theme.card.color)
        .task {
            focused = true
            await git.loadBranches()
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(theme.text3.color)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func branchRow(_ branch: GitBranch) -> some View {
        row(symbol: branch.isRemote ? "cloud" : "arrow.triangle.branch", title: branch.name,
            detail: [branch.subject, branch.date.map { $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            current: branch.isCurrent) {
            guard !branch.isCurrent else { session.showsBranches = false; return }
            Task {
                await git.checkout(branch)
                if git.error == nil { session.showsBranches = false }
            }
        }
    }

    private func row(symbol: String, title: String, detail: String, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: current ? "checkmark" : symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(current ? theme.accent.color : theme.text3.color)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: current ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(theme.text.color)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }

    private func submit() {
        if let first = filtered.first {
            Task { await git.checkout(first); if git.error == nil { session.showsBranches = false } }
        } else if let newName {
            Task { await git.createBranch(newName); if git.error == nil { session.showsBranches = false } }
        }
    }
}

private struct HoverRowStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(configuration.isPressed || hovering ? theme.raised.color : .clear))
            .onHover { hovering = $0 }
    }
}
