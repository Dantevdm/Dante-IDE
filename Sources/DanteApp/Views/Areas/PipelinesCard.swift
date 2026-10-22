import AppKit
import DanteKit
import SwiftUI

/// Ship › Release's pipelines: a lane per environment (non-prod, prod) with the latest run's
/// stages moving while it runs, what failed and how to heal it, and the history.
struct PipelinesCard: View {
    @Environment(\.theme) private var theme
    @Bindable var preferences = Preferences.shared
    let session: Session
    @State private var token = ""
    @State private var showsAll = false
    @State private var expanded: Int?
    @State private var confirmingProd: PipelineRun?

    private var monitor: PipelineMonitor { session.pipelines }

    private var title: String {
        switch monitor.source {
        case .azure: "Pipelines · Azure DevOps"
        case .github: "Pipelines · GitHub Actions"
        case nil: "Pipelines"
        }
    }

    var body: some View {
        Card(title) {
            HStack(spacing: 12) {
                if monitor.loading { ProgressView().controlSize(.mini) }
                else if let checked = monitor.checked {
                    Text(monitor.isActive ? "Watching · every 20 s" : "Checked \(checked.relative)")
                        .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                }
                Toggle("Notify me", isOn: $preferences.notifiesOnPipelines)
                    .toggleStyle(.checkbox).font(.dante(size: 12))
                    .help("A notification when a run starts or finishes, with a sound when one fails or prod finishes.")
                    .onChange(of: preferences.notifiesOnPipelines) { _, on in
                        if on { Task { _ = await Session.requestNotificationPermission() } }
                    }
                Toggle("Heal by itself", isOn: Binding(get: { monitor.autoHeals }, set: { monitor.autoHeals = $0 }))
                    .toggleStyle(.checkbox).font(.dante(size: 12))
                    .help("When a non-prod run fails: a flake (a timeout, the network, a busy registry) runs its failed stage once more, anything else starts a job for \(session.agentName) to find the cause and fix it. Prod is never touched without you. On this Mac only.")
                Button { monitor.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(theme.text2.color).help("Look now")
                if let web = webPage { LinkButton("Open") { NSWorkspace.shared.open(web) } }
            }
        } content: {
            if monitor.needsToken, case .azure(let remote) = monitor.source {
                tokenSetup(remote)
            } else if let problem = monitor.problem {
                Text(problem).font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
                if case .azure = monitor.source {
                    Button("Use another token") { monitor.forgetToken() }.buttonStyle(DanteButtonStyle())
                }
            } else if monitor.runs.isEmpty {
                Text(monitor.checked == nil ? "Looking for runs…" : "No runs yet.").font(.dante(size: 12.5)).foregroundStyle(theme.text3.color)
            }
            // What was seen before still shows while the service can't be reached.
            if !monitor.runs.isEmpty {
                lanes
                history
            }
        }
        .confirmationDialog("Run \(confirmingProd?.failedStage?.name ?? "the failed stage") in production again?",
                            isPresented: Binding(get: { confirmingProd != nil }, set: { if !$0 { confirmingProd = nil } }), presenting: confirmingProd) { run in
            Button("Run it again in prod") { Task { await monitor.retry(run) } }
            Button("Cancel", role: .cancel) {}
        } message: { run in
            Text("\(run.pipeline) \(run.number) on \(run.branch). It deploys with what's in that run, not with changes made since.")
        }
    }

    private var webPage: URL? {
        if case .azure(let remote) = monitor.source { return remote.pipelinesPage }
        return monitor.runs.first?.url?.deletingLastPathComponent()
    }

    // MARK: Token

    private func tokenSetup(_ remote: AzureDevOpsRemote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dante reads \(remote.project)'s pipeline runs from Azure DevOps with a personal access token: Build, Read & execute (execute lets it re-run a failed stage when you ask). It's kept in this Mac's Keychain and only sent to dev.azure.com.")
                .font(.dante(size: 12.5)).foregroundStyle(theme.text2.color).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("Personal access token", text: $token)
                    .textFieldStyle(.roundedBorder).font(.dante(size: 12.5)).frame(maxWidth: 360)
                    .onSubmit(save)
                Button("Save", action: save).buttonStyle(DanteButtonStyle(primary: true)).disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                LinkButton("Make one in \(remote.organization)") { NSWorkspace.shared.open(remote.tokensPage) }
            }
        }
    }

    private func save() {
        monitor.saveToken(token)
        token = ""
    }

    // MARK: Lanes

    private var lanes: some View {
        let lanes = monitor.history.lanes
        return HStack(alignment: .top, spacing: 12) {
            ForEach(lanes) { lane in
                LaneTile(session: session, lane: lane, failures: monitor.failures[lane.latest.id] ?? [],
                         retrying: monitor.retrying.contains(lane.latest.id), retry: { retry($0) })
            }
        }
    }

    private func retry(_ run: PipelineRun) {
        if run.environment == .prod { confirmingProd = run } else { Task { await monitor.retry(run) } }
    }

    // MARK: History

    private var history: some View {
        let runs = showsAll ? monitor.runs : Array(monitor.runs.prefix(8))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Eyebrow("History")
                Spacer()
                if monitor.runs.count > 8 {
                    LinkButton(showsAll ? "Fewer" : "All \(monitor.runs.count)") { withAnimation(.snappy) { showsAll.toggle() } }
                }
            }
            RowList(data: runs, padding: 7) { run in
                VStack(alignment: .leading, spacing: 8) {
                    Button { withAnimation(.snappy) { expanded = expanded == run.id ? nil : run.id } } label: {
                        HStack(spacing: 10) {
                            RunDot(status: run.status)
                            EnvironmentChip(environment: run.environment)
                            Text(run.pipeline).font(.dante(size: 12.5)).foregroundStyle(theme.text.color).lineLimit(1)
                            Text(run.number).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
                            Text(run.branch).font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
                            Spacer()
                            Text(run.reason).font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
                            Text(run.duration().map(Self.duration) ?? "").font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color)
                                .frame(width: 56, alignment: .trailing)
                            Text(run.queued?.relative ?? "").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).frame(width: 84, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded == run.id {
                        RunDetail(session: session, run: run, failures: monitor.failures[run.id] ?? [],
                                  retrying: monitor.retrying.contains(run.id), retry: { retry($0) })
                            .padding(.leading, 17)
                    }
                }
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total)s" : total < 3600 ? "\(total / 60)m \(total % 60)s" : "\(total / 3600)h \(total % 3600 / 60)m"
    }
}

/// An environment's latest run, its stages and where it stands.
private struct LaneTile: View {
    @Environment(\.theme) private var theme
    let session: Session
    let lane: PipelineHistory.Lane
    let failures: [PipelineFailure]
    let retrying: Bool
    let retry: (PipelineRun) -> Void

    var body: some View {
        let run = lane.latest
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                EnvironmentChip(environment: lane.environment)
                Text(run.pipeline).font(.dante(size: 12.5, weight: .semibold)).foregroundStyle(theme.text.color).lineLimit(1)
                Spacer(minLength: 6)
                RunDot(status: run.status)
                Text(run.status.title).font(.dante(size: 12, weight: .medium)).foregroundStyle(RunDot.color(run.status, theme: theme))
            }
            Text([run.number, run.branch, run.commit.isEmpty ? nil : String(run.commit.prefix(7)), run.queued?.relative].compactMap { $0 }.joined(separator: " · "))
                .font(.dante(size: 11.5, design: .monospaced)).foregroundStyle(theme.text3.color).lineLimit(1)
            if !run.stages.isEmpty { StageTrack(stages: run.stages) }
            if run.status == .failed {
                FailurePanel(session: session, run: run, failures: failures, retrying: retrying, retry: retry)
            }
            HStack(spacing: 12) {
                if let good = lane.lastGood, good.id != run.id {
                    Label("Last good \(good.finished?.relative ?? good.queued?.relative ?? "")\(good.commit.isEmpty ? "" : " · \(good.commit.prefix(7))")", systemImage: "checkmark.circle")
                }
                if lane.finished > 0 { Text("\(lane.succeeded) of \(lane.finished) passed") }
                if let typical = lane.typicalDuration { Text("usually \(PipelinesCard.duration(typical))") }
            }
            .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.raised.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(run.status == .failed ? theme.red.color.opacity(0.4) : run.status.isActive ? theme.accentLine.color : theme.line.color))
    }
}

/// A run's stages and, when it failed, what went wrong.
private struct RunDetail: View {
    let session: Session
    let run: PipelineRun
    let failures: [PipelineFailure]
    let retrying: Bool
    let retry: (PipelineRun) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !run.stages.isEmpty { StageTrack(stages: run.stages) }
            if run.status == .failed { FailurePanel(session: session, run: run, failures: failures, retrying: retrying, retry: retry) }
            HStack(spacing: 12) {
                if !run.requestedBy.isEmpty { Text("By \(run.requestedBy)") }
                if let file = run.file { Text(file).font(.dante(size: 11.5, design: .monospaced)) }
                Spacer()
                if let url = run.url { LinkButton("Open the run") { NSWorkspace.shared.open(url) } }
            }
            .font(.dante(size: 11.5)).foregroundStyle(Color.secondary)
        }
    }
}

/// Why a run failed, read from its timeline and logs, with what to do about it.
private struct FailurePanel: View {
    @Environment(\.theme) private var theme
    let session: Session
    let run: PipelineRun
    let failures: [PipelineFailure]
    let retrying: Bool
    let retry: (PipelineRun) -> Void
    @State private var loaded: [PipelineFailure]?
    @State private var showsLog = false

    private var shown: [PipelineFailure] { loaded ?? failures }
    private var transient: Bool { !shown.isEmpty && shown.allSatisfy(\.looksTransient) }
    private var github: Bool { session.pipelines.source == .github }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.red.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(shown.first.map { $0.place.isEmpty ? "A step failed" : $0.place } ?? (run.failedStage.map { "\($0.name) failed" } ?? "It failed"))
                        .font(.dante(size: 12.5, weight: .medium)).foregroundStyle(theme.text.color)
                    if let headline = shown.first?.headline, !headline.isEmpty {
                        Text(headline).font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text2.color)
                            .lineLimit(3).textSelection(.enabled)
                    }
                    if transient {
                        Text("Looks like a flake (the network, a timeout or a busy service): running it again will probably work.")
                            .font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    }
                }
            }
            HStack(spacing: 8) {
                if transient {
                    retryButton(primary: true)
                    healButton(primary: false)
                } else {
                    healButton(primary: true)
                    retryButton(primary: false)
                }
                Spacer()
                if shown.contains(where: { !$0.log.isEmpty }) {
                    LinkButton(showsLog ? "Hide the log" : "Show the log") { withAnimation(.snappy) { showsLog.toggle() } }
                }
            }
            if showsLog {
                ScrollView {
                    Text(shown.map { "── \($0.place)\n\($0.log)" }.joined(separator: "\n\n"))
                        .font(.dante(size: 11, design: .monospaced)).foregroundStyle(theme.text2.color)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.codeBackground.color))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.red.color.opacity(0.06)))
        .task(id: run.id) {
            guard !github else { return }
            loaded = await session.pipelines.loadFailures(run)
        }
    }

    private func healButton(primary: Bool) -> some View {
        Button { Task { await session.pipelines.heal(run) } } label: { ClaudeLabel("Heal it") }
            .buttonStyle(DanteButtonStyle(primary: primary))
            .help("\(session.agentName) reads the log and the pipeline file, says what went wrong, and fixes what's in the repo\(session.jobs.unavailable == nil ? " in a job of its own" : ""). It never deploys or pushes.")
    }

    private func retryButton(primary: Bool) -> some View {
        Button { retry(run) } label: {
            Label(retrying ? "Starting…" : github ? "Re-run failed jobs" : "Re-run \(run.failedStage?.name ?? "failed stage")", systemImage: "arrow.clockwise")
                .lineLimit(1)
        }
        .buttonStyle(DanteButtonStyle(primary: primary))
        .disabled(retrying || (!github && run.failedStage == nil))
    }
}

/// Stages as chips joined by a line; the running one pulses and a packet travels the line
/// into it, as links do in the Infra view.
struct StageTrack: View {
    @Environment(\.theme) private var theme
    let stages: [PipelineStage]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !stages.contains { $0.state.isActive })) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            ViewThatFits(in: .horizontal) {
                track(phase: phase, names: true)
                track(phase: phase, names: false)
            }
        }
    }

    private func track(phase: Double, names: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                if index > 0 { connector(into: stage, phase: phase) }
                chip(stage, phase: phase, names: names)
            }
        }
    }

    private func chip(_ stage: PipelineStage, phase: Double, names: Bool) -> some View {
        let color = RunDot.color(stage.state, theme: theme)
        let pulse = stage.state == .running ? 0.5 + 0.5 * sin(phase * 4) : 0
        return HStack(spacing: 5) {
            Image(systemName: Self.symbol(stage.state)).font(.dante(size: 10, weight: .semibold))
            if names { Text(stage.name).font(.dante(size: 11.5)).lineLimit(1) }
        }
        .foregroundStyle(stage.state == .skipped || stage.state == .queued ? theme.text3.color : color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(color.opacity(stage.state == .queued || stage.state == .skipped ? 0.06 : 0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35 + 0.5 * pulse)))
        .shadow(color: color.opacity(0.35 * pulse), radius: 6 * pulse)
        .help("\(stage.name): \(stage.state.title)")
    }

    private func connector(into stage: PipelineStage, phase: Double) -> some View {
        let reached = stage.state != .queued && stage.state != .skipped
        return ZStack(alignment: .leading) {
            Rectangle().fill(reached ? RunDot.color(stage.state, theme: theme).opacity(0.5) : theme.line.color).frame(height: 1.5)
            if stage.state == .running {
                GeometryReader { geometry in
                    Circle().fill(theme.accent.color).frame(width: 5, height: 5)
                        .offset(x: (phase.truncatingRemainder(dividingBy: 1.2) / 1.2) * max(0, geometry.size.width - 5), y: geometry.size.height / 2 - 2.5)
                }
            }
        }
        .frame(minWidth: 14, maxWidth: 28, maxHeight: 22)
    }

    static func symbol(_ status: PipelineRun.Status) -> String {
        switch status {
        case .queued: "circle.dotted"
        case .running: "circle.dashed"
        case .succeeded: "checkmark"
        case .failed: "xmark"
        case .canceled: "slash.circle"
        case .partial: "exclamationmark"
        case .skipped: "arrow.uturn.right"
        }
    }
}

struct RunDot: View {
    @Environment(\.theme) private var theme
    let status: PipelineRun.Status

    var body: some View {
        StatusDot(color: Self.color(status, theme: theme))
            .overlay(status == .running ? Circle().strokeBorder(Self.color(status, theme: theme).opacity(0.4), lineWidth: 2).scaleEffect(1.8) : nil)
    }

    static func color(_ status: PipelineRun.Status, theme: Theme) -> Color {
        switch status {
        case .running, .queued: theme.accent.color
        case .succeeded: theme.green.color
        case .failed: theme.red.color
        case .partial: theme.amber.color
        case .canceled, .skipped: theme.text3.color
        }
    }
}

struct EnvironmentChip: View {
    @Environment(\.theme) private var theme
    let environment: PipelineEnvironment

    var body: some View {
        Text(environment.title)
            .font(.dante(size: 10.5, weight: .semibold))
            .foregroundStyle(environment == .prod ? theme.red.color : environment == .nonProd ? theme.accent.color : theme.text3.color)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill((environment == .prod ? theme.red.color : environment == .nonProd ? theme.accent.color : theme.text3.color).opacity(0.1)))
    }
}
