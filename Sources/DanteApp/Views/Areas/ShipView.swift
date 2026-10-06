import AppKit
import DanteKit
import SwiftUI

/// Ship: what releasing now would include. The next version and a changelog drafted from
/// commits since the last tag, CI from GitHub Actions, and a checklist. You decide when.
struct ShipView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var git: GitSnapshot?
    @State private var ci: Result<[CIRun], CIRun.Unavailable>?
    @State private var confirmingTag = false
    @State private var copied = false

    private var draft: ReleaseDraft? {
        git.map { ReleaseDraft(previousTag: $0.latestTag, commits: $0.sinceTag) }
    }

    var body: some View {
        AreaPage(
            eyebrow: "Release",
            title: draft?.version ?? "Release",
            subtitle: "What shipping now would include. Dante drafts the version and changelog from your commits and tasks; tagging stays local until you push."
        ) {
            Button {
                guard let draft else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft.markdown, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy changelog", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(DanteButtonStyle())
            .disabled(draft?.isEmpty ?? true)
            Button {
                confirmingTag = true
            } label: {
                Label("Tag \(draft?.version ?? "")", systemImage: "tag")
            }
            .buttonStyle(DanteButtonStyle(primary: true))
            .disabled(draft?.isEmpty ?? true || git?.isRepository != true)
        } content: {
            if let git, !git.isRepository {
                EmptyState(symbol: "arrow.triangle.branch", title: "Not a git repository", message: "Ship drafts releases from git history and tags. Initialise git to use it.") {
                    Button("git init in the terminal") { session.runInTerminal("git init") }
                        .buttonStyle(DanteButtonStyle())
                }
            } else {
                CICard(session: session, ci: ci)
                HStack(alignment: .top, spacing: 16) {
                    ChangelogCard(session: session, workspace: workspace, draft: draft, git: git)
                    ReleaseChecklist(session: session, workspace: workspace, git: git, draft: draft)
                        .frame(width: 360)
                }
            }
        }
        .task(id: workspace.revision) { await load() }
        .onChange(of: draft?.version) { copied = false }
        .confirmationDialog("Tag \(draft?.version ?? "")?", isPresented: $confirmingTag) {
            Button("Create tag \(draft?.version ?? "")") { tag() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates an annotated tag at the current commit. It stays on this Mac until you push it with git push --tags.")
        }
    }

    private func load() async {
        async let snapshot = GitSnapshot.load(in: workspace.url)
        async let runs = CIRun.load(projectRoot: workspace.url)
        git = await snapshot
        ci = await runs
    }

    private func tag() {
        guard let draft else { return }
        Task {
            do {
                try await Git.tag(draft.version, message: "Release \(draft.version)\n\n\(draft.markdown)", in: workspace.url)
                await load()
            } catch {
                session.errorMessage = "Couldn’t create the tag: \(error.localizedDescription)"
            }
        }
    }
}

private struct CICard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let ci: Result<[CIRun], CIRun.Unavailable>?

    var body: some View {
        Card("CI · GitHub Actions") {
            if case .success(let runs) = ci, let url = runs.first?.url?.deletingLastPathComponent() {
                LinkButton("All runs") { NSWorkspace.shared.open(url) }
            }
        } content: {
            switch ci {
            case nil:
                ProgressView().controlSize(.small)
            case .failure(.noWorkflows):
                HStack {
                    Text("No workflows in .github/workflows yet, so nothing checks a release before it ships.")
                        .font(.dante(size: 12.5))
                        .foregroundStyle(theme.text3.color)
                    Spacer()
                    Button("Ask Claude to add CI") {
                        session.askClaude("Add a GitHub Actions workflow in .github/workflows/ci.yml that builds and runs this project's tests on push and pull requests. Keep it minimal.")
                    }
                    .buttonStyle(DanteButtonStyle())
                }
            case .failure(.noGitHubCLI):
                Text("Install the GitHub CLI (brew install gh) and sign in with gh auth login to see runs here.")
                    .font(.dante(size: 12.5))
                    .foregroundStyle(theme.text3.color)
            case .failure(.failed(let message)):
                Text(message).font(.dante(size: 12)).foregroundStyle(theme.text3.color).lineLimit(3)
            case .success(let runs):
                if runs.isEmpty {
                    Text("No runs yet.").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
                }
                if let latest = runs.first, latest.conclusion == "failure" {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.amber.color)
                        Text("The latest run on \(latest.branch) failed: \(latest.title)")
                            .font(.dante(size: 12.5))
                            .foregroundStyle(theme.text2.color)
                        Spacer()
                        Button("Ask Claude why") {
                            session.askClaude("The latest GitHub Actions run (\(latest.workflow), run \(latest.id) on \(latest.branch)) failed. Use `gh run view \(latest.id) --log-failed` to find out why, then propose a fix.")
                        }
                        .buttonStyle(DanteButtonStyle())
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.amber.color.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.amber.color.opacity(0.3)))
                }
                RowList(data: runs, padding: 8) { run in
                    Button { run.url.map { _ = NSWorkspace.shared.open($0) } } label: {
                        HStack(spacing: 10) {
                            StatusDot(color: color(for: run))
                            Text(run.title).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                            Text(run.branch).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                            Spacer()
                            Text(run.isRunning ? run.status.replacingOccurrences(of: "_", with: " ") : run.conclusion)
                                .font(.dante(size: 12))
                                .foregroundStyle(color(for: run))
                            Text(run.created?.relative ?? "").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).frame(width: 90, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func color(for run: CIRun) -> Color {
        if run.isRunning { return theme.accent.color }
        return switch run.conclusion {
        case "success": theme.green.color
        case "failure", "timed_out": theme.red.color
        default: theme.text3.color
        }
    }
}

private struct ChangelogCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let draft: ReleaseDraft?
    let git: GitSnapshot?

    var body: some View {
        let doneTasks = workspace.tasks.tasks.filter { $0.state == .done }
        Card("Changelog · \(draft?.version ?? "")") {
            Button("Polish with Claude") {
                guard let draft else { return }
                session.askClaude("Here's a changelog Dante drafted from commit subjects since \(draft.previous ?? "the first commit"). Rewrite it for users: merge duplicates, drop internal refactors, keep it short. Don't change files.\n\n\(draft.markdown)")
            }
            .buttonStyle(DanteButtonStyle())
            .disabled(draft?.isEmpty ?? true)
        } content: {
            if let draft, let git {
                Text("Drafted from \(git.sinceTag.count) commits since \(draft.previous ?? "the first commit")\(draft.skipped > 0 ? ", leaving out \(draft.skipped) chores and merges" : "").")
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text3.color)
                if draft.isEmpty {
                    Text("Nothing new since \(draft.previous ?? "the start").").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
                }
                ForEach(draft.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(section.title)
                        ForEach(section.entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("–").foregroundStyle(theme.text3.color)
                                Text(MarkdownText.attributed(entry.text, theme: theme))
                                    .font(.dante(size: 12.5))
                                    .foregroundStyle(theme.text.color)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Text(String(entry.hash.prefix(7)))
                                    .font(.dante(size: 11, design: .monospaced))
                                    .foregroundStyle(theme.text3.color)
                            }
                        }
                    }
                }
                if !doneTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Tasks done")
                        ForEach(doneTasks) { task in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(task.id).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color)
                                Text(MarkdownText.attributed(task.title, theme: theme)).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct ReleaseChecklist: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    let git: GitSnapshot?
    let draft: ReleaseDraft?

    private struct Check: Identifiable {
        let text: String
        let done: Bool
        var note: String?
        var id: String { text }
    }

    var body: some View {
        let checks = automatic + fromPhaseDoc
        Card("Release checklist") {
            Text("\(checks.count(where: \.done))/\(checks.count)").font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
        } content: {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(checks) { check in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: check.done ? "checkmark.circle.fill" : "circle")
                            .font(.dante(size: 12))
                            .foregroundStyle(check.done ? theme.green.color : theme.text3.color)
                        Text(MarkdownText.attributed(check.text, theme: theme))
                            .font(.dante(size: 12.5))
                            .foregroundStyle(check.done ? theme.text2.color : theme.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        if let note = check.note {
                            Text(note).font(.dante(size: 11.5)).foregroundStyle(theme.amber.color)
                        }
                    }
                }
            }
            Rectangle().fill(theme.line.color).frame(height: 1)
            HStack {
                Text("A guide, not a gate. You can tag whenever you choose.")
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.text3.color)
                Spacer()
                if workspace.phaseDocs["release"] == nil {
                    LinkButton("Add release.md") { session.showPhase(workspace.lifecycle.phases.first { $0.lowercased() == "release" } ?? "Release") }
                }
            }
        }
    }

    private var automatic: [Check] {
        var checks: [Check] = []
        if let git {
            checks.append(Check(text: "Working tree clean", done: git.changedFiles == 0, note: git.changedFiles == 0 ? nil : "\(git.changedFiles) changed"))
            if let ahead = git.ahead {
                checks.append(Check(text: "Everything pushed", done: ahead == 0, note: ahead == 0 ? nil : "\(ahead) to push"))
            }
        }
        if let run = session.testRun, !run.isRunning {
            let passed = run.state == .finished(exitStatus: 0)
            checks.append(Check(text: "Tests pass (`\(run.command.label)`)", done: passed, note: passed ? nil : "\(run.failed) failing"))
        } else {
            checks.append(Check(text: "Tests pass", done: false, note: "not run"))
        }
        checks.append(Check(text: "Changelog drafted", done: !(draft?.isEmpty ?? true)))
        return checks
    }

    private var fromPhaseDoc: [Check] {
        (workspace.phaseDocs["release"]?.doneWhen ?? []).map { Check(text: $0.text, done: $0.done) }
    }
}
