import SwiftUI

/// Version control from the iPad, as the Mac's Changes panel: the branch and how far it is from
/// its upstream (Pull, Push, Fetch, switch or start a branch), the changed files (staged, not
/// staged, conflicts) with their diffs, a commit message the agent can write, Commit and
/// Commit and Push, and the latest commits. Everything runs on the Mac through the window's
/// own git, so its panel follows along. Conflicts are resolved on the Mac.
struct ChangesView: View {
    let connection: CompanionConnection
    let project: String
    @State private var git: CompanionGit?
    @State private var problem: String?
    @State private var busy: String?
    @State private var message = ""
    /// The Mac's last message, so a draft only replaces what wasn't typed here.
    @State private var macMessage = ""
    @State private var shownDiff: DiffRequest?
    @State private var discarding: [CompanionGit.Change] = []
    @State private var newBranch = ""
    @State private var askingBranch = false
    @Environment(\.horizontalSizeClass) private var width

    struct DiffRequest: Identifiable {
        var change: CompanionGit.Change
        var staged: Bool
        var id: String { change.path + (staged ? "#staged" : "") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let git, git.isRepository {
                    header(git).arrive(0)
                    if let note = note(git) { note.arrive(1) }
                    if width == .regular {
                        HStack(alignment: .top, spacing: 18) {
                            VStack(spacing: 18) { files(git) }.frame(maxWidth: .infinity)
                            VStack(spacing: 18) { commitCard(git); history(git) }.frame(width: 400)
                        }
                    } else {
                        commitCard(git)
                        files(git)
                        history(git)
                    }
                } else if git != nil {
                    ContentUnavailableView("No version control", systemImage: "arrow.triangle.branch",
                                           description: Text("This folder isn’t a git repository. Start one on the Mac."))
                } else if let problem {
                    ContentUnavailableView {
                        Label("Couldn’t load the changes", systemImage: "wifi.exclamationmark")
                    } description: { Text(problem) } actions: {
                        Button("Try Again") { Task { await run(.status) } }
                    }
                } else {
                    ProgressView("Asking the Mac…").frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .lookBackground()
        .navigationTitle("Changes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let busy {
                    HStack(spacing: 6) { ProgressView(); Text(busy).font(.subheadline).foregroundStyle(Palette.text2) }
                } else {
                    Button { Task { await run(.status) } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh")
                }
            }
        }
        .refreshable { await run(.status) }
        .task(id: project) {
            git = ChangesCache.shared.repositories[project]
            message = git?.message ?? ""
            macMessage = message
            while !Task.isCancelled {
                if busy == nil { await run(.status, quietly: true) }
                try? await Task.sleep(for: .seconds(DataSaver.shared.asksFirst ? 300 : 30))
            }
        }
        .sheet(item: $shownDiff) { request in
            DiffSheet(connection: connection, project: project, request: request) { action in
                shownDiff = nil
                Task { await run(action) }
            }
        }
        .confirmationDialog(discardTitle, isPresented: Binding(get: { !discarding.isEmpty }, set: { if !$0 { discarding = [] } }), titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                let paths = discarding.map(\.path)
                discarding = []
                Task { await run(.discard(paths: paths), as: "Discarding…") }
            }
        } message: {
            Text(discarding.contains(where: \.isUntracked) ? "New files go to the Mac’s Trash; edits to the others are lost." : "The edits are lost.")
        }
        .alert("New branch", isPresented: $askingBranch) {
            TextField("feature/name", text: $newBranch).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create and switch") {
                let name = newBranch.trimmingCharacters(in: .whitespaces)
                newBranch = ""
                guard !name.isEmpty else { return }
                Task { await run(.createBranch(name: name), as: "Creating \(name)…") }
            }
            Button("Cancel", role: .cancel) { newBranch = "" }
        } message: {
            Text("It starts from where \(git?.branch ?? "you are") is now, and keeps your changes.")
        }
    }

    // MARK: Header

    private func header(_ git: CompanionGit) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                branchMenu(git)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text(git.syncSummary).font(.subheadline).foregroundStyle(Palette.text2)
                if let upstream = git.upstream { Text(upstream).font(.footnote.monospaced()).foregroundStyle(Palette.text3) }
            }
            HStack(spacing: 10) {
                action("Pull", "arrow.down", prominent: git.behind > 0) { await run(.pull, as: "Pulling…") }
                    .disabled(git.upstream == nil)
                action(git.upstream == nil ? "Publish" : "Push", "arrow.up", prominent: git.ahead > 0 || (git.upstream == nil && !git.commits.isEmpty)) {
                    await run(.push, as: "Pushing…")
                }
                action("Fetch", "arrow.triangle.2.circlepath", prominent: false) { await run(.fetch, as: "Fetching…") }
            }
            .disabled(busy != nil)
        }
    }

    private func branchMenu(_ git: CompanionGit) -> some View {
        Menu {
            Section("Switch to") {
                ForEach(git.localBranches) { branch in
                    Button {
                        Task { await run(.checkout(name: branch.name, isRemote: false), as: "Switching…") }
                    } label: {
                        Label(branch.name, systemImage: branch.isCurrent ? "checkmark" : "arrow.triangle.branch")
                    }
                    .disabled(branch.isCurrent)
                }
            }
            let remote = git.branches.filter { branch in branch.isRemote && !git.localBranches.contains { branch.name.hasSuffix("/" + $0.name) } }
            if !remote.isEmpty {
                Section("From the remote") {
                    ForEach(remote.prefix(15)) { branch in
                        Button(branch.name) { Task { await run(.checkout(name: branch.name, isRemote: true), as: "Switching…") } }
                    }
                }
            }
            Button { askingBranch = true } label: { Label("New branch…", systemImage: "plus") }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Palette.accent)
                Text(git.branch ?? "Detached").font(.title2.weight(.semibold)).foregroundStyle(Palette.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Palette.text3)
            }
        }
        .disabled(busy != nil)
        .accessibilityLabel("Branch \(git.branch ?? "detached")")
    }

    private func action(_ title: String, _ symbol: String, prominent: Bool, _ work: @escaping () async -> Void) -> some View {
        Button { Task { await work() } } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: Palette.controlRadius).fill(prominent ? Palette.accent : Palette.card))
                .overlay(RoundedRectangle(cornerRadius: Palette.controlRadius).strokeBorder(prominent ? .clear : Palette.line))
                .foregroundStyle(prominent ? Palette.onAccent : Palette.text)
        }
        .buttonStyle(.plain)
    }

    /// What the last action did, why it failed, or an operation waiting on the Mac.
    private func note(_ git: CompanionGit) -> AnyView? {
        if let operation = git.operation {
            return AnyView(banner("arrow.triangle.merge", Palette.amber,
                                  "A \(operation) stopped on conflicts. Resolve them in Dante on the Mac, then continue it there."))
        }
        if let failure = git.failure {
            let text = git.needsPassword ? "Git needs your password for that, which only the Mac’s terminal can ask for. Run it there once and it will work from here." : failure
            return AnyView(banner("exclamationmark.triangle.fill", Palette.red, text))
        }
        if let notice = git.notice { return AnyView(banner("checkmark.circle.fill", Palette.green, notice)) }
        return nil
    }

    private func banner(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.subheadline).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.12)))
    }

    // MARK: Files

    @ViewBuilder private func files(_ git: CompanionGit) -> some View {
        if git.changes.isEmpty {
            Card(title: "No changes", symbol: "checkmark.circle") {
                Text("Everything on \(git.branch ?? "this branch") is committed.").font(.subheadline).foregroundStyle(Palette.text2)
            }
        }
        if !git.conflicted.isEmpty {
            Card(title: "Conflicts", symbol: "exclamationmark.triangle", count: git.conflicted.count) {
                ForEach(git.conflicted) { change in fileRow(change, staged: false, letter: "U") }
                Text("Resolve these on the Mac.").font(.footnote).foregroundStyle(Palette.text3)
            }
        }
        if !git.staged.isEmpty {
            Card(title: "Staged", symbol: "tray.full", count: git.staged.count) {
                ForEach(git.staged) { change in
                    fileRow(change, staged: true, letter: change.staged)
                        .contextMenu {
                            Button("Unstage", systemImage: "minus.circle") { Task { await run(.unstage(paths: [change.path])) } }
                        }
                }
                footerButton("Unstage all") { await run(.unstage(paths: git.staged.map(\.path))) }
            }
        }
        if !git.unstaged.isEmpty {
            Card(title: git.staged.isEmpty ? "Changes" : "Not staged", symbol: "pencil.line", count: git.unstaged.count) {
                ForEach(git.unstaged) { change in
                    fileRow(change, staged: false, letter: change.unstaged)
                        .contextMenu {
                            Button("Stage", systemImage: "plus.circle") { Task { await run(.stage(paths: [change.path])) } }
                            Button("Discard…", systemImage: "arrow.uturn.backward", role: .destructive) { discarding = [change] }
                        }
                }
                HStack {
                    footerButton("Stage all") { await run(.stage(paths: git.unstaged.map(\.path))) }
                    Spacer()
                    Button("Discard all…", role: .destructive) { discarding = git.unstaged }
                        .font(.subheadline).disabled(busy != nil)
                }
            }
        }
    }

    private func fileRow(_ change: CompanionGit.Change, staged: Bool, letter: String?) -> some View {
        Button { shownDiff = DiffRequest(change: change, staged: staged) } label: {
            HStack(spacing: 12) {
                Text(letter == "?" ? "N" : (letter ?? "·"))
                    .font(.caption.weight(.bold).monospaced())
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tint(letter).opacity(0.16)))
                    .foregroundStyle(tint(letter))
                VStack(alignment: .leading, spacing: 1) {
                    Text(change.fileName).font(.body).foregroundStyle(Palette.text).lineLimit(1)
                    if !change.folder.isEmpty { Text(change.folder).font(.caption).foregroundStyle(Palette.text3).lineLimit(1).truncationMode(.head) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.text3)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(change.fileName), \(CompanionGit.Change.label(letter))")
    }

    private func tint(_ letter: String?) -> Color {
        switch letter {
        case "A", "?": Palette.green
        case "D", "U": Palette.red
        default: Palette.amber
        }
    }

    private func footerButton(_ title: String, _ work: @escaping () async -> Void) -> some View {
        Button(title) { Task { await work() } }.font(.subheadline.weight(.medium)).disabled(busy != nil)
    }

    // MARK: Commit

    private func commitCard(_ git: CompanionGit) -> some View {
        Card(title: "Commit", symbol: "checkmark.seal") {
            TextField("What changed and why", text: $message, axis: .vertical)
                .lineLimit(3...8)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.background))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
            if let warning = git.warning {
                Label(warning, systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(Palette.amber)
            }
            Text(git.changes.isEmpty ? "Nothing to commit." : git.commitsEverything ? "Nothing is staged, so this commits every change." : "This commits the \(git.staged.count) staged file\(git.staged.count == 1 ? "" : "s").")
                .font(.footnote).foregroundStyle(Palette.text3)
            HStack(spacing: 10) {
                Button { Task { await run(.writeMessage, as: "Writing…") } } label: {
                    Label("Write it for me", systemImage: "sparkles").fixedSize()
                }
                .disabled(git.changes.isEmpty)
                Spacer()
                Button("Commit") { Task { await commit(push: false) } }
                    .buttonStyle(.bordered)
                    .disabled(!ready(git))
                Button("Commit and Push") { Task { await commit(push: true) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready(git))
            }
            .font(.subheadline.weight(.semibold))
            .disabled(busy != nil)
        }
    }

    private func ready(_ git: CompanionGit) -> Bool {
        git.canCommit && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit(push: Bool) async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let before = git?.commits.first?.hash
        await run(.commit(message: text, push: push), as: push ? "Committing and pushing…" : "Committing…")
        // Committed (even if the push then failed): the box empties.
        if git?.commits.first?.hash != before {
            message = ""
            macMessage = ""
        }
    }

    // MARK: History

    private func history(_ git: CompanionGit) -> some View {
        Card(title: "Latest commits", symbol: "clock.arrow.circlepath") {
            if git.commits.isEmpty {
                Text("No commits yet.").font(.subheadline).foregroundStyle(Palette.text3)
            }
            ForEach(git.commits.prefix(12)) { commit in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(commit.unpushed ? Palette.amber : Palette.line).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(commit.subject).font(.subheadline).foregroundStyle(Palette.text).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(commit.hash).font(.caption.monospaced())
                            if let date = commit.date { Text(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))) }
                            if commit.unpushed { Text("not pushed").foregroundStyle(Palette.amber) }
                        }
                        .font(.caption).foregroundStyle(Palette.text3)
                    }
                }
            }
        }
    }

    // MARK: Running

    private var discardTitle: String {
        discarding.count == 1 ? "Discard the changes to \(discarding[0].fileName)?" : "Discard changes to \(discarding.count) files?"
    }

    private func run(_ action: CompanionGitAction, as label: String? = nil, quietly: Bool = false) async {
        if let label { busy = label }
        defer { if label != nil { busy = nil } }
        switch await connection.git(action, project: project) {
        case .success(let fresh):
            withAnimation(.snappy) { git = fresh }
            problem = nil
            ChangesCache.shared.repositories[project] = fresh
            // The Mac's draft fills the box unless something's being typed here.
            if action == .writeMessage || message == macMessage { message = fresh.message }
            macMessage = fresh.message
        case .failure(let failure):
            if git == nil || !quietly { problem = git == nil ? failure.message : nil }
            if git != nil, !quietly { git?.failure = failure.message; git?.notice = nil }
        }
    }
}

/// The last repository read per project while the app runs, so going back is instant.
@MainActor
final class ChangesCache {
    static let shared = ChangesCache()
    var repositories: [String: CompanionGit] = [:]
}

/// One file's diff, with Stage or Unstage and Discard.
private struct DiffSheet: View {
    let connection: CompanionConnection
    let project: String
    let request: ChangesView.DiffRequest
    let act: (CompanionGitAction) -> Void
    @State private var diff: CompanionGit.Diff?
    @State private var problem: String?
    @State private var confirmDiscard = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let diff {
                    if diff.isBinary {
                        ContentUnavailableView("A binary file", systemImage: "doc", description: Text("Its changes can’t be shown as text."))
                    } else if diff.lines.isEmpty {
                        ContentUnavailableView("No differences", systemImage: "equal", description: Text("Nothing to show on this side."))
                    } else {
                        GeometryReader { geometry in
                            ScrollView([.vertical, .horizontal]) {
                                // At least as wide as the sheet, so a line's shading runs across it.
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in row(line) }
                                    if diff.truncated {
                                        Text("The rest is on the Mac.").font(.footnote).foregroundStyle(Palette.text3).padding(12)
                                    }
                                }
                                .frame(minWidth: geometry.size.width, alignment: .leading)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                } else if let problem {
                    ContentUnavailableView("Couldn’t load the diff", systemImage: "wifi.exclamationmark", description: Text(problem))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Palette.background)
            .navigationTitle(request.change.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    if let diff {
                        HStack(spacing: 8) {
                            Text(request.change.fileName).font(.headline)
                            Text("+\(diff.added)").foregroundStyle(Palette.green)
                            Text("−\(diff.removed)").foregroundStyle(Palette.red)
                        }
                        .font(.subheadline.monospacedDigit())
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !request.change.isConflicted {
                        if request.staged {
                            Button("Unstage") { act(.unstage(paths: [request.change.path])) }
                        } else {
                            Button("Discard", role: .destructive) { confirmDiscard = true }
                            Button("Stage") { act(.stage(paths: [request.change.path])) }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .confirmationDialog("Discard the changes to \(request.change.fileName)?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { act(.discard(paths: [request.change.path])) }
            }
        }
        .task {
            switch await connection.git(.diff(path: request.change.path, staged: request.staged), project: project) {
            case .success(let git):
                diff = git.diff
                if git.diff == nil { problem = "The Mac sent no diff." }
            case .failure(let failure):
                problem = failure.message
            }
        }
    }

    private func row(_ line: CompanionGit.Diff.Line) -> some View {
        HStack(spacing: 0) {
            Text(line.number.map(String.init) ?? "")
                .frame(width: 48, alignment: .trailing)
                .foregroundStyle(Palette.text3)
                .padding(.trailing, 10)
            Text(marker(line.kind)).foregroundStyle(color(line.kind)).frame(width: 14, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk ? Palette.accent : Palette.text)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 16)
        }
        .font(.system(.footnote, design: .monospaced))
        .padding(.vertical, line.kind == .hunk ? 6 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line.kind))
    }

    private func marker(_ kind: CompanionGit.Diff.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        default: " "
        }
    }

    private func color(_ kind: CompanionGit.Diff.Kind) -> Color {
        switch kind {
        case .added: Palette.green
        case .removed: Palette.red
        default: Palette.text3
        }
    }

    private func background(_ kind: CompanionGit.Diff.Kind) -> Color {
        switch kind {
        case .added: Palette.green.opacity(0.12)
        case .removed: Palette.red.opacity(0.12)
        case .hunk: Palette.accentTint
        case .context: .clear
        }
    }
}
