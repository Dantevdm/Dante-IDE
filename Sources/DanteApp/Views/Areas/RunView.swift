import DanteKit
import SwiftUI

/// Run: how the deployed project is doing. Health checks and a log stream configured in
/// `operate:` in project.yaml, with errors grouped so each can become a task.
struct RunView: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    @State private var latestTag: String?

    private var info: ProjectInfo { workspace.info }

    var body: some View {
        AreaPage(
            eyebrow: "Operate",
            title: "Runtime health",
            subtitle: "Health checks and production logs from operate: in .dante/project.yaml. Every error can become a task or go straight to Claude."
        ) {
            if let latestTag { Chip(text: "\(latestTag) is the latest tag", symbol: "tag") }
            if !info.checks.isEmpty {
                IconButton(symbol: "arrow.clockwise", label: "Check now") { Task { await session.health.poll() } }
            }
        } content: {
            if info.checks.isEmpty, info.logsCommand == nil {
                SetupCard(session: session)
            } else {
                if !info.checks.isEmpty {
                    CardGrid(minimum: 260) {
                        ForEach(info.checks) { check in
                            CheckCard(check: check, samples: session.health.samples[check.id] ?? [])
                        }
                    }
                    if let down = info.checks.first(where: { session.health.samples[$0.id]?.last?.isUp == false }) {
                        DownCard(session: session, check: down, sample: session.health.samples[down.id]?.last)
                    }
                }
                ErrorsCard(session: session, workspace: workspace)
            }
        }
        .task(id: info) {
            session.health.watch(info.checks)
            if let command = info.logsCommand, session.logWatch?.command != command {
                session.logWatch?.stop()
                session.logWatch = LogWatch(command: command, projectRoot: workspace.url)
            }
            latestTag = await GitSnapshot.load(in: workspace.url, recentLimit: 1, sinceTagLimit: 1).latestTag
        }
    }
}

private struct SetupCard: View {
    @Environment(\.theme) private var theme
    let session: Session

    var body: some View {
        EmptyState(
            symbol: "waveform.path.ecg",
            title: "Nothing to watch yet",
            message: "Add health check URLs and a command that streams production logs (aws logs tail, fly logs, kubectl logs -f, heroku logs --tail…) under operate: in .dante/project.yaml."
        ) {
            Button("Set up with Claude") {
                session.askClaude("Set up the Operate area for this project: add an operate: block to .dante/project.yaml with checks (name and url of each health endpoint) and logs (a shell command that streams production logs, for whichever host this project deploys to). Look at the code and config to work out what exists; ask me for anything you can't find.")
            }
            .buttonStyle(DanteButtonStyle(primary: true))
        }
        CodeBlock(text: """
        operate:
          checks:
            - { name: api, url: "https://api.example.com/health" }
          logs: fly logs -a my-app
        """, language: "yaml")
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
                Text(check.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
                Spacer()
                if let last {
                    HStack(spacing: 5) {
                        StatusDot(color: last.isUp ? theme.green.color : theme.red.color, size: 6)
                        Text(last.status.map { "\($0)" } ?? "down").font(.system(size: 12)).foregroundStyle(last.isUp ? theme.green.color : theme.red.color)
                    }
                } else {
                    Text("checking…").font(.system(size: 12)).foregroundStyle(theme.text3.color)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(last?.milliseconds.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text.color)
                Text("ms").foregroundStyle(theme.text3.color)
                Spacer()
                if let uptime {
                    Text("\(Int((uptime * 100).rounded()))% up").font(.system(size: 12)).foregroundStyle(uptime >= 0.99 ? theme.text3.color : theme.amber.color)
                }
            }
            Sparkline(values: latencies, color: (last?.isUp ?? true) ? theme.accent.color : theme.red.color)
                .frame(height: 44)
            Text(last?.error ?? check.url.absoluteString)
                .font(.system(size: 11, design: .monospaced))
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

    var body: some View {
        Card(accent: true) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").foregroundStyle(theme.accent.color)
                Text("\(check.name) is failing its health check").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text.color)
            }
            Text(sample?.error ?? sample?.status.map { "Last response: HTTP \($0)" } ?? "No response")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.text3.color)
            Button("Ask Claude what changed") {
                session.askClaude("The \(check.name) health check (\(check.url.absoluteString)) is failing: \(sample?.error ?? sample?.status.map { "HTTP \($0)" } ?? "no response"). Look at recent commits, the health endpoint's code and any deploy config, and suggest what to check first.")
            }
            .buttonStyle(DanteButtonStyle(primary: true))
        }
    }
}

private struct ErrorsCard: View {
    @Environment(\.theme) private var theme
    let session: Session
    let workspace: Workspace

    var body: some View {
        if let watch = session.logWatch {
            Card("Errors · since this window opened") {
                HStack(spacing: 8) {
                    Text(watch.isRunning ? "following operate.logs" : (watch.exitMessage ?? ""))
                        .font(.system(size: 12))
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
                if watch.digest.issues.isEmpty {
                    Text(watch.digest.linesSeen == 0 ? "Waiting for log lines…" : "No errors in \(watch.digest.linesSeen) lines.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.text3.color)
                    if let message = watch.exitMessage, watch.digest.linesSeen < 5 {
                        Text(watch.recent.suffix(5).joined(separator: "\n").nonEmpty ?? message)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.text2.color)
                            .textSelection(.enabled)
                    }
                }
                RowList(data: Array(watch.digest.issues.prefix(12)), padding: 10) { issue in
                    HStack(alignment: .top, spacing: 12) {
                        StatusDot(color: issue.count > 10 ? theme.red.color : theme.amber.color).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.example)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(theme.text.color)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Text("last seen \(issue.lastSeen.relative)").font(.system(size: 11.5)).foregroundStyle(theme.text3.color)
                        }
                        Spacer(minLength: 8)
                        Text("×\(issue.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.text2.color)
                        Button("Create task") { createTask(for: issue) }
                            .buttonStyle(DanteButtonStyle())
                        Button("Ask Claude") {
                            session.askClaude("This error shows up \(issue.count) times in production logs:\n\n\(issue.example)\n\nFind where it comes from in the code and propose a fix.")
                        }
                        .buttonStyle(DanteButtonStyle())
                    }
                }
            }
        } else {
            Card("Errors") {
                Text("Add operate.logs to .dante/project.yaml with a command that streams production logs, and errors are grouped here as they happen.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.text3.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func createTask(for issue: ErrorDigest.Issue) {
        let phase = workspace.lifecycle.phases.first { $0.lowercased() == "operate" } ?? workspace.lifecycle.phases.last ?? "Operate"
        do {
            try workspace.tasks.add(title: "Fix in production: \(issue.summary)", phase: phase.lowercased())
        } catch {
            session.errorMessage = "Couldn’t add the task: \(error.localizedDescription)"
        }
    }
}
