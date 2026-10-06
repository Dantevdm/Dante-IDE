import DanteKit
import SwiftUI

/// Home: where the project is. The lifecycle, the current phase's checklist and tasks,
/// then git, the local environment, what Claude knows and the docs.
struct HomeView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var git: GitSnapshot?
    @State private var containers: Result<[ContainerState], DockerUnavailable>?
    @State private var compose: ComposeFile?

    private var lifecycle: Lifecycle { workspace.lifecycle }

    var body: some View {
        AreaPage(
            eyebrow: "Project",
            title: workspace.info.name ?? workspace.name,
            subtitle: workspace.info.summary ?? (lifecycle.hasSpec ? nil : "No .dante/project.yaml yet. Plan can draft one, or Claude can write it from the README and code.")
        ) {
            Button {
                session.palette = .all
            } label: {
                Label("Search or ask", systemImage: "magnifyingglass")
            }
            .buttonStyle(DanteButtonStyle())
        } content: {
            facts
            if let since = session.sinceLastVisit {
                SinceLastVisitCard(session: session, since: since)
            }
            Timeline(session: session, workspace: workspace)
            HStack(alignment: .top, spacing: 16) {
                CurrentPhaseCard(session: session, workspace: workspace)
                PhaseTasksCard(session: session, workspace: workspace)
            }
            CardGrid(minimum: 300) {
                GitCard(git: git) { session.area = .ship }
                EnvironmentCard(compose: compose, containers: containers) { session.area = .environments }
                ClaudeKnowsCard(session: session, workspace: workspace)
                DocsCard(session: session, workspace: workspace)
            }
        }
        .task(id: workspace.revision) { await load() }
    }

    private var facts: some View {
        HStack(spacing: 8) {
            ForEach(LanguageStats.top(workspace.files), id: \.language) { entry in
                Chip(text: entry.language.displayName, symbol: "chevron.left.forwardslash.chevron.right")
            }
            if let branch = Git.currentBranch(in: workspace.url) {
                Chip(text: branch, symbol: "arrow.triangle.branch")
            }
            if !workspace.files.isEmpty {
                Chip(text: "\(workspace.files.count) files", symbol: "doc")
            }
            if let compose, !compose.services.isEmpty {
                Chip(text: "\(compose.services.count) services", symbol: "shippingbox")
            }
        }
    }

    private func load() async {
        compose = ComposeFile.load(projectRoot: workspace.url)
        async let snapshot = GitSnapshot.load(in: workspace.url)
        if compose != nil {
            containers = await ContainerState.load(projectRoot: workspace.url)
        }
        git = await snapshot
    }
}

// MARK: Since last visit

/// Commits, task moves and a branch switch since the project was last closed in Dante.
private struct SinceLastVisitCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let since: SinceLastVisit

    var body: some View {
        Card("Since you were last here", accent: true) {
            Text(since.since.relative).font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
            IconButton(symbol: "xmark", label: "Dismiss", size: 9.5) { session.sinceLastVisit = nil }
        } content: {
            HStack(spacing: 14) {
                if !since.commits.isEmpty {
                    let count = since.commits.count + since.moreCommits
                    stat("\(count) commit\(count == 1 ? "" : "s")", symbol: "point.3.connected.trianglepath.dotted")
                }
                if since.filesChanged > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "doc").font(.system(size: 10.5))
                        Text("\(since.filesChanged) file\(since.filesChanged == 1 ? "" : "s")")
                        Text("+\(since.insertions)").foregroundStyle(theme.green.color)
                        Text("−\(since.deletions)").foregroundStyle(theme.red.color)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2.color)
                }
                if let change = since.branchChange {
                    stat("\(change.from) → \(change.to)", symbol: "arrow.triangle.branch")
                }
            }
            if !since.commits.isEmpty {
                RowList(data: since.commits, padding: 6) { commit in
                    HStack(spacing: 10) {
                        Text(String(commit.hash.prefix(7)))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.text3.color)
                        Text(commit.subject).font(.system(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(commit.author).font(.system(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        if let date = commit.date {
                            Text(date.relative).font(.system(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        }
                    }
                }
                if since.moreCommits > 0 {
                    Text("and \(since.moreCommits) more").font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
                }
            }
            if !since.taskMoves.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(since.taskMoves) { move in
                        HStack(spacing: 8) {
                            Text(move.id).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(theme.text3.color)
                            Text(MarkdownText.attributed(move.title, theme: theme)).font(.system(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(move.from.map { "\($0.title) → \(move.to.title)" } ?? "New · \(move.to.title)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(move.to == .done ? theme.green.color : theme.text2.color)
                        }
                    }
                }
            }
        }
    }

    private func stat(_ text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5))
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(theme.text2.color)
    }
}

// MARK: Lifecycle

private struct Timeline: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        let lifecycle = workspace.lifecycle
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(lifecycle.phases.enumerated()), id: \.offset) { index, phase in
                Button { session.showPhase(phase) } label: {
                    step(phase, index: index, current: lifecycle.currentIndex)
                }
                .buttonStyle(.plain)
                .help("Open \(phase) in Plan")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.line.color))
    }

    private func step(_ phase: String, index: Int, current: Int?) -> some View {
        let state: (bar: Double, label: String, color: Color, weight: Font.Weight) = {
            guard let current else { return (0, "Not started", theme.text3.color, .regular) }
            if index < current { return (1, "Done", theme.text3.color, .regular) }
            if index == current {
                let count = workspace.tasks.count(in: phase)
                let fraction = count.total == 0 ? 0.08 : max(0.08, Double(count.done) / Double(count.total))
                return (fraction, count.total == 0 ? "In progress" : "\(count.done) of \(count.total) tasks", theme.accent.color, .semibold)
            }
            return (0, "Not started", theme.text3.color, .regular)
        }()
        let isDone = current.map { index < $0 } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(isDone ? theme.done.color : theme.track.color)
                    if !isDone, state.bar > 0 {
                        Capsule().fill(theme.accent.color).frame(width: proxy.size.width * state.bar)
                    }
                }
            }
            .frame(height: 4)
            HStack(spacing: 5) {
                if isDone {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.green.color)
                }
                Text(phase)
                    .font(.system(size: 12.5, weight: state.weight))
                    .foregroundStyle(index == current ? theme.text.color : (isDone ? theme.text2.color : theme.text3.color))
            }
            Text(state.label).font(.system(size: 11.5)).foregroundStyle(state.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct CurrentPhaseCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        let lifecycle = workspace.lifecycle
        let phase = lifecycle.currentIndex.map { lifecycle.phases[$0] }
        let doc = phase.flatMap { workspace.phaseDocs[$0.lowercased()] }
        let items = doc?.doneWhen ?? []
        Card(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Current phase")
                    Text(phase ?? "None set").font(.system(size: 20, weight: .semibold)).foregroundStyle(theme.text.color)
                    if let summary = doc?.summary.nonEmpty ?? phase.map({ PhaseDoc.parse(workspace.lifecycle.phaseDocTemplate($0)).summary }) {
                        Text(summary).font(.system(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if !items.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        (Text("\(items.count(where: \.done))") + Text("/\(items.count)").foregroundStyle(theme.text3.color))
                            .font(.system(size: 22, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.text.color)
                        Text("done when").font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
                    }
                }
            }
            if items.isEmpty, let phase {
                Text("No “done when” checklist for \(phase) yet.").font(.system(size: 12.5)).foregroundStyle(theme.text3.color)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(item.done ? theme.green.color : theme.text3.color)
                        Text(MarkdownText.attributed(item.text, theme: theme))
                            .font(.system(size: 12.5))
                            .foregroundStyle(item.done ? theme.text2.color : theme.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                if let index = lifecycle.currentIndex, index + 1 < lifecycle.phases.count {
                    (Text("Up next: ") + Text(lifecycle.phases[index + 1]).foregroundStyle(theme.text2.color) + Text(". Move on whenever you’re ready."))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text3.color)
                }
                Spacer()
                Button("Open phase") { phase.map(session.showPhase) ?? (session.area = .plan) }
                    .buttonStyle(DanteButtonStyle())
            }
        }
    }
}

private struct PhaseTasksCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        let lifecycle = workspace.lifecycle
        let phase = lifecycle.currentIndex.map { lifecycle.phases[$0] }
        let order: [TaskState] = [.inProgress, .review, .ready]
        let tasks = phase.map { phase in order.flatMap { workspace.tasks.tasks(in: phase, state: $0) } } ?? []
        Card(phase.map { "\($0) tasks" } ?? "Tasks") {
            LinkButton("Board") { session.area = .plan }
        } content: {
            if tasks.isEmpty {
                Text(workspace.tasks.tasks.isEmpty ? "No tasks yet. Add them on the Plan board." : "Nothing open in this phase.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text3.color)
            } else {
                RowList(data: Array(tasks.prefix(7))) { task in
                    HStack(spacing: 10) {
                        Text(task.id)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.text3.color)
                            .frame(width: 48, alignment: .leading)
                        Text(MarkdownText.attributed(task.title, theme: theme))
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.text.color)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if task.claude == true {
                            Text("with Claude").font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
                        }
                        HStack(spacing: 5) {
                            StatusDot(color: color(for: task.state), size: 6)
                            Text(task.state.title).font(.system(size: 12)).foregroundStyle(color(for: task.state))
                        }
                        .frame(width: 92, alignment: .trailing)
                    }
                }
                if tasks.count > 7 {
                    Text("\(tasks.count - 7) more on the board").font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
                }
            }
        }
    }

    private func color(for state: TaskState) -> Color {
        switch state {
        case .inProgress: theme.accent.color
        case .review: theme.amber.color
        case .done: theme.green.color
        case .ready: theme.text3.color
        }
    }
}

// MARK: Cards

private struct GitCard: View {
    @Environment(\.theme) private var theme
    let git: GitSnapshot?
    let openShip: () -> Void

    var body: some View {
        Card("Recent commits") {
            LinkButton("Release", action: openShip)
        } content: {
            if let git {
                if !git.isRepository {
                    Text("Not a git repository.").font(.system(size: 12.5)).foregroundStyle(theme.text3.color)
                } else {
                    HStack(spacing: 14) {
                        stat(git.changedFiles == 0 ? "Clean" : "\(git.changedFiles) changed", color: git.changedFiles == 0 ? theme.green.color : theme.amber.color)
                        if let ahead = git.ahead, ahead > 0 { stat("\(ahead) to push", color: theme.accent.color) }
                        if let tag = git.latestTag { stat(tag, color: theme.text2.color, symbol: "tag") }
                    }
                    RowList(data: Array(git.recent.prefix(5)), padding: 7) { commit in
                        HStack(spacing: 10) {
                            Text(String(commit.hash.prefix(7)))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.text3.color)
                            Text(commit.subject).font(.system(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(commit.date.relative).font(.system(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func stat(_ text: String, color: Color, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5)) } else { StatusDot(color: color, size: 6) }
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(color)
    }
}

private struct EnvironmentCard: View {
    @Environment(\.theme) private var theme
    let compose: ComposeFile?
    let containers: Result<[ContainerState], DockerUnavailable>?
    let openEnv: () -> Void

    var body: some View {
        Card("Local environment") {
            LinkButton(compose == nil ? "Set up" : "Containers", action: openEnv)
        } content: {
            if let compose {
                if let error = compose.parseError {
                    Text(error).font(.system(size: 12.5)).foregroundStyle(theme.red.color)
                } else {
                    RowList(data: compose.services, padding: 7) { service in
                        let state = running.first { $0.service == service.name }
                        HStack(spacing: 8) {
                            StatusDot(color: color(for: state), size: 7)
                            Text(service.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text.color)
                            Spacer()
                            Text(state?.ports.first ?? service.ports.first.map { ":" + ($0.split(separator: ":").first.map(String.init) ?? $0) } ?? "")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.text3.color)
                            Text(state?.label ?? "stopped")
                                .font(.system(size: 12))
                                .foregroundStyle(color(for: state))
                                .frame(width: 76, alignment: .trailing)
                        }
                    }
                    if case .failure(let reason) = containers {
                        Text(reason.message).font(.system(size: 11.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("No docker-compose.yml. Env can run this project’s services once it has one, and Claude can write it.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var running: [ContainerState] {
        if case .success(let list) = containers { list } else { [] }
    }

    private func color(for state: ContainerState?) -> Color {
        guard let state else { return theme.text3.color }
        if state.state == "restarting" || state.health == "unhealthy" || state.health == "starting" { return theme.amber.color }
        if state.state == "running" { return theme.green.color }
        if state.state == "exited", !state.status.contains("(0)") { return theme.red.color }
        return theme.text3.color
    }
}

private struct ClaudeKnowsCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    private struct Fact: Identifiable {
        let label: String
        let value: String
        let present: Bool
        var id: String { label }
    }

    var body: some View {
        let rules = workspace.claudeRules
        let fileManager = FileManager.default
        let facts = [
            Fact(label: "Project and lifecycle", value: workspace.lifecycle.hasSpec ? "project.yaml" : "missing", present: workspace.lifecycle.hasSpec),
            Fact(label: "Phase definitions", value: "\(workspace.phaseDocs.count) of \(workspace.lifecycle.phases.count)", present: !workspace.phaseDocs.isEmpty),
            Fact(label: "Tasks", value: workspace.tasks.tasks.isEmpty ? "none" : "\(workspace.tasks.tasks.count)", present: !workspace.tasks.tasks.isEmpty),
            Fact(label: "Rules for Claude", value: rules.isEmpty ? "none" : "\(rules.propose.count) · \(rules.flag.count) · \(rules.never.count)", present: !rules.isEmpty),
            Fact(label: "Project notes", value: fileManager.fileExists(atPath: workspace.url.appending(path: "CLAUDE.md").path) ? "CLAUDE.md" : "none",
                 present: fileManager.fileExists(atPath: workspace.url.appending(path: "CLAUDE.md").path)),
        ]
        Card("What Claude knows") {
            LinkButton("Spec") { session.area = .spec }
        } content: {
            Text("Every conversation starts from the project spec, so nothing has to be re-explained.")
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text2.color)
                .fixedSize(horizontal: false, vertical: true)
            RowList(data: facts, padding: 7) { fact in
                HStack {
                    Text(fact.label).font(.system(size: 12.5)).foregroundStyle(theme.text2.color)
                    Spacer()
                    Text(fact.value)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(fact.present ? theme.text.color : theme.text3.color)
                }
            }
        }
    }
}

private struct DocsCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        let library = DocLibrary(paths: workspace.files)
        let docs = library.all.filter { !$0.path.hasPrefix(".dante/phases/") }
        Card("Documentation") {
            LinkButton("Read") { session.area = .docs }
        } content: {
            if docs.isEmpty {
                Text("No markdown docs yet.").font(.system(size: 12.5)).foregroundStyle(theme.text3.color)
            } else {
                RowList(data: Array(docs.prefix(6)), padding: 7) { doc in
                    Button { session.showDoc(doc.path) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(theme.text3.color)
                            Text(doc.title).font(.system(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                            Spacer()
                            Text(doc.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1).truncationMode(.head)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
