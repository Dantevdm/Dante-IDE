import DanteKit
import SwiftUI

/// Health: how the project is doing, live (health checks, a log stream and alarms from
/// `operate:` in project.yaml) or on this Mac (the compose services' health routes and
/// `docker compose logs`), with errors grouped so each can be asked about.
struct RunView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    /// Live is the deployed app (`operate:` in project.yaml); This Mac is the compose services;
    /// Grafana is the project's own, from any of its compose files.
    enum Place: String { case live, local, grafana }

    @State private var latestTag: String?
    @State private var compose: ComposeFile?
    @State private var localChecks: [ProjectInfo.HealthCheck] = []
    @State private var chosen: Place?
    @State private var grafana: GrafanaSetup?

    private var info: ProjectInfo { workspace.info }
    private var hasLive: Bool { !info.checks.isEmpty || info.logsCommand != nil || !info.alarms.isEmpty }
    private var hasLocal: Bool { compose != nil && !(compose?.services.isEmpty ?? true) }
    private var places: [Place] {
        [hasLive ? Place.live : nil, hasLocal ? .local : nil, grafana != nil ? .grafana : nil].compactMap { $0 }
    }
    private var placeKey: String { "health.place." + workspace.url.path }

    /// The chosen place when it has something, else whichever does; This Mac first when the
    /// project has nothing live set up.
    private var place: Place {
        if let chosen, places.contains(chosen) { return chosen }
        return hasLive ? .live : hasLocal || grafana == nil ? .local : .grafana
    }

    /// What's watched for checks and errors: Grafana's view keeps watching This Mac (or Live).
    private var watched: Place { place == .grafana ? (hasLocal ? .local : .live) : place }
    private var checks: [ProjectInfo.HealthCheck] { watched == .live ? info.checks : localChecks }
    private var logsCommand: String? {
        watched == .live ? info.logsCommand : compose.map { LocalHealth.logsCommand(compose: $0) }
    }

    var body: some View {
        AreaPage(
            eyebrow: nil,
            title: "Health",
            subtitle: nil
        ) {
            if let latestTag, place == .live { Chip(text: "\(latestTag) is the latest tag", symbol: "tag") }
            if places.count >= 2 {
                Picker("", selection: Binding(get: { place }, set: { choose($0) })) {
                    if hasLive { Text("Live").tag(Place.live) }
                    if hasLocal { Text("This Mac").tag(Place.local) }
                    if grafana != nil { Text("Grafana").tag(Place.grafana) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Live is the deployed app, from operate: in .dante/project.yaml. This Mac is the compose services running here. Grafana is the project's own dashboards.")
            }
            if !checks.isEmpty, place != .grafana {
                IconButton(symbol: "arrow.clockwise", label: "Check now") { Task { await session.health.poll() } }
            }
        } content: {
            if place == .grafana, let grafana {
                GrafanaPanel(session: session, workspace: workspace, grafana: grafana)
            } else if !hasLive && !hasLocal {
                SetupCard(session: session)
            } else {
                if place == .live, !info.alarms.isEmpty {
                    AlarmsCard(session: session, workspace: workspace, monitor: session.alarms)
                }
                if place == .local, localChecks.isEmpty {
                    Card {
                        Text("No compose service here builds from the repo and publishes a port, so there's nothing to check over HTTP. Docker's own health checks are on Services.")
                            .font(.dante(size: 12.5)).foregroundStyle(theme.text3.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !checks.isEmpty {
                    CardGrid(minimum: 260) {
                        ForEach(checks) { check in
                            CheckCard(check: check, samples: session.health.samples[check.id] ?? [])
                        }
                    }
                    if let down = checks.first(where: { session.health.samples[$0.id]?.last?.isUp == false }) {
                        DownCard(session: session, check: down, sample: session.health.samples[down.id]?.last, local: place == .local)
                    }
                }
                ErrorsCard(session: session, workspace: workspace, local: place == .local)
            }
        }
        .task(id: workspace.revision) {
            chosen = (UserDefaults.standard.string(forKey: placeKey)).flatMap(Place.init(rawValue:))
            let root = workspace.url
            let files = workspace.files
            let loaded = ComposeFile.load(projectRoot: root)
            compose = loaded
            let shell = session.remoteSync == nil ? Shell.environment() : [:]
            // A remote project's Grafana runs on its host, not here.
            let remote = session.remoteSync != nil
            let found = remote ? nil : await Task.detached(priority: .utility) { GrafanaSetup.load(projectRoot: root, shell: shell).first }.value
            if found != grafana { grafana = found }
            localChecks = await Task.detached(priority: .utility) {
                guard let loaded else { return [ProjectInfo.HealthCheck]() }
                return LocalHealth.checks(compose: loaded, files: files) { try? String(contentsOf: root.appending(path: $0), encoding: .utf8) }
            }.value
            latestTag = await GitSnapshot.load(in: workspace.git.root, recentLimit: 1, sinceTagLimit: 1).latestTag
        }
        .task(id: Watched(checks: checks, logs: logsCommand)) {
            session.health.watch(checks)
            if let command = logsCommand {
                if session.logWatch?.command != command {
                    session.logWatch?.stop()
                    session.logWatch = LogWatch(command: command, projectRoot: workspace.url)
                }
            } else {
                session.logWatch?.stop()
                session.logWatch = nil
            }
        }
    }

    private struct Watched: Equatable {
        var checks: [ProjectInfo.HealthCheck]
        var logs: String?
    }

    private func choose(_ next: Place) {
        chosen = next
        UserDefaults.standard.set(next.rawValue, forKey: placeKey)
    }
}

private struct SetupCard: View {
    @Environment(\.theme) private var theme
    let session: Session

    var body: some View {
        EmptyState(
            symbol: "waveform.path.ecg",
            title: "Nothing to watch yet"
        ) {
            Button("Set up with Claude") {
                session.askClaude("Set up the Operate area for this project: add an operate: block to .dante/project.yaml with checks (name and url of each health endpoint), logs (a shell command that streams production logs, for whichever host this project deploys to) and alarms (cloudwatch with profile, region and an alarm name prefix, or a command that prints alarms as JSON). Look at the code and config to work out what exists; ask me for anything you can't find.")
            }
            .buttonStyle(DanteButtonStyle(primary: true))
            .help("Claude adds an operate: block to .dante/project.yaml: health checks (name and url), a log command, and alarms (CloudWatch, or a command that prints them as JSON).")
        }
    }
}

private struct CheckCard: View {
    @Environment(\.theme) private var theme
    let check: ProjectInfo.HealthCheck
    let samples: [HealthMonitor.Sample]

    var body: some View {
        let last = samples.last
        let latencies = samples.compactMap(\.milliseconds)
        let uptime = samples.isEmpty ? nil : Double(samples.count(where: \.isUp)) / Double(samples.count)
        Card(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(check.name).font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                Spacer()
                if let last {
                    HStack(spacing: 5) {
                        StatusDot(color: last.isUp ? theme.green.color : theme.red.color, size: 6)
                        Text(last.status.map { "\($0)" } ?? "down").font(.dante(size: 12)).foregroundStyle(last.isUp ? theme.green.color : theme.red.color)
                    }
                } else {
                    Text("checking…").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(last?.milliseconds.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.dante(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text.color)
                Text("ms").foregroundStyle(theme.text3.color)
                Spacer()
                if let uptime {
                    Text("\(Int((uptime * 100).rounded()))% up").font(.dante(size: 12)).foregroundStyle(uptime >= 0.99 ? theme.text3.color : theme.amber.color)
                }
            }
            Sparkline(values: latencies, color: (last?.isUp ?? true) ? theme.accent.color : theme.red.color)
                .frame(height: 44)
            Text(last?.error ?? check.url.absoluteString)
                .font(.dante(size: 11, design: .monospaced))
                .foregroundStyle(last?.error == nil ? theme.text3.color : theme.red.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct Sparkline: View {
    @Environment(\.theme) private var theme
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let low = values.min(), let high = values.max() else {
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height / 2))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(baseline, with: .color(theme.track.color), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                return
            }
            let range = max(high - low, 1)
            let step = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: size.height - 4 - CGFloat((value - low) / range) * (size.height - 8))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct DownCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let check: ProjectInfo.HealthCheck
    let sample: HealthMonitor.Sample?
    var local = false

    var body: some View {
        Card(accent: true) {
            HStack(spacing: 8) {
                ClaudeSparkIcon()
                Text("\(check.name) is failing its health check").font(.dante(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
            }
            Text(sample?.error ?? sample?.status.map { "Last response: HTTP \($0)" } ?? "No response")
                .font(.dante(size: 12, design: .monospaced))
                .foregroundStyle(theme.text3.color)
            Button("Ask \(session.agentName) what changed") {
                let failure = sample?.error ?? sample?.status.map { "HTTP \($0)" } ?? "no response"
                session.askClaude(local
                    ? "The \(check.name) compose service's health check on this Mac (\(check.url.absoluteString)) is failing: \(failure). Check whether it's running (docker compose ps), read its recent logs (docker compose logs --tail 100 \(check.name)), and look at the health endpoint's code and the compose file. Say what's wrong before changing anything."
                    : "The \(check.name) health check (\(check.url.absoluteString)) is failing: \(failure). Look at recent commits, the health endpoint's code and any deploy config, and suggest what to check first.")
            }
            .buttonStyle(DanteButtonStyle(primary: true))
        }
    }
}

private struct ErrorsCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace
    var local = false

    var body: some View {
        if let watch = session.logWatch {
            Card("Errors · since this window opened") {
                HStack(spacing: 8) {
                    Text(watch.isRunning ? (local ? "following docker compose logs" : "following operate.logs") : (watch.exitMessage ?? ""))
                        .font(.dante(size: 12))
                        .foregroundStyle(theme.text3.color)
                        .lineLimit(1)
                        .help(watch.command)
                    if !watch.isRunning {
                        Button("Restart") {
                            session.logWatch = LogWatch(command: watch.command, projectRoot: workspace.url)
                        }
                        .buttonStyle(DanteButtonStyle())
                    }
                }
            } content: {
                if local, !watch.isRunning, watch.digest.linesSeen == 0 {
                    // `docker compose logs -f` ends at once when nothing has been started.
                    Text("No compose service has run yet, so there are no logs to follow. Start them on Services, then press Restart.")
                        .font(.dante(size: 12.5))
                        .foregroundStyle(theme.text3.color)
                        .fixedSize(horizontal: false, vertical: true)
                } else if watch.digest.issues.isEmpty {
                    Text(watch.digest.linesSeen == 0 ? "Waiting for log lines…" : "No errors in \(watch.digest.linesSeen) lines.")
                        .font(.dante(size: 12.5))
                        .foregroundStyle(theme.text3.color)
                    if let message = watch.exitMessage, watch.digest.linesSeen < 5 {
                        Text(watch.recent.suffix(5).joined(separator: "\n").nonEmpty ?? message)
                            .font(.dante(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.text2.color)
                            .textSelection(.enabled)
                    }
                }
                RowList(data: Array(watch.digest.issues.prefix(12)), padding: 10) { issue in
                    HStack(alignment: .top, spacing: 12) {
                        StatusDot(color: issue.count > 10 ? theme.red.color : theme.amber.color).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.example)
                                .font(.dante(size: 12, design: .monospaced))
                                .foregroundStyle(theme.text.color)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text("last seen \(issue.lastSeen.relative)").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                        }
                        Spacer(minLength: 8)
                        Text("×\(issue.count)").font(.dante(size: 12, design: .monospaced)).foregroundStyle(theme.text2.color)
                        Button("Ask \(session.agentName)") {
                            session.askClaude("This error shows up \(issue.count) times in \(local ? "the compose services' logs on this Mac" : "production logs"):\n\n\(issue.example)\n\nFind where it comes from in the code and propose a fix.")
                        }
                        .buttonStyle(DanteButtonStyle())
                    }
                }
            }
        } else {
            Card("Errors") {
                Text(local ? "No compose file" : "No production logs set up")
                    .font(.dante(size: 12.5))
                    .foregroundStyle(theme.text3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AlarmsCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    let session: Session
    let workspace: Workspace
    let monitor: AlarmMonitor
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        let firing = monitor.alarms.count { $0.state == .alarm }
        Card(firing > 0 ? "Alarms · \(firing) firing" : "Alarms") {
            HStack(spacing: 10) {
                Toggle("Notify me", isOn: $preferences.notifiesOnAlarms)
                    .toggleStyle(.checkbox)
                    .font(.dante(size: 12))
                    .help("A macOS notification when an alarm starts firing, while this project is open")
                    .onChange(of: preferences.notifiesOnAlarms) { _, on in
                        if on { Task { if await !Session.requestNotificationPermission() { preferences.notifiesOnAlarms = false } } }
                    }
                if monitor.isChecking {
                    ProgressView().controlSize(.small)
                } else if let checked = monitor.lastChecked {
                    Text("checked \(checked.relative)").font(.dante(size: 12)).foregroundStyle(theme.text3.color)
                }
                IconButton(symbol: "arrow.clockwise", label: "Check alarms now", size: 11) { Task { await monitor.poll() } }
            }
        } content: {
            ForEach(monitor.errors.sorted(by: { $0.key < $1.key }), id: \.key) { source, message in
                Text("\(source): \(message)")
                    .font(.dante(size: 12))
                    .foregroundStyle(theme.amber.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if monitor.alarms.isEmpty, monitor.errors.isEmpty {
                Text(monitor.lastChecked == nil ? "Reading alarms…" : "No alarms found.")
                    .font(.dante(size: 12.5))
                    .foregroundStyle(theme.text3.color)
            }
            RowList(data: monitor.alarms, padding: 10) { alarm in
                AlarmRow(alarm: alarm,
                         investigate: { session.investigate(alarm) },
                         open: alarm.url.map { url in { openURL(url) } })
            }
        }
    }
}

private struct AlarmRow: View {
    @Environment(\.theme) private var theme
    let alarm: Alarm
    let investigate: () -> Void
    let open: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(color: color).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(alarm.name).font(.dante(size: 13, weight: .medium)).foregroundStyle(theme.text.color)
                    Text(label).font(.dante(size: 11, weight: .semibold)).foregroundStyle(color)
                }
                if let reason = alarm.reason {
                    Text(reason).font(.dante(size: 12)).foregroundStyle(theme.text2.color).lineLimit(2).textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    if let updated = alarm.updated {
                        Text("since \(updated.relative)").font(.dante(size: 11.5)).foregroundStyle(theme.text3.color)
                    }
                }
            }
            Spacer(minLength: 8)
            if let open {
                IconButton(symbol: "arrow.up.right.square", label: "Open in the monitoring console", size: 12, action: open)
            }
            if alarm.state == .alarm {
                Button("Investigate", action: investigate)
                    .buttonStyle(DanteButtonStyle(primary: true))
                    .help("Ask Claude what in the code could cause this, with matching errors from the logs")
            }
        }
    }

    private var color: Color {
        switch alarm.state {
        case .alarm: theme.red.color
        case .unknown: theme.amber.color
        case .ok: theme.green.color
        }
    }

    private var label: String {
        switch alarm.state {
        case .alarm: "ALARM"
        case .unknown: "NO DATA"
        case .ok: "OK"
        }
    }
}
