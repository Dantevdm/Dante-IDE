import DanteKit
import SwiftUI

extension JobPhase {
    func color(_ theme: Theme) -> Color {
        switch self {
        case .starting, .working: theme.accent.color
        case .waiting, .asking: theme.amber.color
        case .ready, .merged: theme.green.color
        case .failed: theme.red.color
        case .paused, .discarded: theme.text3.color
        }
    }
}

/// A job's state as a small living mark: a turning arc while it works, ripples while it waits
/// for you, a check drawn in when it's ready.
struct JobPulse: View {
    @Environment(\.theme) private var theme
    let phase: JobPhase
    var size: CGFloat = 14
    @State private var drawn = false

    var body: some View {
        let color = phase.color(theme)
        ZStack {
            switch phase {
            case .starting, .working:
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                    ZStack {
                        Circle().strokeBorder(color.opacity(0.18), lineWidth: max(1.5, size * 0.13))
                        Circle()
                            .trim(from: 0, to: 0.62)
                            .stroke(AngularGradient(colors: [color.opacity(0), color], center: .center, startAngle: .zero, endAngle: .degrees(223)),
                                    style: StrokeStyle(lineWidth: max(1.5, size * 0.13), lineCap: .round))
                            .rotationEffect(.degrees(turn * 360))
                            .padding(max(0.75, size * 0.065))
                        Circle().fill(color).frame(width: size * 0.28, height: size * 0.28)
                            .scaleEffect(0.8 + 0.25 * sin(turn * .pi * 2))
                    }
                }
            case .waiting, .asking:
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<2) { ring in
                            let progress = (t / 1.6 + Double(ring) / 2).truncatingRemainder(dividingBy: 1)
                            Circle().stroke(color, lineWidth: 1.2)
                                .scaleEffect(0.45 + progress * 0.75)
                                .opacity(1 - progress)
                        }
                        Circle().fill(color).frame(width: size * 0.48, height: size * 0.48)
                    }
                }
            case .ready, .merged:
                ZStack {
                    Circle().fill(color.opacity(0.16))
                    CheckShape()
                        .trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(color, style: StrokeStyle(lineWidth: max(1.4, size * 0.12), lineCap: .round, lineJoin: .round))
                        .padding(size * 0.27)
                }
                .onAppear { withAnimation(.easeOut(duration: 0.45).delay(0.1)) { drawn = true } }
            case .failed:
                Image(systemName: "exclamationmark").font(.dante(size: size * 0.62, weight: .bold)).foregroundStyle(color)
                    .frame(width: size, height: size)
                    .background(Circle().fill(color.opacity(0.16)))
            case .paused:
                Image(systemName: "pause.fill").font(.dante(size: size * 0.45)).foregroundStyle(color)
                    .frame(width: size, height: size)
                    .background(Circle().strokeBorder(color.opacity(0.5), lineWidth: 1))
            case .discarded:
                Image(systemName: "xmark").font(.dante(size: size * 0.45, weight: .semibold)).foregroundStyle(color)
                    .frame(width: size, height: size)
                    .background(Circle().strokeBorder(color.opacity(0.5), lineWidth: 1))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(phase.label)
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return path
    }
}

// MARK: The panel

/// Above the conversation while jobs exist: the main conversation and each job, to switch
/// between, each with its state.
struct JobStrip: View {
    @Environment(\.theme) private var theme
    let session: Session
    @Namespace private var namespace

    var body: some View {
        let jobs = session.jobs
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tab(id: nil, title: "Main", waiting: session.claude?.pendingApprovals.count ?? 0) {
                    AgentIcon(engine: session.claude?.engine ?? .claude, size: 11, isWorking: session.claude?.state == .working)
                }
                ForEach(jobs.open) { job in
                    let phase = jobs.phase(of: job.id)
                    tab(id: job.id, title: job.title, waiting: jobs.sessions[job.id]?.pendingApprovals.count ?? 0) {
                        JobPulse(phase: phase, size: 11)
                    }
                    .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
                }
                if let starting = jobs.starting {
                    HStack(spacing: 5) {
                        JobPulse(phase: .starting, size: 11)
                        Text(starting).lineLimit(1)
                    }
                    .font(.dante(size: 11.5))
                    .foregroundStyle(theme.text3.color)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: jobs.open.map(\.id))
            .animation(.snappy(duration: 0.25), value: session.shownJob)
        }
        .frame(height: 32)
        .padding(.bottom, 6)
    }

    private func tab<Icon: View>(id: String?, title: String, waiting: Int, @ViewBuilder icon: () -> Icon) -> some View {
        let selected = session.shownJob == id
        return Button { session.showJob(id) } label: {
            HStack(spacing: 5) {
                icon()
                Text(title)
                    .font(.dante(size: 11.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if waiting > 0, !selected {
                    Text("\(waiting)")
                        .font(.dante(size: 10, weight: .bold)).monospacedDigit()
                        .foregroundStyle(theme.onAccent.color)
                        .padding(.horizontal, 5).frame(height: 15)
                        .background(Capsule().fill(theme.amber.color))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(selected ? theme.text.color : theme.text2.color)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6).fill(theme.card.color)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.line2.color))
                        .matchedGeometryEffect(id: "tab", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(id == nil ? "The window’s own conversation" : "\(title): \(session.jobs.phase(of: id!).label)")
    }
}

/// The shown job: its branch, what it changed, and merging or throwing it away.
struct JobBanner: View {
    @Environment(\.theme) private var theme
    let session: Session
    let job: JobRecord
    @State private var confirmsMerge = false
    @State private var confirmsDiscard = false

    var body: some View {
        let jobs = session.jobs
        let changes = jobs.changes[job.id] ?? JobChanges()
        let busy = jobs.busy.contains(job.id)
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").font(.dante(size: 10.5)).foregroundStyle(theme.text3.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.branch).font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text2.color)
                    .lineLimit(1).truncationMode(.middle)
                Text(changes.summary).font(.dante(size: 10.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: changes)
            }
            .layoutPriority(-1)
            Spacer(minLength: 4)
            AwayChip(job: job, now: jobs.now)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button("Merge") { confirmsMerge = true }
                    .disabled(changes.isEmpty || session.jobs.sessions[job.id]?.state == .working)
                    .help("Commit what’s left and merge \(job.branch) into the branch checked out here")
                Menu {
                    AwayMenu(session: session, job: job)
                    Divider()
                    Button("Show on the Jobs board") { session.area = .jobs }
                    Button("Show the worktree in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.worktreeURL]) }
                    Divider()
                    Button("Discard the job…", role: .destructive) { confirmsDiscard = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.raised.color.opacity(0.6))
        .jobConfirmations(session: session, job: job, merge: $confirmsMerge, discard: $confirmsDiscard)
        .task(id: job.id) { await session.jobs.refreshChanges(of: job.id) }
    }
}

extension View {
    /// The questions before merging or discarding a job.
    func jobConfirmations(session: Session, job: JobRecord, merge: Binding<Bool>, discard: Binding<Bool>) -> some View {
        let into = session.branch ?? "the checked-out branch"
        return self
            .confirmationDialog("Merge “\(job.title)” into \(into)?", isPresented: merge) {
                Button("Merge") { session.mergeJob(job.id) }
            } message: {
                Text("Dante commits anything the job left uncommitted, merges \(job.branch) into \(into) and removes the job’s worktree. If your own uncommitted edits touch the same files, git stops and nothing is lost.")
            }
            .confirmationDialog("Discard “\(job.title)”?", isPresented: discard) {
                Button("Discard", role: .destructive) { session.discardJob(job.id) }
            } message: {
                Text("The job’s edits, its worktree and the branch \(job.branch) are deleted. This can’t be undone.")
            }
    }
}

/// Starting a job: what to do, and who does it.
struct NewJobForm: View {
    @Environment(\.theme) private var theme
    let session: Session
    var onStart: () -> Void = {}
    @State private var brief = ""
    @State private var engine = Preferences.shared.agentEngine
    @State private var away = false
    @State private var awayMinutes = 30
    @FocusState private var focused: Bool

    private var canStart: Bool {
        !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.jobs.starting == nil && session.jobs.unavailable == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reason = session.jobs.unavailable {
                Label(reason, systemImage: "exclamationmark.triangle").font(.dante(size: 12)).foregroundStyle(theme.amber.color)
            }
            ZStack(alignment: .topLeading) {
                if brief.isEmpty {
                    Text("What should the job do? It works on its own branch, so you can keep going here.")
                        .font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
                        .padding(.horizontal, 5).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $brief)
                    .font(.dante(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 64, maxHeight: 140)
            }
            .padding(4)
            .background(theme.raised.color, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? theme.accentLine.color : theme.line.color))
            HStack(spacing: 8) {
                if Session.codexPath != nil {
                    Picker("Agent", selection: $engine) {
                        ForEach(AgentEngine.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle(isOn: $away.animation(.snappy)) {
                    Text("Away").font(.dante(size: 11.5, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                .help("Lets the job go ahead without asking: edits in its worktree and building, testing and committing, within this project’s rules. Flagged files, other commands and questions still wait for you, and pushing, merging and deploying are never allowed.")
                if away {
                    Picker("For", selection: $awayMinutes) {
                        ForEach(AwayMenu.choices, id: \.self) { Text(AwayMenu.label($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .transition(.scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
                }
                Text(startsFrom).font(.dante(size: 11)).foregroundStyle(theme.text3.color).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    session.startJob(brief, engine: engine, awayMinutes: away ? awayMinutes : nil)
                    brief = ""
                    onStart()
                } label: {
                    AgentButtonLabel(engine: engine, title: "Start job", filled: true)
                }
                .buttonStyle(DanteButtonStyle(primary: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canStart)
            }
            if let failure = session.jobs.startFailure {
                Text(failure).font(.dante(size: 11.5)).foregroundStyle(theme.red.color).fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { session.jobs.clearStartFailure() }
            }
        }
        .onAppear { focused = true }
    }

    private var startsFrom: String {
        let branch = session.branch.map { "the last commit on \($0)" } ?? "the last commit"
        let dirty = (session.git.status?.changes.isEmpty == false) ? "; your uncommitted edits stay here" : ""
        return "Starts from \(branch)\(dirty)."
    }
}

/// The panel header's button for starting a job.
struct NewJobButton: View {
    let session: Session
    @State private var shows = false

    var body: some View {
        IconButton(symbol: "square.stack.3d.up", label: "New job: hand work to an agent that runs on its own branch") { shows.toggle() }
            .popover(isPresented: $shows, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("New job").font(.dante(size: 13, weight: .semibold))
                    NewJobForm(session: session) { shows = false }
                }
                .padding(14)
                .frame(width: 400)
            }
    }
}

/// Approvals and questions from the conversations you aren't looking at.
struct InboxButton: View {
    @Environment(\.theme) private var theme
    let session: Session
    @State private var shows = false

    var body: some View {
        let elsewhere = session.inbox.filter { $0.job != session.shownJob }
        if !elsewhere.isEmpty {
            Button { shows.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "tray.full").font(.dante(size: 11.5, weight: .medium))
                    Text("\(elsewhere.count)").font(.dante(size: 11, weight: .bold)).monospacedDigit()
                        .contentTransition(.numericText())
                }
                .foregroundStyle(theme.onAccent.color)
                .padding(.horizontal, 7).frame(height: 22)
                .background(Capsule().fill(theme.amber.color))
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Waiting in other conversations")
            .transition(.scale(scale: 0.5).combined(with: .opacity))
            .popover(isPresented: $shows, arrowEdge: .bottom) {
                InboxList(session: session, items: elsewhere) { shows = false }
                    .frame(width: 380)
            }
        }
    }
}

struct InboxList: View {
    @Environment(\.theme) private var theme
    let session: Session
    let items: [JobInbox.Item]
    var showsTitle = true
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                Text("Waiting for you").font(.dante(size: 13, weight: .semibold)).padding(14)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        InboxRow(session: session, item: item, dismiss: dismiss)
                        Rectangle().fill(theme.line.color).frame(height: 1)
                    }
                }
            }
            .frame(maxHeight: 420)
        }
    }
}

private struct InboxRow: View {
    @Environment(\.theme) private var theme
    let session: Session
    let item: JobInbox.Item
    let dismiss: () -> Void

    var body: some View {
        let job = item.job.flatMap { session.jobs.record($0) }
        let root = job?.worktreeURL ?? session.workspace?.url ?? URL(filePath: "/")
        let target = job.map { JobPlan.shortened(item.tool.target(in: root), worktree: $0.worktree) } ?? item.tool.target(in: root)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let job = item.job {
                    JobPulse(phase: session.jobs.phase(of: job), size: 10)
                } else {
                    AgentIcon(engine: session.claude?.engine ?? .claude, size: 10)
                }
                Text(item.from).font(.dante(size: 11.5, weight: .medium)).foregroundStyle(theme.text2.color).lineLimit(1)
            }
            Text([item.isQuestion ? "Asks" : item.tool.verb, item.isQuestion ? "a question" : target].filter { !$0.isEmpty }.joined(separator: " "))
                .font(.dante(size: 12.5, design: item.isQuestion ? .default : .monospaced))
                .foregroundStyle(theme.text.color)
                .lineLimit(2)
            if let note = item.tool.securityNote {
                Label(note, systemImage: "exclamationmark.shield").font(.dante(size: 11)).foregroundStyle(theme.red.color).lineLimit(2)
            }
            HStack(spacing: 8) {
                if !item.isQuestion {
                    Button("Approve") { session.conversation(of: item)?.approve(item.tool.id) }
                        .buttonStyle(DanteButtonStyle(primary: true))
                    Button("Decline") { session.conversation(of: item)?.decline(item.tool.id) }
                        .buttonStyle(DanteButtonStyle())
                }
                Button(item.isQuestion ? "Answer…" : "Show") {
                    session.showJob(item.job)
                    dismiss()
                }
                .buttonStyle(DanteButtonStyle(primary: item.isQuestion))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Away mode's choices for a job: go ahead on its own for a while, or ask for each step.
struct AwayMenu: View {
    let session: Session
    let job: JobRecord

    static let choices = [15, 30, 60, 120]

    static func label(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
    }

    var body: some View {
        Menu(job.isAway ? (job.outOfTime() ? "Away time’s up: give it more" : "Away for longer") : "Go ahead without asking") {
            ForEach(Self.choices, id: \.self) { minutes in
                Button("For \(Self.label(minutes))") { session.jobs.setAway(job.id, minutes: minutes) }
            }
        }
        if job.isAway {
            Button("Ask before each step") { session.jobs.setAway(job.id, minutes: nil) }
        }
    }
}

/// A job's away time: a ring that empties as it runs, and what's left.
struct AwayChip: View {
    @Environment(\.theme) private var theme
    let job: JobRecord
    let now: Date

    var body: some View {
        if let until = job.awayUntil, let minutes = job.awayMinutes {
            let left = max(0, until.timeIntervalSince(now))
            let fraction = left / Double(minutes * 60)
            let color = left > 0 ? theme.accent.color : theme.amber.color
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(color.opacity(0.2), lineWidth: 2)
                    Circle().trim(from: 0, to: fraction)
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth(duration: 0.8), value: fraction)
                }
                .frame(width: 11, height: 11)
                Text(left > 0 ? "Away · \(Self.remaining(left))" : "Away time’s up")
                    .font(.dante(size: 11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.1)))
            .fixedSize()
            .help(left > 0 ? "Going ahead without asking until \(until.formatted(date: .omitted, time: .shortened)), within this project’s rules"
                           : "Each step now waits for you. Give it more time from the job’s menu.")
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes < 60 ? "\(minutes) min left" : "\(minutes / 60) h \(minutes % 60) min left"
    }
}
