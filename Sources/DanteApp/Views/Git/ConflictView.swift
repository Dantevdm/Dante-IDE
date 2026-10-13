import DanteKit
import SwiftUI

/// A conflicted file in the editor area: each conflict as yours, the common base and
/// theirs side by side, with a choice per conflict and the result under it. Mark Resolved
/// writes the file and stages it; nothing changes on disk before that.
struct ConflictView: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeStore.self) private var themeStore
    let session: Session
    let workspace: Workspace
    let change: GitStatus.Change

    @State private var conflict: MergeConflict?
    @State private var loaded = false
    @State private var choices: [Int: MergeConflict.Choice] = [:]
    /// Text being written for a conflict by hand.
    @State private var drafts: [Int: String] = [:]
    /// The bases have been looked up in the index, so a missing one really is missing.
    @State private var basesChecked = false

    private var git: GitModel { session.git }
    private var url: URL { workspace.url.appending(path: change.path) }
    private var sides: (ours: String, theirs: String) { git.operation?.sides ?? ("Yours", "Theirs") }
    private var font: Font { .dante(size: themeStore.editorFontSize - 1, design: .monospaced) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.line.color).frame(height: 1)
            if let conflict {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(conflict.segments.enumerated()), id: \.offset) { index, segment in
                            switch segment {
                            case .common(let text):
                                context(text, first: index == 0, last: index == conflict.segments.count - 1)
                            case .conflict(let hunk):
                                card(hunk, total: conflict.hunks.count)
                            }
                        }
                    }
                    .padding(16)
                }
            } else if loaded {
                VStack(spacing: 10) {
                    Text("No conflict markers left in this file.")
                        .font(.dante(size: 13))
                        .foregroundStyle(theme.text2.color)
                    Text("If you resolved it in the editor, mark it resolved to stage it.")
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.text3.color)
                    Button("Mark Resolved") { Task { await markResolvedAsIs() } }
                        .buttonStyle(DanteButtonStyle(primary: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.codeBackground.color)
        .task(id: "\(change.path)#\(workspace.revision)") { await load() }
    }

    // MARK: Header

    private var resolvedCount: Int {
        conflict?.hunks.filter { choices[$0.id] != nil }.count ?? 0
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(theme.red.color)
            Text(change.path)
                .font(.dante(size: 12.5, weight: .medium))
                .foregroundStyle(theme.text.color)
                .lineLimit(1)
                .truncationMode(.head)
            if let conflict {
                Text("\(resolvedCount) of \(conflict.hunks.count) chosen")
                    .font(.dante(size: 10.5, weight: .semibold))
                    .foregroundStyle(resolvedCount == conflict.hunks.count ? theme.green.color : theme.text2.color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(theme.raised.color))
            }
            Spacer()
            if let conflict {
                Menu("Take All") {
                    Button("All \(sides.ours)") { choose(.ours, in: conflict) }
                    Button("All \(sides.theirs)") { choose(.theirs, in: conflict) }
                    Divider()
                    Button("Clear Choices") { choices = [:]; drafts = [:] }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.dante(size: 12))
            }
            Button("Ask Claude") { askClaude() }
                .buttonStyle(DanteButtonStyle())
                .help("Claude resolves the conflicts in this file; you review the edit")
            Button("Open in Editor") {
                git.diff = nil
                session.open(file: url, line: conflict?.hunks.first?.line ?? 1)
            }
            .buttonStyle(DanteButtonStyle())
            Button("Mark Resolved") { Task { await markResolved() } }
                .buttonStyle(DanteButtonStyle(primary: true))
                .disabled(conflict == nil || resolvedCount < (conflict?.hunks.count ?? 0) || git.busy != nil)
                .help("Writes your choices to the file and stages it")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    // MARK: Text both sides agree on

    /// A few lines either side of the conflicts; the rest folds to a count.
    private func context(_ text: String, first: Bool, last: Bool) -> some View {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let keep = 3
        let head = first ? [] : Array(lines.prefix(keep))
        let tail = last ? [] : Array(lines.suffix(keep))
        let hidden = lines.count - head.count - tail.count
        return VStack(alignment: .leading, spacing: 0) {
            if hidden <= 0 {
                code(lines.joined(separator: "\n"))
            } else {
                if !head.isEmpty { code(head.joined(separator: "\n")) }
                Text("⋯ \(hidden) unchanged line\(hidden == 1 ? "" : "s")")
                    .font(.dante(size: 11))
                    .foregroundStyle(theme.text3.color)
                    .padding(.vertical, 4)
                if !tail.isEmpty { code(tail.joined(separator: "\n")) }
            }
        }
        .padding(.horizontal, 10)
    }

    private func code(_ text: String) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(font)
            .foregroundStyle(theme.text2.color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: One conflict

    private func card(_ hunk: MergeConflict.Hunk, total: Int) -> some View {
        let choice = choices[hunk.id]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(total > 1 ? "Conflict \(hunk.id + 1) of \(total)" : "Conflict")
                    .font(.dante(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text.color)
                Text("line \(hunk.line)").font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                if hunk.base == nil, basesChecked {
                    Text("no common base: added on both sides")
                        .font(.dante(size: 11))
                        .foregroundStyle(theme.text3.color)
                }
                Spacer()
                if choice != nil {
                    Label("Chosen", systemImage: "checkmark.circle.fill")
                        .font(.dante(size: 11.5))
                        .foregroundStyle(theme.green.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(alignment: .top, spacing: 1) {
                column(title: sides.ours, detail: hunk.oursLabel, text: hunk.ours, tint: theme.accentTint, selected: choice == .ours) { choose(.ours, hunk) }
                if let base = hunk.base {
                    column(title: "Base", detail: "before either change", text: base, tint: theme.raised, selected: choice == .base) { choose(.base, hunk) }
                }
                column(title: sides.theirs, detail: hunk.theirsLabel, text: hunk.theirs, tint: theme.greenTint, selected: choice == .theirs) { choose(.theirs, hunk) }
            }
            .background(theme.line.color)

            HStack(spacing: 6) {
                choiceButton("Use \(sides.ours)", .ours, hunk)
                choiceButton("Use \(sides.theirs)", .theirs, hunk)
                choiceButton("Both", .both, hunk)
                choiceButton("Both, \(sides.theirs) First", .theirsThenOurs, hunk)
                Button("Edit…") {
                    let start = choice.map { MergeConflict.text(for: $0, in: hunk) } ?? MergeConflict.text(for: .both, in: hunk)
                    drafts[hunk.id] = start
                    choices[hunk.id] = .custom(start)
                }
                .buttonStyle(DanteButtonStyle())
                Spacer()
            }
            .padding(10)

            if let choice {
                result(choice, hunk)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(choice == nil ? theme.red.opacity(0.5).color : theme.line.color))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func column(title: String, detail: String, text: String, tint: RGBA, selected: Bool, pick: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.dante(size: 11, weight: .semibold)).foregroundStyle(theme.text.color)
                if !detail.isEmpty, detail != title {
                    Text(detail).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.dante(size: 10, weight: .bold)).foregroundStyle(theme.accent.color) }
            }
            Text(text.isEmpty ? "(nothing)" : String(text.dropLast(text.hasSuffix("\n") ? 1 : 0)))
                .font(font)
                .foregroundStyle(text.isEmpty ? theme.text3.color : theme.text.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint.color)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(theme.accent.color).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: pick)
        .help("Double-click to use this side")
    }

    private func choiceButton(_ title: String, _ choice: MergeConflict.Choice, _ hunk: MergeConflict.Hunk) -> some View {
        Button(title) { choose(choice, hunk) }
            .buttonStyle(DanteButtonStyle(primary: choices[hunk.id] == choice))
    }

    private func result(_ choice: MergeConflict.Choice, _ hunk: MergeConflict.Hunk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RESULT")
                .font(.dante(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(theme.text3.color)
            if case .custom = choice {
                TextEditor(text: Binding(
                    get: { drafts[hunk.id] ?? "" },
                    set: { drafts[hunk.id] = $0; choices[hunk.id] = .custom($0) }
                ))
                .font(font)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 80)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.codeBackground.color))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.accentLine.color))
            } else {
                let text = MergeConflict.text(for: choice, in: hunk)
                Text(text.isEmpty ? "(removed)" : String(text.dropLast(text.hasSuffix("\n") ? 1 : 0)))
                    .font(font)
                    .foregroundStyle(text.isEmpty ? theme.text3.color : theme.text.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.codeBackground.color))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: Actions

    private func choose(_ choice: MergeConflict.Choice, _ hunk: MergeConflict.Hunk) {
        choices[hunk.id] = choice
        drafts[hunk.id] = nil
    }

    private func choose(_ choice: MergeConflict.Choice, in conflict: MergeConflict) {
        for hunk in conflict.hunks { choose(choice, hunk) }
    }

    private func load() async {
        // An open document with edits is what the person is looking at; otherwise the disk.
        let open = workspace.documents.first { $0.url.standardizedFileURL == url.standardizedFileURL }
        let text = open?.text ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let parsed = MergeConflict.parse(text) else {
            conflict = nil
            loaded = true
            return
        }
        // Keep choices when the file reloads with the same conflicts.
        if conflict?.hunks.map(\.ours) != parsed.hunks.map(\.ours) || conflict?.hunks.map(\.theirs) != parsed.hunks.map(\.theirs) {
            choices = [:]
            drafts = [:]
        }
        // Show the sides straight away; the bases follow from the index.
        if conflict?.hunks.map(\.ours) != parsed.hunks.map(\.ours) { basesChecked = false }
        conflict = parsed.fillingBases(from: conflict ?? parsed)
        loaded = true
        if parsed.hunks.contains(where: { $0.base == nil }), let diff3 = await GitRepository.diff3(of: change.path, in: workspace.url) {
            conflict = parsed.fillingBases(from: diff3)
        }
        basesChecked = true
    }

    private func markResolved() async {
        guard let conflict else { return }
        await git.resolve(change.path, text: conflict.resolved(choices))
    }

    private func markResolvedAsIs() async {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        await git.resolve(change.path, text: text)
    }

    private func askClaude() {
        let operation = git.operation
        var note = "Resolve the merge conflicts in \(change.path)"
        if let operation { note += " (\(operation.title.lowercased()))" }
        note += ". In this file, the \(sides.ours.lowercased()) side is between <<<<<<< and =======, and the \(sides.theirs.lowercased()) side is between ======= and >>>>>>>."
        note += " Keep what each side meant to do, remove every conflict marker, and explain any choice that isn't obvious. Don't stage the file; I'll review it and mark it resolved."
        session.askClaude(note)
    }
}
