import AppKit
import DanteKit
import SwiftUI

/// Review's pull request card: the branch's pull request on Bitbucket with its reviewers'
/// verdicts and comment threads, read with git's own sign-in. Writing (approving, commenting,
/// adding reviewers, opening a pull request) happens on Bitbucket's pages in the browser.
struct PullRequestCard: View {
    @Environment(\.theme) private var theme
    let host: ReviewModel.HostReview
    let open: (String, Int?) -> Void
    let refresh: () -> Void

    @State private var showsAllThreads = false

    var body: some View {
        if host.status != .notHosted, host.status != .unknown {
            Card("Pull request") {
                HStack(spacing: 8) {
                    if host.status == .loading { ProgressView().controlSize(.small) }
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(DanteButtonStyle())
                        .disabled(host.status == .loading)
                        .help("Read the pull request from Bitbucket again")
                    if let url = host.current?.url ?? host.remote.map({ $0.webURL.appending(path: "pull-requests") }) {
                        Button("Open in Bitbucket") { NSWorkspace.shared.open(url) }
                            .buttonStyle(DanteButtonStyle())
                            .help("Approve, comment and add reviewers on Bitbucket’s own page")
                    }
                }
            } content: {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch host.status {
        case .failed(let error):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(theme.amber.color)
                Text(error.explanation).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .loading where host.current == nil && host.others.isEmpty:
            Text("Reading pull requests from Bitbucket with git’s sign-in…").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
        default:
            if let pr = host.current {
                pullRequest(pr)
            } else {
                noPullRequest
            }
        }
    }

    // MARK: The branch's pull request

    private func pullRequest(_ pr: BitbucketPullRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("#\(pr.id)").font(.dante(size: 14, design: .monospaced)).foregroundStyle(theme.text3.color)
                    Text(pr.title).font(.dante(size: 15, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(2)
                    if pr.draft { Chip(text: "Draft") }
                }
                Text("\(pr.source) → \(pr.destination) · opened by \(pr.author.name)\(pr.updated.map { " · updated \($0.formatted(.relative(presentation: .named)))" } ?? "")")
                    .font(.dante(size: 12)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.middle)
            }
            verdict(pr)
            if pr.reviewers.isEmpty {
                Text("No reviewers yet. Add them on Bitbucket, and their approvals show here.")
                    .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color)
            } else {
                FlowChips(items: pr.reviewers.map(\.person.name)) { name in
                    if let reviewer = pr.reviewers.first(where: { $0.person.name == name }) { reviewerChip(reviewer) }
                }
            }
            threads(pr)
        }
    }

    private func verdict(_ pr: BitbucketPullRequest) -> some View {
        let reviewers = pr.reviewers.count
        let (text, color): (String, Color) =
            pr.changesRequested > 0 ? ("\(pr.changesRequested) asked for changes", theme.red.color)
            : reviewers > 0 && pr.approvals >= reviewers ? ("Approved by everyone asked", theme.green.color)
            : pr.approvals > 0 ? ("\(pr.approvals) of \(reviewers) approved", theme.amber.color)
            : reviewers > 0 ? ("Waiting for \(reviewers == 1 ? "its reviewer" : "\(reviewers) reviewers")", theme.text2.color)
            : ("Not reviewed yet", theme.text2.color)
        let open = host.threads.count { !$0.resolved }
        return HStack(spacing: 10) {
            Text(text).font(.dante(size: 13, weight: .semibold)).foregroundStyle(color)
            Text([open > 0 ? "\(open) open thread\(open == 1 ? "" : "s")" : nil,
                  pr.tasks > 0 ? "\(pr.tasks) task\(pr.tasks == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.dante(size: 12)).foregroundStyle(theme.text3.color)
        }
    }

    private func reviewerChip(_ reviewer: BitbucketParticipant) -> some View {
        let (symbol, color, said): (String, Color, String) = switch reviewer.verdict {
        case .approved: ("checkmark.circle.fill", theme.green.color, "approved")
        case .changesRequested: ("exclamationmark.circle.fill", theme.red.color, "asked for changes")
        case .none: ("circle", theme.text3.color, "hasn’t decided yet")
        }
        return HStack(spacing: 5) {
            Image(systemName: symbol).font(.dante(size: 11)).foregroundStyle(color)
            Text(reviewer.person.name).font(.dante(size: 12, weight: .medium)).foregroundStyle(theme.text.color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(0.1)))
        .help("\(reviewer.person.name) \(said)")
    }

    // MARK: Threads

    @ViewBuilder
    private func threads(_ pr: BitbucketPullRequest) -> some View {
        let threads = host.threads.sorted { !$0.resolved && $1.resolved }
        if !threads.isEmpty {
            let shown = showsAllThreads ? threads : Array(threads.prefix(6))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, thread in
                    if index > 0 { Rectangle().fill(theme.line.color).frame(height: 1) }
                    threadRow(thread)
                }
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.ground.color.opacity(0.5)))
            if threads.count > 6 {
                LinkButton(showsAllThreads ? "Show fewer" : "Show all \(threads.count) threads") { showsAllThreads.toggle() }
            }
        } else if pr.comments == 0 {
            Text("No comments yet.").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
        }
    }

    private func threadRow(_ thread: BitbucketThread) -> some View {
        let root = thread.root
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if let path = root.path {
                    Button { open(path, root.onRemovedLine ? nil : root.line) } label: {
                        Text("\((path as NSString).lastPathComponent)\(root.line.map { ":\($0)" } ?? "")")
                            .font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.accent.color)
                    }
                    .buttonStyle(.plain)
                    .help(root.onRemovedLine ? "On a line this pull request removes from \(path)" : "Open \(path) at this line")
                } else {
                    Text("On the pull request").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                Spacer(minLength: 6)
                if thread.resolved { Chip(text: "Resolved", color: theme.green.color) }
                if !thread.replies.isEmpty {
                    Text("\(thread.replies.count) repl\(thread.replies.count == 1 ? "y" : "ies")")
                        .font(.dante(size: 11)).foregroundStyle(theme.text3.color)
                }
            }
            (Text(root.author.name + "  ").font(.dante(size: 12, weight: .semibold)).foregroundStyle(theme.text.color)
                + Text(root.text.split(separator: "\n").first.map(String.init) ?? "").font(.dante(size: 12)).foregroundStyle(theme.text2.color))
                .lineLimit(2)
            if let last = thread.replies.last {
                (Text("↳ " + last.author.name + "  ").font(.dante(size: 11.5, weight: .medium)).foregroundStyle(theme.text2.color)
                    + Text(last.text.split(separator: "\n").first.map(String.init) ?? "").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color))
                    .lineLimit(1)
            }
        }
        .opacity(thread.resolved ? 0.65 : 1)
        .padding(.vertical, 8)
    }

    // MARK: No pull request for this branch

    @ViewBuilder
    private var noPullRequest: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let branch = host.branch, branch != host.base, let remote = host.remote {
                HStack(spacing: 10) {
                    Text("No pull request for \(branch) yet.").font(.dante(size: 13)).foregroundStyle(theme.text2.color)
                    Spacer(minLength: 8)
                    Button("Create pull request") { NSWorkspace.shared.open(remote.newPullRequestURL(source: branch, destination: host.base)) }
                        .buttonStyle(DanteButtonStyle(primary: true))
                        .help("Opens Bitbucket’s new pull request page for this branch in your browser, where you’re signed in")
                }
            } else {
                Text(host.others.isEmpty ? "No open pull requests." : "\(host.others.count) open pull request\(host.others.count == 1 ? "" : "s") in \(host.remote?.repository ?? "this repository").")
                    .font(.dante(size: 13)).foregroundStyle(theme.text2.color)
            }
            if !host.others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(host.others.prefix(6)) { pr in
                        Button { if let url = pr.url { NSWorkspace.shared.open(url) } } label: {
                            HStack(spacing: 8) {
                                Text("#\(pr.id)").font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text3.color)
                                Text(pr.title).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(pr.author.name) · \(pr.approvals) approval\(pr.approvals == 1 ? "" : "s")")
                                    .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(pr.source) → \(pr.destination). Opens on Bitbucket")
                    }
                }
            }
        }
    }
}
