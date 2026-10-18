import DanteKit
import SwiftUI

/// Jobs: work handed to agents that run side by side, each on its own branch in its own
/// worktree. What each is doing, what it needs from you, and merging what's done.
struct JobsView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        let jobs = session.jobs
        AreaPage(eyebrow: nil, title: "Jobs", subtitle: subtitle) {
            if !jobs.open.isEmpty {
                Button { Task { await jobs.refreshChanges() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Count each job’s changes again")
            }
        } content: {
            Card("New job", accent: jobs.open.isEmpty) {
                NewJobForm(session: session)
            }
            if !jobs.inboxItems(session).isEmpty {
                Card("Waiting for you") {
                    InboxList(session: session, items: jobs.inboxItems(session), showsTitle: false)
                        .padding(.horizontal, -14)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if jobs.open.isEmpty, jobs.starting == nil {
                EmptyState(symbol: "square.stack.3d.up", title: "No jobs running",
                           message: "A job is an agent working on its own branch in a separate copy of the project, so several can run at once while you carry on here. When one is done, look over its changes and merge it.") {
                    EmptyView()
                }
            } else {
                CardGrid(minimum: 340) {
                    if let starting = jobs.starting { StartingCard(title: starting) }
                    ForEach(jobs.open) { job in
                        JobCard(session: session, job: job)
                            .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .scale(scale: 0.9).combined(with: .opacity)))
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: jobs.open.map(\.id))
            }
            if !jobs.types.isEmpty, jobs.unavailable == nil {
                Card("Job types") {
                    LinkButton("New type") { newType() }
                        .help("Write a job type in .dante/jobs/: a brief, a scope and when it starts")
                } content: {
                    RowList(data: jobs.types) { type in JobTypeRow(session: session, type: type) }
                }
            }
            if !jobs.closed.isEmpty {
                Card("Finished") {
                    RowList(data: jobs.closed) { job in FinishedRow(session: session, job: job) }
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: jobs.inboxItems(session).map(\.id))
        .task(id: workspace.revision) {
            jobs.reloadTypes()
            await jobs.refreshChanges()
        }
    }

    /// Starts a project job type from a template and opens it.
    private func newType() {
        let folder = JobType.folder(in: workspace.url)
        var name = "new-job"
        var number = 2
        while FileManager.default.fileExists(atPath: folder.appending(path: "\(name).md").path) {
            name = "new-job-\(number)"
            number += 1
        }
        let template = JobType(id: name, name: "New job", summary: "What this kind of job is for", awayMinutes: 30,
                               paths: [], brief: "How to do this kind of job, step by step. The person's request comes first, then this.")
        do {
            session.open(file: try template.copy(into: workspace.url))
            session.jobs.reloadTypes()
        } catch {
            session.errorMessage = "Couldn’t write the job type: \(error.localizedDescription)"
        }
    }

    private var subtitle: String? {
        let jobs = session.jobs
        guard !jobs.open.isEmpty else { return nil }
        let phases = jobs.open.map { jobs.phase(of: $0.id) }
        var parts: [String] = []
        let working = phases.filter { $0 == .working || $0 == .starting }.count
        let waiting = phases.filter { if case .waiting = $0 { true } else { $0 == .asking } }.count
        let ready = phases.filter { $0 == .ready }.count
        let paused = phases.filter { $0 == .paused }.count
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        if ready > 0 { parts.append("\(ready) ready to review") }
        if paused > 0 { parts.append("\(paused) paused") }
        return parts.joined(separator: " · ")
    }
}

private extension JobsModel {
    /// The board shows the jobs' waiting items; the main conversation's are in its panel.
    @MainActor func inboxItems(_ session: Session) -> [JobInbox.Item] { session.inbox.filter { $0.job != nil } }
}

private struct StartingCard: View {
    @Environment(\.theme) private var theme
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            JobPulse(phase: .starting, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(2)
                Text("Making its worktree…").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.accentLine.color, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

/// One job on the board.
private struct JobCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let job: JobRecord
    @State private var confirmsMerge = false
    @State private var confirmsDiscard = false
    @State private var hovering = false

    var body: some View {
        let jobs = session.jobs
        let phase = jobs.phase(of: job.id)
        let changes = jobs.changes[job.id] ?? JobChanges()
        let busy = jobs.busy.contains(job.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                JobPulse(phase: phase, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title).font(.dante(size: 14, weight: .semibold)).foregroundStyle(theme.text.color)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        AgentIcon(engine: job.engine, size: 11)
                        if let type = jobs.type(job.kind) {
                            Label(type.name, systemImage: job.trigger == nil ? JobTypeIcon.symbol(for: type) : "bolt")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                                .fixedSize()
                            Text("·")
                        }
                        Text(job.branch).font(.dante(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Text("·")
                        Elapsed(since: job.created)
                    }
                    .font(.dante(size: 11))
                    .foregroundStyle(theme.text3.color)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(phase.label)
                        .font(.dante(size: 11, weight: .semibold))
                        .foregroundStyle(phase.color(theme))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(phase.color(theme).opacity(0.13)))
                        .contentTransition(.interpolate)
                        .animation(.snappy, value: phase.label)
                    AwayChip(job: job, now: jobs.now)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if let activity = jobs.activity(of: job.id), phase.isActive {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.dante(size: 9, weight: .bold)).foregroundStyle(phase.color(theme))
                        Text(activity).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text2.color).lineLimit(1)
                    }
                    .id(activity)
                    .transition(.push(from: .bottom))
                }
                if let reply = jobs.lastReply(of: job.id) {
                    Text(reply).font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else if phase == .paused {
                    Text("Paused since Dante restarted. Open it to pick up where it left off.")
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
                } else if case .failed(let reason) = phase {
                    Text(reason).font(.dante(size: 12.5)).foregroundStyle(theme.red.color).lineLimit(3)
                } else {
                    Text(job.brief).font(.dante(size: 12.5)).foregroundStyle(theme.text3.color).lineLimit(2)
                }
            }
            .animation(.snappy(duration: 0.3), value: jobs.activity(of: job.id))
            ChangeBar(changes: changes)
            HStack(spacing: 8) {
                Button("Open") { session.showJob(job.id) }
                    .buttonStyle(DanteButtonStyle())
                    .help("Show the job’s conversation in the panel")
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Merge…") { confirmsMerge = true }
                        .buttonStyle(DanteButtonStyle(primary: phase == .ready))
                        .disabled(changes.isEmpty || phase.isActive)
                        .help(phase.isActive ? "Wait for the job to finish its turn" : "Commit what’s left and merge \(job.branch) into \(session.branch ?? "the checked-out branch")")
                    Menu("Away") { AwayMenu(session: session, job: job) }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Let the job go ahead without asking for a while, or ask before each step")
                    Spacer(minLength: 0)
                    Button("Discard…", role: .destructive) { confirmsDiscard = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(theme.text3.color)
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.card.color)
                if phase == .working || phase == .starting { WorkSweep(color: phase.color(theme)) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(phase.needsYou ? phase.color(theme).opacity(0.55) : (hovering ? theme.line2.color : theme.line.color), lineWidth: phase.needsYou ? 1.5 : 1))
        .shadow(color: phase.needsYou ? phase.color(theme).opacity(0.18) : .clear, radius: 10, y: 2)
        .animation(.easeInOut(duration: 0.35), value: phase.needsYou)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { session.showJob(job.id) }
        .jobConfirmations(session: session, job: job, merge: $confirmsMerge, discard: $confirmsDiscard)
    }
}

/// A bright line sweeping along the top of a working job's card.
private struct WorkSweep: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geometry in
                let width = geometry.size.width
                let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                LinearGradient(colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width * 0.35, height: 2)
                    .offset(x: -width * 0.35 + progress * width * 1.35)
            }
        }
        .frame(height: 2)
    }
}

/// Files touched, as a bar of insertions against deletions, and the summary.
private struct ChangeBar: View {
    @Environment(\.theme) private var theme
    let changes: JobChanges

    var body: some View {
        HStack(spacing: 8) {
            let total = max(changes.insertions + changes.deletions, 1)
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    Rectangle().fill(theme.green.color)
                        .frame(width: geometry.size.width * CGFloat(changes.insertions) / CGFloat(total))
                    Rectangle().fill(theme.red.color)
                        .frame(width: geometry.size.width * CGFloat(changes.deletions) / CGFloat(total))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.track.color)
                .clipShape(Capsule())
            }
            .frame(width: 60, height: 5)
            .opacity(changes.isEmpty ? 0.4 : 1)
            Text(changes.summary).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                .contentTransition(.numericText())
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: changes)
    }
}

/// "4 min", ticking.
private struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let minutes = Int(context.date.timeIntervalSince(since) / 60)
            Text(minutes < 1 ? "just now" : minutes < 60 ? "\(minutes) min" : minutes < 60 * 24 ? "\(minutes / 60) h \(minutes % 60) min" : since.relative)
                .monospacedDigit()
        }
    }
}

private struct FinishedRow: View {
    @Environment(\.theme) private var theme
    let session: Session
    let job: JobRecord

    var body: some View {
        HStack(spacing: 10) {
            JobPulse(phase: job.outcome == .merged ? .merged : .discarded, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color).lineLimit(1)
                Text("\(job.outcome == .merged ? "Merged" : "Discarded") \((job.closed ?? job.created).relative) · \(job.branch)")
                    .font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(1)
            }
            Spacer(minLength: 8)
            IconButton(symbol: "xmark", label: "Remove from the list", size: 10) { session.jobs.forget(job.id) }
        }
    }
}

/// A job type on the board: what it does, when it starts, what it may touch, and a way to
/// start it (or let it start itself).
private struct JobTypeRow: View {
    @Environment(\.theme) private var theme
    let session: Session
    let type: JobType

    var body: some View {
        let jobs = session.jobs
        let watching = type.trigger == .ciFailed && jobs.watching.contains(type.id)
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if watching { Radar(color: theme.green.color).frame(width: 44, height: 44) }
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((watching ? theme.green : theme.accent).color.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: JobTypeIcon.symbol(for: type))
                    .font(.dante(size: 13, weight: .semibold))
                    .foregroundStyle((watching ? theme.green : theme.accent).color)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(type.name).font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                    if type.isBuiltIn {
                        Text("BUILT IN").font(.dante(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(theme.text3.color)
                    }
                }
                if !type.summary.isEmpty {
                    Text(type.summary).font(.dante(size: 12)).foregroundStyle(theme.text2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { chips }
                    VStack(alignment: .leading, spacing: 5) { chips }
                }
                if watching { watchStatus }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 3)
        .animation(.snappy, value: watching)
    }

    @ViewBuilder private var chips: some View {
        Chip(text: type.trigger == .ciFailed ? "When CI fails\(type.branches.isEmpty ? "" : " on " + type.branches.joined(separator: ", "))" : (type.input == .task ? "From a task" : "By hand"),
             symbol: type.trigger == .ciFailed ? "bolt" : "hand.point.up.left")
        if let minutes = type.awayMinutes { Chip(text: "Away \(AwayMenu.label(minutes))", symbol: "figure.walk") }
        if !type.paths.isEmpty { Chip(text: type.paths.joined(separator: " "), symbol: "folder", mono: true) }
        if !type.commands.isEmpty {
            Chip(text: type.commands.joined(separator: ", "), symbol: "terminal", mono: true)
                .help("Commands it may run while away, besides building, testing and committing")
        }
    }

    private var watchStatus: some View {
        let jobs = session.jobs
        return Group {
            if let problem = jobs.ciProblem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(theme.amber.color)
            } else if let checked = jobs.ciChecked {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text("Watching \(session.branch ?? "the current branch") · checked \(Self.ago(checked, now: context.date))")
                        .foregroundStyle(theme.green.color)
                }
            } else {
                Text("Looking at CI…").foregroundStyle(theme.text3.color)
            }
        }
        .font(.dante(size: 11.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 60 ? "just now" : "\(seconds / 60) min ago"
    }

    @ViewBuilder private var actions: some View {
        let jobs = session.jobs
        HStack(spacing: 8) {
            if type.trigger == .ciFailed {
                Toggle(isOn: Binding(get: { jobs.watching.contains(type.id) }, set: { jobs.setWatching(type.id, $0) })) {
                    Text("Watch CI").font(.dante(size: 11.5, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                .help("While this window is open, Dante checks CI every minute and a half and starts this job when a run on your branch fails. Only on this Mac.")
            } else {
                Button("Start…") {
                    withAnimation(.snappy) { jobs.draftType = type.id }
                }
                .buttonStyle(DanteButtonStyle())
                .help("Choose it in New job above")
            }
            Menu {
                Button(type.isBuiltIn ? "Copy into .dante/jobs and Edit" : "Edit") { edit() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func edit() {
        guard let root = session.workspace?.url else { return }
        do {
            session.open(file: try type.copy(into: root))
            session.jobs.reloadTypes()
        } catch {
            session.errorMessage = "Couldn’t write the job type: \(error.localizedDescription)"
        }
    }
}

/// Rings spreading out from a watching job type, like a radar ping.
private struct Radar: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                for ring in 0..<3 {
                    let phase = (time / 2.4 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    let radius = 12 + phase * (size.width / 2 - 12)
                    let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
                    canvas.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.5 * (1 - phase))), lineWidth: 1.2)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
