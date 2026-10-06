import DanteKit
import SwiftUI

/// Finish a task: branch, commit, push and pull request in one go, with Claude's drafts to edit.
struct FinishTaskSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let session: Session
    let workspace: Workspace
    @Bindable var model: FinishTaskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Finish \(model.task.id)").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text.color)
                Text(MarkdownText.attributed(model.task.title, theme: theme))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at the repository…").font(.system(size: 12)).foregroundStyle(theme.text3.color)
                }
            } else if model.finished {
                finishedView
            } else {
                branchSection
                commitSection
                pullRequestSection
            }

            if let error = model.error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.red.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let step = model.step {
                    ProgressView().controlSize(.small)
                    Text(step).font(.system(size: 12)).foregroundStyle(theme.text3.color)
                }
                Spacer()
                if model.finished {
                    Button("Done") { dismiss() }
                        .buttonStyle(DanteButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(DanteButtonStyle())
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.step != nil)
                    Button(model.runLabel) {
                        Task {
                            await model.run(tasks: workspace.tasks)
                            session.gitRevision += 1
                            session.refreshBranch()
                        }
                    }
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRun || model.draftingCommit || model.draftingPull)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(theme.card.color)
        .task { await model.prepare() }
    }

    private var branchSection: some View {
        section("Branch") {
            if model.createsBranch {
                HStack(spacing: 8) {
                    Text("New branch from \(model.defaultBranch)").font(.system(size: 12)).foregroundStyle(theme.text2.color)
                    TextField("Branch", text: $model.branchName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                if !GitBranch.isValidName(model.branchName) {
                    Text("That isn’t a valid branch name.").font(.system(size: 11)).foregroundStyle(theme.red.color)
                }
            } else {
                Text("On \(model.currentBranch)\(model.hasUpstream ? "" : ", which hasn’t been pushed yet").")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2.color)
            }
        }
    }

    private var commitSection: some View {
        section("Commit", drafting: model.draftingCommit, redraft: model.hasChanges ? { Task { await model.draftCommitMessage() } } : nil) {
            if model.hasChanges {
                editor($model.commitMessage, height: 84, monospaced: true)
            } else {
                let count = model.branchCommits.count
                Text("Nothing uncommitted. \(count) commit\(count == 1 ? "" : "s") on this branch \(count == 1 ? "goes" : "go") into the pull request.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2.color)
            }
        }
    }

    private var pullRequestSection: some View {
        section("Pull request", drafting: model.draftingPull, redraft: model.opensPullRequest ? { Task { await model.draftPullRequest() } } : nil) {
            Toggle("Open a pull request into \(model.defaultBranch)", isOn: $model.opensPullRequest)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .disabled(model.pullRequestUnavailable != nil)
            if let reason = model.pullRequestUnavailable {
                Text(reason).font(.system(size: 11)).foregroundStyle(theme.text3.color)
            }
            if model.opensPullRequest {
                TextField("Title", text: $model.pullTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
                editor($model.pullBody, height: 150, monospaced: false)
                Toggle("Open as a draft", isOn: $model.isDraft)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
        }
    }

    private var finishedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(model.task.id) is in review, and \(model.branchName) is pushed.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.green.color)
            if let url = model.pullRequestURL {
                HStack(spacing: 8) {
                    Text(url.absoluteString)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.text2.color)
                        .textSelection(.enabled)
                    Button("Open Pull Request") { openURL(url) }
                        .buttonStyle(DanteButtonStyle())
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, drafting: Bool = false, redraft: (() -> Void)? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.text3.color)
                Spacer()
                if drafting {
                    ProgressView().controlSize(.mini)
                    Text("Claude is drafting…").font(.system(size: 11)).foregroundStyle(theme.text3.color)
                } else if let redraft {
                    Button(action: redraft) {
                        Label("Redraft", systemImage: "sparkle").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent.color)
                    .help("Ask Claude for a new draft")
                }
            }
            content()
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat, monospaced: Bool) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line.color))
    }
}
